package com.xdm.downloadmanager.widget

import java.util.Locale

/**
 * Pure formatting and sizing utilities for DMX widgets.
 * Isolated from Android framework views for direct unit-testability.
 */
object WidgetFormatters {
    const val SIZE_MINI = "mini"
    const val SIZE_WIDE = "wide"
    const val SIZE_LIST = "list"
    const val SIZE_DASHBOARD = "dashboard"

    fun sizeClassFromWidth(minWidthDp: Int): String = when {
        minWidthDp < 250 -> SIZE_MINI
        minWidthDp < 400 -> SIZE_WIDE
        minWidthDp < 550 -> SIZE_LIST
        else -> SIZE_DASHBOARD
    }

    fun formatSpeed(bytesPerSec: Long): String {
        if (bytesPerSec <= 0) return "0 B/s"
        val units = arrayOf("B/s", "KB/s", "MB/s", "GB/s")
        var value = bytesPerSec.toDouble()
        var unit = 0
        while (value >= 1024 && unit < units.size - 1) {
            value /= 1024
            unit++
        }
        return if (unit == 0) "${value.toInt()} ${units[unit]}"
        else String.format(Locale.US, "%.1f %s", value, units[unit])
    }

    fun formatBytes(bytes: Long): String {
        if (bytes <= 0) return "0 B"
        val units = arrayOf("B", "KB", "MB", "GB", "TB")
        var value = bytes.toDouble()
        var unit = 0
        while (value >= 1024 && unit < units.size - 1) {
            value /= 1024
            unit++
        }
        return if (unit == 0) "${value.toInt()} ${units[unit]}"
        else String.format(Locale.US, "%.1f %s", value, units[unit])
    }

    fun formatSmartEta(status: String, speedBytesPerSec: Long, fileSizeBytes: Long, downloadedBytes: Long): String {
        if (status != "downloading" || speedBytesPerSec <= 0) return "--"
        val remaining = fileSizeBytes - downloadedBytes
        if (remaining <= 0) return "Almost done"
        val etaSeconds = (remaining / speedBytesPerSec).toInt()
        return when {
            etaSeconds < 60 -> "Almost done"
            etaSeconds < 300 -> "~${etaSeconds / 60}m left"
            etaSeconds < 3600 -> {
                val m = etaSeconds / 60
                val s = etaSeconds % 60
                "~${m}m ${s}s"
            }
            else -> {
                val h = etaSeconds / 3600
                val m = (etaSeconds % 3600) / 60
                if (m == 0) "~${h}h" else "~${h}h ${m}m"
            }
        }
    }
}
