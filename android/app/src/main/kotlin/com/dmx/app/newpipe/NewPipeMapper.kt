package com.dmx.app.newpipe

import org.schabi.newpipe.extractor.InfoItem
import org.schabi.newpipe.extractor.stream.AudioStream
import org.schabi.newpipe.extractor.stream.DeliveryMethod
import org.schabi.newpipe.extractor.stream.Stream
import org.schabi.newpipe.extractor.stream.StreamExtractor
import org.schabi.newpipe.extractor.stream.StreamInfoItem
import org.schabi.newpipe.extractor.stream.VideoStream

/**
 * Maps NewPipeExtractor model objects to the flat Dart-compatible shapes the
 * download engine / UI consume. Keys mirror the *StreamEntry*, *VideoStreams*,
 * *PlaylistInfo* and *SearchResult* Dart models so the Dart service can decode
 * them directly.
 */
object NewPipeMapper {

    fun streamInfoToMap(
        url: String,
        extractor: StreamExtractor,
    ): Map<String, Any> {
        val title = safeRead { extractor.name }.orEmpty()
        val id = safeRead { extractor.id }.orEmpty()
        val thumb = safeRead { extractor.thumbnails?.firstOrNull()?.url }.orEmpty()

        val videoStreams = try {
            extractor.videoStreams.orEmpty()
        } catch (e: Exception) {
            emptyList()
        }
        val videoOnlyStreams = try {
            extractor.videoOnlyStreams.orEmpty()
        } catch (e: Exception) {
            emptyList()
        }
        val audioStreams = try {
            extractor.audioStreams.orEmpty()
        } catch (e: Exception) {
            emptyList()
        }
        val bestAudio = audioStreams.maxByOrNull { it.averageBitrate }

        val entries = mutableListOf<Map<String, Any>>()
        videoStreams.forEach { video ->
            entries += video.toStreamEntry(
                appType = "muxed",
                quality = video.resolution,
                label = "Video: ${video.resolution} (Muxed)",
            )
        }
        videoOnlyStreams.forEach { video ->
            entries += video.toStreamEntry(
                appType = "video_only",
                quality = video.resolution,
                label = "Video Only: ${video.resolution}",
                audioStream = bestAudio,
            )
        }
        audioStreams.forEach { audio ->
            entries += audio.toStreamEntry()
        }

        return mapOf(
            "url" to url,
            "title" to title,
            "id" to id,
            "thumbnail" to thumb,
            "thumbnailUrl" to thumb,
            "source" to "newpipe",
            "streams" to entries,
        )
    }

    fun resolveExpired(
        url: String,
        extractor: StreamExtractor,
    ): Map<String, Any> = streamInfoToMap(url, extractor)

    private fun VideoStream.toStreamEntry(
        appType: String,
        quality: String,
        label: String,
        audioStream: AudioStream? = null,
    ): Map<String, Any> {
        val videoSize = itagItem?.contentLength?.coerceAtLeast(0L) ?: 0L
        val audioSize = audioStream?.itagItem?.contentLength?.coerceAtLeast(0L) ?: 0L
        val ext = format?.suffix ?: "mp4"

        val entry = mutableMapOf<String, Any>(
            "type" to appType,
            "quality" to quality,
            "label" to label,
            "src" to (content ?: ""),
            "ext" to ext,
            "format" to ext,
            "format_id" to (formatId.takeIf { it >= 0 }?.toString() ?: ""),
            "itag" to (itag.takeIf { it >= 0 }?.toString() ?: ""),
            "manifestType" to manifestType(),
            "videoSize" to videoSize,
            "audioSize" to audioSize,
            "size" to (videoSize + audioSize),
        )
        if (audioStream != null) {
            entry["audioSrc"] = audioStream.content.orEmpty()
            entry["audioExt"] = audioStream.format?.suffix ?: "m4a"
            entry["audioSize"] = audioSize
        }
        return entry
    }

    private fun AudioStream.toStreamEntry(): Map<String, Any> {
        val quality = averageBitrate
        val size = itagItem?.contentLength?.coerceAtLeast(0L) ?: 0L
        val ext = format?.suffix ?: "m4a"
        return mapOf(
            "type" to "audio",
            "quality" to "${quality / 1000}kbps",
            "label" to "Audio Only: (${quality / 1000} Kbps)",
            "src" to (content ?: ""),
            "ext" to ext,
            "format" to ext,
            "format_id" to (formatId.takeIf { it >= 0 }?.toString() ?: ""),
            "itag" to (itag.takeIf { it >= 0 }?.toString() ?: ""),
            "manifestType" to manifestType(),
            "videoSize" to 0L,
            "audioSize" to size,
            "size" to size,
        )
    }

    private fun Stream.manifestType(): String = when (deliveryMethod) {
        DeliveryMethod.HLS -> "hls"
        DeliveryMethod.DASH -> "dash"
        else -> ""
    }

    fun playlistToMap(
        title: String,
        author: String,
        videoCount: Long,
        items: List<Map<String, Any>>,
        nextPageToken: String?,
    ): Map<String, Any> = mapOf<String, Any>(
        "info" to mapOf<String, Any>(
            "title" to title,
            "author" to author,
            "videoCount" to videoCount,
        ),
        "videos" to items,
        "nextPageToken" to (nextPageToken ?: ""),
    )

    fun playlistItemToMap(item: StreamInfoItem): Map<String, Any> {
        val thumb = safeRead { item.thumbnails?.firstOrNull()?.url }.orEmpty()
        val author = safeRead { item.uploaderName }.orEmpty()
        return mapOf(
            "id" to videoIdFromUrl(item.url),
            "title" to item.getName(),
            "author" to author,
            "thumbnail" to thumb,
            "thumbnailUrl" to thumb,
            "url" to item.url,
            "duration" to item.duration,
            "selected" to true,
        )
    }

    fun searchItemToMap(item: InfoItem): Map<String, Any> {
        val thumb = safeRead { item.thumbnails?.firstOrNull()?.url }.orEmpty()
        val streamItem = item as? StreamInfoItem
        val author = streamItem?.let { safeRead { it.uploaderName }.orEmpty() } ?: ""
        val duration = streamItem?.duration ?: 0L
        return mapOf(
            "id" to videoIdFromUrl(item.url),
            "title" to item.name,
            "author" to author,
            "thumbnail" to thumb,
            "thumbnailUrl" to thumb,
            "url" to item.url,
            "duration" to duration,
        )
    }

    /** Extracts a stable video id from a watch/short/embed URL. */
    fun videoIdFromUrl(url: String): String {
        Regex("""[?&]v=([a-zA-Z0-9_-]{11})""").find(url)?.let {
            return it.groupValues[1]
        }
        Regex(""".*/(?:shorts|embed|v)/([a-zA-Z0-9_-]{11})""").find(url)?.let {
            return it.groupValues[1]
        }
        Regex("""youtu\.be/([a-zA-Z0-9_-]{11})""").find(url)?.let {
            return it.groupValues[1]
        }
        val segment = Regex("""/([a-zA-Z0-9_-]{11})(?=/|$)""").find(url)
        if (segment != null && segment.groupValues[1].length == 11) {
            return segment.groupValues[1]
        }
        return ""
    }

    private inline fun <T> safeRead(block: () -> T?): T? = try {
        block()
    } catch (e: Exception) {
        null
    }
}