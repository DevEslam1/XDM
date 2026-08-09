package com.dmx.app.newpipe

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.schabi.newpipe.extractor.NewPipe
import org.schabi.newpipe.extractor.Page
import org.schabi.newpipe.extractor.exceptions.AgeRestrictedContentException
import org.schabi.newpipe.extractor.exceptions.ExtractionException
import org.schabi.newpipe.extractor.exceptions.GeographicRestrictionException
import org.schabi.newpipe.extractor.exceptions.ReCaptchaException
import org.schabi.newpipe.extractor.exceptions.SignInConfirmNotBotException
import org.schabi.newpipe.extractor.playlist.PlaylistInfo
import org.schabi.newpipe.extractor.services.youtube.PoTokenProvider
import org.schabi.newpipe.extractor.services.youtube.PoTokenResult
import org.schabi.newpipe.extractor.services.youtube.extractors.YoutubeStreamExtractor
import org.schabi.newpipe.extractor.stream.StreamInfoItem
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class NewPipePlugin(
    private val messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val downloader = NewPipeDownloader()
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var initialized = false

    fun register() {
        channel.setMethodCallHandler(this)
    }

    fun unregister() {
        channel.setMethodCallHandler(null)
        executor.shutdown()
        try {
            if (!executor.awaitTermination(5, TimeUnit.SECONDS)) {
                executor.shutdownNow()
            }
        } catch (e: InterruptedException) {
            executor.shutdownNow()
            Thread.currentThread().interrupt()
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getStreams", "resolveExpired" -> handleStreamCall(call, result)
            "getPlaylist" -> handlePlaylistCall(call, result)
            "search" -> handleSearchCall(call, result)
            else -> result.notImplemented()
        }
    }

    private fun ensureInitialized() {
        if (initialized) return
        synchronized(this) {
            if (initialized) return
            NewPipe.init(downloader)
            registerPoTokenProvider()
            initialized = true
        }
    }

    private fun registerPoTokenProvider() {
        val provider = object : PoTokenProvider {
            override fun getWebClientPoToken(visitorData: String): PoTokenResult? = resultFor(visitorData)
            override fun getWebEmbedClientPoToken(visitorData: String): PoTokenResult? = resultFor(visitorData)
            // Return null for mobile clients as we don't have a mobile-specific poToken from Dart
            override fun getAndroidClientPoToken(visitorData: String): PoTokenResult? = null
            override fun getIosClientPoToken(visitorData: String): PoTokenResult? = null
        }
        YoutubeStreamExtractor.setPoTokenProvider(provider)
    }

    private fun resultFor(visitorData: String): PoTokenResult? {
        val poToken = downloader.poToken()
        return if (poToken.isNullOrEmpty()) {
            null
        } else {
            PoTokenResult(visitorData, poToken, poToken)
        }
    }

    private fun handleStreamCall(call: MethodCall, result: MethodChannel.Result) {
        val url: String? = call.argument("url")
        if (url.isNullOrBlank()) {
            result.error("invalid_url", "A media URL is required.", null)
            return
        }
        val cookies: String? = call.argument("cookies")
        val poToken: String? = call.argument("poToken")
        val userAgent: String? = call.argument("userAgent")

        android.util.Log.d("NewPipePlugin", "handleStreamCall: method=${call.method}, url=$url, hasCookies=${!cookies.isNullOrBlank()}, hasPoToken=${!poToken.isNullOrBlank()}, hasUserAgent=${!userAgent.isNullOrBlank()}")

        if (url.contains("\r") || url.contains("\n") ||
            cookies?.contains("\r") == true || cookies?.contains("\n") == true ||
            poToken?.contains("\r") == true || poToken?.contains("\n") == true ||
            userAgent?.contains("\r") == true || userAgent?.contains("\n") == true) {
            result.error("invalid_input", "HTTP header injection detected.", null)
            return
        }

        val resolve = call.method == "resolveExpired"

        runBackground(result) {
            val map = withContext(cookies, poToken, userAgent) {
                ensureInitialized()
                val service = NewPipe.getServiceByUrl(url)
                val extractor = service.getStreamExtractor(url)
                extractor.fetchPage()
                if (resolve) {
                    NewPipeMapper.resolveExpired(url, extractor)
                } else {
                    NewPipeMapper.streamInfoToMap(url, extractor)
                }
            }
            result.success(map)
        }
    }

    private fun handlePlaylistCall(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        if (url.isNullOrBlank()) {
            result.error("invalid_url", "A playlist URL is required.", null)
            return
        }
        val cookies = call.argument<String>("cookies")
        val pageToken = call.argument<String>("pageToken")
        val userAgent = call.argument<String>("userAgent")

        android.util.Log.d("NewPipePlugin", "handlePlaylistCall: url=$url, hasCookies=${!cookies.isNullOrBlank()}, hasPageToken=${!pageToken.isNullOrBlank()}, hasUserAgent=${!userAgent.isNullOrBlank()}")

        runBackground(result) {
            val payload = withContext(cookies, null, userAgent) {
                ensureInitialized()
                val service = NewPipe.getServiceByUrl(url)
                if (pageToken.isNullOrEmpty()) {
                    val info = PlaylistInfo.getInfo(service, url)
                    val items = info.relatedItems
                        .filterIsInstance<StreamInfoItem>()
                        .map { NewPipeMapper.playlistItemToMap(it) }
                    NewPipeMapper.playlistToMap(
                        title = info.name.orEmpty(),
                        author = info.uploaderName.orEmpty(),
                        videoCount = info.streamCount,
                        items = items,
                        nextPageToken = encodeNextPage(info.nextPage),
                    )
                } else {
                    val page = decodeNextPage(pageToken)
                    if (page == null) {
                        throw ExtractionException("Invalid page token")
                    }
                    val pageResult = PlaylistInfo.getMoreItems(service, url, page)
                    val items = pageResult.items
                        .filterIsInstance<StreamInfoItem>()
                        .map { NewPipeMapper.playlistItemToMap(it) }
                    NewPipeMapper.playlistToMap(
                        title = "",
                        author = "",
                        videoCount = -1L,
                        items = items,
                        nextPageToken = encodeNextPage(pageResult.nextPage),
                    )
                }
            }
            result.success(payload)
        }
    }

    private fun handleSearchCall(call: MethodCall, result: MethodChannel.Result) {
        val serviceId = call.argument<Int>("serviceId") ?: 0
        val query = call.argument<String>("query")
        if (query.isNullOrBlank()) {
            result.error("invalid_query", "A search query is required.", null)
            return
        }
        val cookies = call.argument<String>("cookies")
        val userAgent = call.argument<String>("userAgent")

        android.util.Log.d("NewPipePlugin", "handleSearchCall: serviceId=$serviceId, query=$query, hasCookies=${!cookies.isNullOrBlank()}, hasUserAgent=${!userAgent.isNullOrBlank()}")

        runBackground(result) {
            val items = withContext(cookies, null, userAgent) {
                ensureInitialized()
                val service = NewPipe.getService(serviceId)
                val linkHandler = service.searchQHFactory.fromQuery(query)
                val extractor = service.getSearchExtractor(linkHandler)
                extractor.fetchPage()
                extractor.initialPage.items
                    .filterIsInstance<StreamInfoItem>()
                    .map { NewPipeMapper.searchItemToMap(it) }
            }
            result.success(items)
        }
    }

    private fun runBackground(result: MethodChannel.Result, block: () -> Unit) {
        executor.execute {
            try {
                block()
            } catch (e: Throwable) {
                android.util.Log.e("NewPipePlugin", "Extraction failed: ${e.message}", e)
                mainHandler.post {
                    result.error(exceptionCode(e), e.message ?: "Extraction failed", null)
                }
            }
        }
    }

    private inline fun <T> withContext(cookies: String?, poToken: String?, userAgent: String?, block: () -> T): T {
        downloader.setExtractionContext(cookies, poToken, userAgent)
        try {
            return block()
        } finally {
            downloader.clearExtractionContext()
        }
    }

    private fun exceptionCode(e: Throwable): String = when (e) {
        is AgeRestrictedContentException -> "age_restricted"
        is GeographicRestrictionException -> "geo_restricted"
        is ReCaptchaException -> "sign_in_required"
        is SignInConfirmNotBotException -> "sign_in_required"
        else -> {
            val msg = (e.message ?: "").lowercase()
            when {
                msg.contains("sign in to confirm") || msg.contains("bot") ||
                    msg.contains("recaptcha") || msg.contains("captcha") ||
                    msg.contains("ytinitialdata") || msg.contains("ytinitialplayerresponse") ||
                    msg.contains("could not get") -> "sign_in_required"
                msg.contains("age-restricted") || msg.contains("age restricted") -> "age_restricted"
                msg.contains("not available in your country") || msg.contains("geo") ->
                    "geo_restricted"
                msg.contains("no streams") || msg.contains("nothing found") -> "no_streams"
                else -> "extraction_failed"
            }
        }
    }

    private fun encodeNextPage(page: Page?): String? {
        if (page == null || !Page.isValid(page)) return null
        val obj = JSONObject()
        obj.put("id", page.id ?: "")
        obj.put("url", page.url ?: "")
        val cookies = page.cookies
        if (cookies != null) {
            val parts = mutableListOf<String>()
            for ((k, v) in cookies) {
                if (k != null && v != null) {
                    parts.add("$k=$v")
                }
            }
            if (parts.isNotEmpty()) {
                obj.put("cookies", parts.joinToString("; "))
            }
        }
        return obj.toString()
    }

    private fun decodeNextPage(token: String?): Page? {
        if (token.isNullOrEmpty()) return null
        return try {
            val obj = JSONObject(token)
            val id = obj.optString("id", "")
            val url = obj.optString("url", "")
            val cookiesStr = obj.optString("cookies", "").ifEmpty { null }
            
            val cookies = cookiesStr?.split(";")?.map { it.trim() }?.filter { it.isNotEmpty() }
            
            when {
                id.isNotEmpty() && url.isNotEmpty() -> {
                    if (cookies != null) Page(url, id, cookies, emptyMap(), null)
                    else Page(url, id)
                }
                id.isNotEmpty() -> Page(id)
                url.isNotEmpty() -> Page(url)
                else -> null
            }
        } catch (e: Exception) {
            null
        }
    }

    companion object {
        const val CHANNEL_NAME = "com.dmx.app/newpipe"
    }
}