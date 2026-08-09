package com.dmx.app.newpipe

import org.schabi.newpipe.extractor.InfoItem
import org.schabi.newpipe.extractor.stream.AudioStream
import org.schabi.newpipe.extractor.stream.DeliveryMethod
import org.schabi.newpipe.extractor.stream.Stream
import org.schabi.newpipe.extractor.stream.StreamExtractor
import org.schabi.newpipe.extractor.stream.StreamInfoItem
import org.schabi.newpipe.extractor.stream.VideoStream

object NewPipeMapper {

    fun streamInfoToMap(
        url: String,
        extractor: StreamExtractor,
    ): Map<String, Any> {
        val title = safeRead { extractor.name }.orEmpty()
        val id = safeRead { extractor.id }.orEmpty()
        val thumb = safeRead { extractor.thumbnails?.firstOrNull()?.url }
        val videoId = videoIdFromUrl(url)

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
            if (video.deliveryMethod != DeliveryMethod.HLS && video.deliveryMethod != DeliveryMethod.DASH) {
                entries += video.toStreamEntry(
                    appType = "muxed",
                    quality = video.resolution,
                    label = "Video: ${video.resolution} (Muxed)",
                    videoId = videoId,
                )
            }
        }
        videoOnlyStreams.forEach { video ->
            if (video.deliveryMethod != DeliveryMethod.HLS && video.deliveryMethod != DeliveryMethod.DASH) {
                entries += video.toStreamEntry(
                    appType = "video_only",
                    quality = video.resolution,
                    label = "Video Only: ${video.resolution}",
                    audioStream = bestAudio,
                    videoId = videoId,
                )
            }
        }
        audioStreams.forEach { audio ->
            if (audio.deliveryMethod != DeliveryMethod.HLS && audio.deliveryMethod != DeliveryMethod.DASH) {
                entries += audio.toStreamEntry(videoId = videoId)
            }
        }

        val map = mutableMapOf<String, Any>(
            "url" to url,
            "title" to title,
            "id" to id,
            "source" to "newpipe",
            "streams" to entries,
        )
        thumb?.let {
            map["thumbnail"] = it
            map["thumbnailUrl"] = it
        }
        return map
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
        videoId: String = "",
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
            "videoId" to videoId,
        )
        if (audioStream != null) {
            entry["audioSrc"] = audioStream.content.orEmpty()
            entry["audioExt"] = audioStream.format?.suffix ?: "m4a"
            entry["audioSize"] = audioSize
        }
        return entry
    }

    private fun AudioStream.toStreamEntry(videoId: String = ""): Map<String, Any> {
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
            "videoId" to videoId,
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
    ): Map<String, Any> {
        val map = mutableMapOf<String, Any>(
            "info" to mapOf<String, Any>(
                "title" to title,
                "author" to author,
                "videoCount" to videoCount,
            ),
            "videos" to items,
        )
        if (nextPageToken != null) {
            map["nextPageToken"] = nextPageToken
        }
        return map
    }

    fun playlistItemToMap(item: StreamInfoItem): Map<String, Any> {
        val thumb = safeRead { item.thumbnails?.firstOrNull()?.url }
        val author = safeRead { item.uploaderName }.orEmpty()
        val map = mutableMapOf<String, Any>(
            "id" to videoIdFromUrl(item.url),
            "title" to item.getName(),
            "author" to author,
            "url" to item.url,
            "duration" to item.duration,
            "selected" to true,
        )
        thumb?.let {
            map["thumbnail"] = it
            map["thumbnailUrl"] = it
        }
        return map
    }

    fun searchItemToMap(item: InfoItem): Map<String, Any> {
        val thumb = safeRead { item.thumbnails?.firstOrNull()?.url }
        val streamItem = item as? StreamInfoItem
        val author = streamItem?.let { safeRead { it.uploaderName }.orEmpty() } ?: ""
        val duration = streamItem?.duration ?: 0L
        val map = mutableMapOf<String, Any>(
            "id" to videoIdFromUrl(item.url),
            "title" to item.name,
            "author" to author,
            "url" to item.url,
            "duration" to duration,
        )
        thumb?.let {
            map["thumbnail"] = it
            map["thumbnailUrl"] = it
        }
        return map
    }

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
        Regex("""music\.youtube\.com/watch\?v=([a-zA-Z0-9_-]{11})""").find(url)?.let {
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