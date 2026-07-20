package com.example.dmx

import org.schabi.newpipe.extractor.NewPipe
import org.schabi.newpipe.extractor.ServiceList
import org.schabi.newpipe.extractor.downloader.Downloader
import org.schabi.newpipe.extractor.downloader.Request
import org.schabi.newpipe.extractor.downloader.Response
import org.schabi.newpipe.extractor.stream.AudioStream
import org.schabi.newpipe.extractor.stream.VideoStream
import java.io.BufferedReader
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets

/** Android-only bridge around NewPipe Extractor. */
object YoutubeExtractor {
    @Volatile
    private var initialized = false

    fun getStreams(url: String): List<Map<String, Any>> {
        ensureInitialized()
        val extractor = ServiceList.YouTube.getStreamExtractor(url)
        extractor.fetchPage()
        val title = extractor.name.orEmpty()
        val streams = mutableListOf<Map<String, Any>>()

        extractor.videoStreams.orEmpty().forEach { stream ->
            streams += stream.toMap(title, "muxed")
        }
        val audioStreams = extractor.audioStreams.orEmpty()
        audioStreams.forEach { stream ->
            streams += stream.toMap(title)
        }
        val sortedAudio = audioStreams.sortedByDescending { it.bitrate }
        val bestAudio = sortedAudio.firstOrNull()
        val secondBestAudio = if (sortedAudio.size > 1) sortedAudio[1] else bestAudio
        
        extractor.videoOnlyStreams.orEmpty().forEach { stream ->
            streams += stream.toMap(title, "video_only")
            if (bestAudio != null && secondBestAudio != null) {
                val resNum = stream.resolution.replace(Regex("[^0-9]"), "").toIntOrNull() ?: 0
                val selectedAudio = if (resNum >= 720) bestAudio else secondBestAudio
                val audioLabel = if (resNum >= 720) "Best" else "Standard"

                val videoSize = (stream.itagItem?.contentLength ?: 0L).coerceAtLeast(0L)
                val audioSize = (selectedAudio.itagItem?.contentLength ?: 0L).coerceAtLeast(0L)
                streams += stream.toMap(title, "combined").toMutableMap().apply {
                    put("label", "Video: ${stream.resolution} + Audio ($audioLabel)")
                    put("type", "combined")
                    put("audioSrc", selectedAudio.content)
                    put("size", videoSize + audioSize)
                    put("videoSize", videoSize)
                    put("audioSize", audioSize)
                    put("audioExt", selectedAudio.format?.suffix ?: "m4a")
                }
            }
        }
        return streams
    }

    private fun ensureInitialized() {
        if (initialized) return
        synchronized(this) {
            if (!initialized) {
                NewPipe.init(NewPipeHttpDownloader())
                initialized = true
            }
        }
    }

    private fun VideoStream.toMap(title: String, type: String) = mapOf(
        "src" to content,
        "label" to if (type == "muxed") "Video: $resolution (Muxed)" else "Video Only: ($resolution)",
        "size" to (itagItem?.contentLength ?: 0L).coerceAtLeast(0L),
        "ext" to (format?.suffix ?: "mp4"),
        "title" to title,
        "quality" to resolution,
        "type" to type,
        "videoSize" to (itagItem?.contentLength ?: 0L).coerceAtLeast(0L),
    )

    private fun AudioStream.toMap(title: String) = mapOf(
        "src" to content,
        "label" to "Audio Only: (${bitrate / 1000} Kbps)",
        "size" to (itagItem?.contentLength ?: 0L).coerceAtLeast(0L),
        "ext" to (format?.suffix ?: "mp4"),
        "title" to title,
        "quality" to "${bitrate / 1000}kbps",
        "type" to "audio",
    )
}

/** Small HTTP implementation required by NewPipe Extractor. */
private class NewPipeHttpDownloader : Downloader() {
    override fun execute(request: Request): Response {
        val connection = (URL(request.url()).openConnection() as HttpURLConnection).apply {
            instanceFollowRedirects = true
            requestMethod = request.httpMethod()
            connectTimeout = 20_000
            readTimeout = 30_000
            setRequestProperty("User-Agent", "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/124.0 Mobile Safari/537.36")
            request.headers().forEach { (name, values) ->
                values.forEach { value -> addRequestProperty(name, value) }
            }
        }
        val body = request.dataToSend()
        if (body != null && body.isNotEmpty()) {
            connection.doOutput = true
            connection.outputStream.use { output: OutputStream -> output.write(body) }
        }
        val code = connection.responseCode
        val stream = if (code >= 400) connection.errorStream else connection.inputStream
        val responseBody = stream?.bufferedReader(StandardCharsets.UTF_8)?.use(BufferedReader::readText).orEmpty()
        val headers = connection.headerFields
            .filterKeys { it != null }
            .mapKeys { it.key!! }
            .mapValues { it.value ?: emptyList() }
        return Response(code, connection.responseMessage.orEmpty(), headers, responseBody, connection.url.toString())
    }
}