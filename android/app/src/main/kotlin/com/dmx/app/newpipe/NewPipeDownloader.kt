package com.dmx.app.newpipe

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.schabi.newpipe.extractor.downloader.Downloader
import org.schabi.newpipe.extractor.downloader.Request as NpRequest
import org.schabi.newpipe.extractor.downloader.Response as NpResponse
import java.util.concurrent.TimeUnit

class NewPipeDownloader : Downloader() {

    @Volatile
    private var contextCookies: String? = null

    @Volatile
    private var contextPoToken: String? = null

    @Volatile
    private var contextUserAgent: String? = null

    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .followRedirects(true)
        .followSslRedirects(true)
        .build()

    fun setExtractionContext(cookies: String?, poToken: String?, userAgent: String?) {
        contextCookies = cookies?.takeIf { it.isNotBlank() }
        contextPoToken = poToken?.takeIf { it.isNotBlank() }
        contextUserAgent = userAgent?.takeIf { it.isNotBlank() }
    }

    fun clearExtractionContext() {
        contextCookies = null
        contextPoToken = null
        contextUserAgent = null
    }

    fun poToken(): String? = contextPoToken

    override fun execute(request: NpRequest): NpResponse {
        val url = request.url()
        val reqHeaders = request.headers()
        val body = request.dataToSend()

        val reqBuilder = Request.Builder().url(url)
        if (body != null && body.isNotEmpty()) {
            val mediaType = reqHeaders["Content-Type"]?.firstOrNull()?.toMediaTypeOrNull()
                ?: "application/json".toMediaType()
            reqBuilder.method(request.httpMethod(), body.toRequestBody(mediaType))
        } else {
            reqBuilder.method(request.httpMethod(), null)
        }

        // Fix 8: Cookie merging doesn't deduplicate
        val cookieMap = mutableMapOf<String, String>()
        reqHeaders.forEach { (name, values) ->
            val lowerName = name.lowercase()
            if (lowerName == "cookie") {
                values.forEach { cookieHeader ->
                    cookieHeader.split(";").map { it.trim() }.filter { it.isNotEmpty() }.forEach { cookie ->
                        val parts = cookie.split("=", limit = 2)
                        if (parts.size == 2) {
                            cookieMap[parts[0].trim()] = parts[1].trim()
                        }
                    }
                }
            } else if (lowerName != "user-agent") {
                values.forEach { value -> reqBuilder.addHeader(name, value) }
            }
        }

        contextCookies?.let { contextCookieHeader ->
            contextCookieHeader.split(";").map { it.trim() }.filter { it.isNotEmpty() }.forEach { cookie ->
                val parts = cookie.split("=", limit = 2)
                if (parts.size == 2) {
                    cookieMap[parts[0].trim()] = parts[1].trim() // Context cookies override
                }
            }
        }

        if (cookieMap.isNotEmpty()) {
            reqBuilder.header("Cookie", cookieMap.entries.joinToString("; ") { "${it.key}=${it.value}" })
        }

        // Fix 7: X-Youtube-Po-Token header sent to non-YouTube hosts
        val isYoutube = url.contains("youtube.com") || url.contains("googlevideo.com") || url.contains("youtu.be")
        if (isYoutube) {
            contextPoToken?.let { reqBuilder.header("X-Youtube-Po-Token", it) }
        }

        val isYoutubeiApi = url.contains("youtubei.googleapis.com") || url.contains("youtube.com/youtubei")
        if (!isYoutubeiApi) {
            reqBuilder.header("User-Agent", contextUserAgent ?: USER_AGENT)
        }

        val call = client.newCall(reqBuilder.build())
        call.execute().use { response ->
            val code = response.code
            val message = response.message ?: ""
            
            // Fix 12: Response body read for error responses (Limit to 1MB to prevent OOM)
            val bodyStr = if (response.isSuccessful || code in 400..599) {
                val source = response.body?.source()
                source?.request(1024 * 1024) // Buffer up to 1MB
                val buffer = source?.buffer?.clone()
                buffer?.readString(Charsets.UTF_8) ?: ""
            } else {
                ""
            }
            
            val headers: MutableMap<String, MutableList<String>> = LinkedHashMap()
            response.headers.toMultimap().forEach { (name, values) ->
                headers[name] = ArrayList(values)
            }
            return NpResponse(code, message, headers, bodyStr, response.request.url.toString())
        }
    }

    companion object {
        internal const val USER_AGENT =
            "Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP1A.240505.005) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"

        @Suppress("unused")
        const val CHANNEL_NAME = "com.dmx.app/newpipe"
    }
}