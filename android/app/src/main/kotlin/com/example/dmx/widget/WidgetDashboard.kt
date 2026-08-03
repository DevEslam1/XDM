package com.example.dmx.widget

import org.json.JSONObject

/**
 * Single download task snapshot for the launcher widget.
 * Mirrors `WidgetTaskSummary` in `lib/core/services/widget_data_bridge.dart`.
 */
data class WidgetTaskSummary(
    val id: String,
    val fileName: String,
    val status: String, // queued | downloading | paused | completed | failed | seeding
    val progress: Double, // 0.0 - 1.0
    val speedBytesPerSec: Long,
    val etaSeconds: Int?,
    val fileSizeBytes: Long,
    val downloadedBytes: Long,
    val category: String,
    val thumbnailUrl: String?,
    val playlistId: String?,
    val playlistTitle: String?,
    val playlistIndex: Int?,
    val errorMessage: String?,
    val isTorrent: Boolean,
    val seedingRatio: Double?,
    val priority: Int,
    val isAppUpdate: Boolean,
    val speedTrend: String, // up | down | stable
) {
    fun isActive(): Boolean = status == "downloading" || status == "seeding"

    fun isFailed(): Boolean = status == "failed"

    fun isPaused(): Boolean = status == "paused"

    fun isQueued(): Boolean = status == "queued"

    companion object {
        fun fromJson(obj: JSONObject): WidgetTaskSummary {
            fun nullableInt(key: String): Int? =
                if (obj.isNull(key)) null else obj.optInt(key, -1).let { if (it < 0) null else it }

            fun nullableDouble(key: String): Double? =
                if (obj.isNull(key)) null else obj.optDouble(key, -1.0).let { if (it < 0) null else it }

            return WidgetTaskSummary(
                id = obj.optString("id", ""),
                fileName = obj.optString("fileName", ""),
                status = obj.optString("status", "paused"),
                progress = obj.optDouble("progress", 0.0).coerceIn(0.0, 1.0),
                speedBytesPerSec = obj.optLong("speedBytesPerSec", 0L),
                etaSeconds = nullableInt("etaSeconds"),
                fileSizeBytes = obj.optLong("fileSizeBytes", 0L),
                downloadedBytes = obj.optLong("downloadedBytes", 0L),
                category = obj.optString("category", "Other"),
                thumbnailUrl = obj.optString("thumbnailUrl").takeIf { it.isNotEmpty() },
                playlistId = obj.optString("playlistId").takeIf { it.isNotEmpty() },
                playlistTitle = obj.optString("playlistTitle").takeIf { it.isNotEmpty() },
                playlistIndex = nullableInt("playlistIndex"),
                errorMessage = obj.optString("errorMessage").takeIf { it.isNotEmpty() },
                isTorrent = obj.optBoolean("isTorrent", false),
                seedingRatio = nullableDouble("seedingRatio"),
                priority = obj.optInt("priority", 0),
                isAppUpdate = obj.optBoolean("isAppUpdate", false),
                speedTrend = obj.optString("speedTrend", "stable"),
            )
        }
    }
}

/**
 * Aggregated download snapshot for the launcher widget.
 * Mirrors `WidgetDashboard` in `lib/core/services/widget_data_bridge.dart`.
 */
data class WidgetDashboard(
    val tasks: List<WidgetTaskSummary>,
    val totalActiveCount: Int,
    val totalSpeedBytesPerSec: Long,
    val totalDownloadedBytes: Long,
    val totalFileSizeBytes: Long,
    val completedTodayCount: Int,
    val failedCount: Int,
    val availableStorageBytes: Long, // -1 = unknown
    val isOnWifi: Boolean,
    val lastUpdated: String,
) {
    val hasActiveDownloads: Boolean get() = totalActiveCount > 0
    val hasFailures: Boolean get() = failedCount > 0
    val isStorageLow: Boolean
        get() = availableStorageBytes >= 0 && availableStorageBytes < LOW_STORAGE_THRESHOLD
    val isStorageCritical: Boolean
        get() = availableStorageBytes >= 0 && availableStorageBytes < CRITICAL_STORAGE_THRESHOLD

    val queuedCount: Int get() = tasks.count { it.isQueued() }

    /** Playlist members grouped by playlist id, ordered by index. */
    val playlistGroups: Map<String, List<WidgetTaskSummary>>
        get() = tasks
            .filter { it.playlistId != null }
            .groupBy { it.playlistId!! }
            .mapValues { (_, value) -> value.sortedBy { it.playlistIndex ?: Int.MAX_VALUE } }

    companion object {
        const val LOW_STORAGE_THRESHOLD = 500L * 1024 * 1024
        const val CRITICAL_STORAGE_THRESHOLD = 100L * 1024 * 1024

        fun fromJson(json: String): WidgetDashboard? {
            return try {
                val obj = JSONObject(json)
                val arr = obj.optJSONArray("tasks") ?: return null
                val tasks = (0 until arr.length()).map { index ->
                    WidgetTaskSummary.fromJson(arr.getJSONObject(index))
                }
                WidgetDashboard(
                    tasks = tasks,
                    totalActiveCount = obj.optInt("totalActiveCount", 0),
                    totalSpeedBytesPerSec = obj.optLong("totalSpeedBytesPerSec", 0L),
                    totalDownloadedBytes = obj.optLong("totalDownloadedBytes", 0L),
                    totalFileSizeBytes = obj.optLong("totalFileSizeBytes", 0L),
                    completedTodayCount = obj.optInt("completedTodayCount", 0),
                    failedCount = obj.optInt("failedCount", 0),
                    availableStorageBytes = obj.optLong("availableStorageBytes", -1L),
                    isOnWifi = obj.optBoolean("isOnWifi", false),
                    lastUpdated = obj.optString("lastUpdated", ""),
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}
