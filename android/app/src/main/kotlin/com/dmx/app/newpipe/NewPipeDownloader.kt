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

/**
 * OkHttp-backed [Downloader] used by NewPipeExtractor.
 *
 * Cookies / poToken passed from Dart are stored here for the duration of a
 * single extraction and injected into every request NewPipe makes. Extraction
 * runs are serialized on a single thread in [NewPipePlugin] so the context
 * can't bleed across concurrent resolutions.
 */
class NewPipeDownloader : Downloader() {

    @Volatile
    private var contextCookies: String? = null

    @Volatile
    private var contextPoToken: String? = null

    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .followRedirects(true)
        .followSslRedirects(true)
        .build()

    /** Call before starting an extraction (see [NewPipePlugin]). */
    fun setExtractionContext(cookies: String?, poToken: String?) {
        contextCookies = cookies?.takeIf { it.isNotBlank() }
        contextPoToken = poToken?.takeIf { it.isNotBlank() }
    }

    /** Call after extraction finishes so stale session data isn't leaked. */
    fun clearExtractionContext() {
        contextCookies = null
        contextPoToken = null
    }

    /** Reads back the active poToken so the PoTokenProvider can inject it. */
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

        val combinedCookies = mutableListOf<String>()
        reqHeaders.forEach { (name, values) ->
            if (name.equals("Cookie", ignoreCase = true)) {
                combinedCookies.addAll(values)
            } else {
                values.forEach { value -> reqBuilder.addHeader(name, value) }
            }
        }

        // Merge existing cookies with context cookies (RFC 6265)
        contextCookies?.let { combinedCookies.add(it) }
        if (combinedCookies.isNotEmpty()) {
            reqBuilder.header("Cookie", combinedCookies.joinToString("; "))
        }

        contextPoToken?.let { reqBuilder.header("X-Youtube-Po-Token", it) }
        reqBuilder.header("User-Agent", USER_AGENT)

        val call = client.newCall(reqBuilder.build())
        call.execute().use { response ->
            val code = response.code
            val message = response.message ?: ""
            val bodyStr = if (response.isSuccessful || code >= 300) {
                response.body?.string() ?: ""
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
            "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36"

        @Suppress("unused")
        const val CHANNEL_NAME = "com.dmx.app/newpipe"
    }
}