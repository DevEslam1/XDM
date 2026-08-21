package com.xdm.downloadmanager.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import com.xdm.downloadmanager.MainActivity
import com.xdm.downloadmanager.R
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

object DMXRemoteViewsFactory {
    const val SIZE_MINI = "mini"
    const val SIZE_WIDE = "wide"
    const val SIZE_LIST = "list"
    const val SIZE_DASHBOARD = "dashboard"

    private val requestCodeMap = ConcurrentHashMap<String, Int>()
    private val nextRequestCode = AtomicInteger(1000)

    private fun getOrCreateRequestCode(key: String): Int {
        return requestCodeMap.computeIfAbsent(key) { nextRequestCode.getAndIncrement() }
    }

    // ── Enhanced palette ──
    const val COLOR_BG = 0xFF0F1117.toInt()
    const val COLOR_SURFACE = 0xFF161A22.toInt()
    const val COLOR_NEON_GREEN = 0xFF10B981.toInt()
    const val COLOR_NEON_BLUE = 0xFF3B82F6.toInt()
    const val COLOR_NEON_RED = 0xFFEF4444.toInt()
    const val COLOR_NEON_VIOLET = 0xFF8B5CF6.toInt()
    const val COLOR_NEON_AMBER = 0xFFF59E0B.toInt()
    const val COLOR_TEXT_PRIMARY = 0xFFF2F4F8.toInt()
    const val COLOR_TEXT_SECONDARY = 0xFF9AA3B5.toInt()
    const val COLOR_TEXT_MUTED = 0xFF5F6B82.toInt()

    fun sizeClassFromWidth(minWidthDp: Int): String = when {
        minWidthDp < 250 -> SIZE_MINI
        minWidthDp < 400 -> SIZE_WIDE
        minWidthDp < 550 -> SIZE_LIST
        else -> SIZE_DASHBOARD
    }

    fun build(context: Context, widgetId: Int, dashboard: WidgetDashboard?): RemoteViews {
        val size = WidgetDataRepository.sizeClass(context, widgetId)
        val layout = when (size) {
            SIZE_MINI -> R.layout.widget_mini
            SIZE_WIDE -> R.layout.widget_wide
            SIZE_DASHBOARD -> R.layout.widget_dashboard
            else -> R.layout.widget_list
        }
        return buildFor(context, widgetId, size, layout, dashboard)
    }

    fun buildFor(
        context: Context,
        widgetId: Int,
        size: String,
        layout: Int,
        dashboard: WidgetDashboard?,
    ): RemoteViews {
        val views = RemoteViews(context.packageName, layout)
        val selectedTab = WidgetDataRepository.selectedTab(context, widgetId)
        val openDownloads = activityIntent(context, "dmx://downloads")
        val allTasks = dashboard?.tasks ?: emptyList()
        val filteredTasks = if (selectedTab == WidgetDataRepository.TAB_COMPLETED) {
            allTasks.filter { it.status == "completed" }
        } else {
            allTasks.filter { it.status != "completed" }
        }

        if (dashboard == null || allTasks.isEmpty()) {
            applyAllClear(views, size, dashboard)
        } else {
            when (size) {
                SIZE_MINI -> applyMini(context, views, dashboard, filteredTasks, selectedTab)
                SIZE_WIDE -> applyWide(context, views, dashboard, filteredTasks, selectedTab)
                SIZE_DASHBOARD -> applyDashboard(context, widgetId, views, dashboard, filteredTasks, selectedTab)
                else -> applyList(context, widgetId, views, dashboard, filteredTasks, selectedTab)
            }
        }

        views.setOnClickPendingIntent(R.id.widget_root, openDownloads)
        return views
    }

    // ─────────────────────────────────────────────────────────────────────
    // Smart Wide Widget
    // ─────────────────────────────────────────────────────────────────────
    private fun applyWide(
        context: Context,
        views: RemoteViews,
        dashboard: WidgetDashboard,
        tasks: List<WidgetTaskSummary>,
        selectedTab: String,
    ) {
        val top = tasks.firstOrNull()
        if (top == null) {
            applyAllClear(views, SIZE_WIDE, dashboard)
            return
        }

        views.setViewVisibility(R.id.widget_wide_clear, View.GONE)
        views.setViewVisibility(R.id.widget_wide_name, View.VISIBLE)
        views.setViewVisibility(R.id.widget_wide_progress, View.VISIBLE)

        applyCategoryTag(views, R.id.widget_wide_tag, top)
        views.setTextViewText(R.id.widget_wide_name, top.fileName)
        setProgress(views, R.id.widget_wide_progress, top.progress)

        // Smart speed badge with trend
        val speedText = formatSpeed(top.speedBytesPerSec)
        val trendIcon = when (top.speedTrend) {
            "up" -> "↑"
            "down" -> "↓"
            else -> "→"
        }
        val trendColor = when (top.speedTrend) {
            "up" -> COLOR_NEON_GREEN
            "down" -> COLOR_NEON_RED
            else -> COLOR_TEXT_SECONDARY
        }
        views.setTextViewText(R.id.widget_wide_speed_badge, "$trendIcon $speedText")
        views.setTextColor(R.id.widget_wide_speed_badge, trendColor)

        // Smart ETA
        val etaText = formatSmartEta(top)
        views.setTextViewText(R.id.widget_wide_eta, etaText)

        // Percentage
        val percentText = if (top.status == "completed") {
            formatBytes(top.fileSizeBytes)
        } else {
            "${(top.progress * 100).toInt()}%"
        }
        views.setTextViewText(R.id.widget_wide_percent, percentText)

        val intent = if (top.status == "completed") {
            broadcastActionIntent(context, WidgetActionReceiver.ACTION_OPEN_TASK, top.id)
        } else {
            activityIntent(context, "dmx://download/${top.id}")
        }
        views.setOnClickPendingIntent(R.id.widget_wide_root, intent)
    }

    // ─────────────────────────────────────────────────────────────────────
    // Smart Dashboard Widget
    // ─────────────────────────────────────────────────────────────────────
    private fun applyDashboard(
        context: Context,
        widgetId: Int,
        views: RemoteViews,
        dashboard: WidgetDashboard,
        tasks: List<WidgetTaskSummary>,
        selectedTab: String,
    ) {
        views.setViewVisibility(R.id.widget_dash_clear, View.GONE)
        views.setViewVisibility(R.id.widget_dash_rows, View.VISIBLE)
        views.setViewVisibility(R.id.widget_dash_actions, View.VISIBLE)
        bindTabsHeader(context, widgetId, views, dashboard, selectedTab, SIZE_DASHBOARD)

        val visible = tasks.take(5)
        for (index in 0 until 5) {
            val task = visible.getOrNull(index)
            val visibleId = dashRowVisibleId(index)
            views.setViewVisibility(visibleId, if (task != null) View.VISIBLE else View.GONE)

            if (task != null) {
                applyCategoryTag(views, dashRowTagId(index), task)
                views.setTextViewText(dashRowNameId(index), task.fileName)
                setProgress(views, dashRowProgressId(index), if (task.status == "completed") 1.0 else task.progress)

                // Smart percentage display
                val percentText = if (task.status == "completed") {
                    formatBytes(task.fileSizeBytes)
                } else {
                    "${(task.progress * 100).toInt()}%"
                }
                views.setTextViewText(dashRowPercentId(index), percentText)

                // Status dot color
                val dotColor = when (task.status) {
                    "downloading" -> COLOR_NEON_BLUE
                    "seeding" -> COLOR_NEON_GREEN
                    "paused" -> COLOR_NEON_AMBER
                    "queued" -> COLOR_NEON_VIOLET
                    "failed" -> COLOR_NEON_RED
                    "completed" -> COLOR_NEON_GREEN
                    else -> COLOR_TEXT_MUTED
                }
                views.setInt(dashRowDotId(index), "setBackgroundColor", dotColor)

                // Speed + ETA meta row
                if (task.status == "downloading") {
                    views.setViewVisibility(dashRowMetaId(index), View.VISIBLE)
                    views.setTextViewText(dashRowSpeedId(index), formatSpeed(task.speedBytesPerSec))
                    views.setTextViewText(dashRowEtaId(index), formatSmartEta(task))
                } else {
                    views.setViewVisibility(dashRowMetaId(index), View.GONE)
                }

                // Action button
                val actionId = dashRowActionId(index)
                bindRowActionButton(context, views, actionId, task)

                val itemIntent = if (task.status == "completed") {
                    broadcastActionIntent(context, WidgetActionReceiver.ACTION_OPEN_TASK, task.id)
                } else {
                    activityIntent(context, "dmx://download/${task.id}")
                }
                views.setOnClickPendingIntent(visibleId, itemIntent)
            }
        }

        // "+N more" hint
        val remaining = tasks.size - 5
        views.setViewVisibility(
            R.id.widget_dash_more,
            if (remaining > 0) View.VISIBLE else View.GONE,
        )
        views.setTextViewText(R.id.widget_dash_more, "+$remaining more")

        // Storage warning with smart thresholds
        when {
            dashboard.isStorageCritical -> {
                views.setViewVisibility(R.id.widget_dash_storage, View.VISIBLE)
                views.setTextViewText(
                    R.id.widget_dash_storage,
                    "⚠ CRITICAL: ${formatBytes(dashboard.availableStorageBytes)} free",
                )
                views.setInt(R.id.widget_dash_storage, "setBackgroundColor", COLOR_NEON_RED)
            }
            dashboard.isStorageLow -> {
                views.setViewVisibility(R.id.widget_dash_storage, View.VISIBLE)
                views.setTextViewText(
                    R.id.widget_dash_storage,
                    "⚠ Low storage: ${formatBytes(dashboard.availableStorageBytes)} free",
                )
                views.setInt(R.id.widget_dash_storage, "setBackgroundColor", COLOR_NEON_AMBER)
            }
            else -> views.setViewVisibility(R.id.widget_dash_storage, View.GONE)
        }

        // Failure banner
        if (dashboard.hasFailures && selectedTab == WidgetDataRepository.TAB_DOWNLOADING) {
            views.setViewVisibility(R.id.widget_dash_failures, View.VISIBLE)
            views.setTextViewText(
                R.id.widget_dash_failures,
                "${dashboard.failedCount} download${if (dashboard.failedCount == 1) "" else "s"} failed",
            )
            views.setInt(R.id.widget_dash_failures, "setBackgroundColor", COLOR_NEON_RED)
        } else {
            views.setViewVisibility(R.id.widget_dash_failures, View.GONE)
        }

        // Quick actions
        views.setOnClickPendingIntent(
            R.id.widget_dash_pause,
            broadcastIntent(context, WidgetActionReceiver.ACTION_PAUSE_ALL),
        )
        views.setOnClickPendingIntent(
            R.id.widget_dash_resume,
            broadcastIntent(context, WidgetActionReceiver.ACTION_RESUME_ALL),
        )
    }

    // ─────────────────────────────────────────────────────────────────────
    // Smart Helpers
    // ─────────────────────────────────────────────────────────────────────

    /// Smart ETA formatting based on remaining time
    private fun formatSmartEta(task: WidgetTaskSummary): String {
        if (task.status != "downloading" || task.speedBytesPerSec <= 0) return "--"
        val remaining = task.fileSizeBytes - task.downloadedBytes
        if (remaining <= 0) return "Almost done"
        val etaSeconds = (remaining / task.speedBytesPerSec).toInt()
        return when {
            etaSeconds < 10 -> "Almost done"
            etaSeconds < 60 -> "${etaSeconds}s left"
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

    private fun bindTabsHeader(
        context: Context,
        widgetId: Int,
        views: RemoteViews,
        dashboard: WidgetDashboard,
        selectedTab: String,
        size: String = SIZE_LIST,
    ) {
        val activeCount = dashboard.tasks.count { it.status != "completed" }
        val completedCount = dashboard.tasks.count { it.status == "completed" }
        views.setTextViewText(R.id.widget_tab_downloading, "DOWNLOADING ($activeCount)")
        views.setTextViewText(R.id.widget_tab_completed, "COMPLETED ($completedCount)")

        val isCompleted = selectedTab == WidgetDataRepository.TAB_COMPLETED
        if (isCompleted) {
            views.setInt(R.id.widget_tab_downloading, "setBackgroundResource", R.drawable.widget_tab_inactive)
            views.setTextColor(R.id.widget_tab_downloading, COLOR_TEXT_SECONDARY)
            views.setInt(R.id.widget_tab_completed, "setBackgroundResource", R.drawable.widget_tab_active_green)
            views.setTextColor(R.id.widget_tab_completed, COLOR_NEON_GREEN)
        } else {
            views.setInt(R.id.widget_tab_downloading, "setBackgroundResource", R.drawable.widget_tab_active_cyan)
            views.setTextColor(R.id.widget_tab_downloading, COLOR_NEON_BLUE)
            views.setInt(R.id.widget_tab_completed, "setBackgroundResource", R.drawable.widget_tab_inactive)
            views.setTextColor(R.id.widget_tab_completed, COLOR_TEXT_SECONDARY)
        }

        views.setOnClickPendingIntent(
            R.id.widget_tab_downloading,
            broadcastTabIntent(context, widgetId, WidgetDataRepository.TAB_DOWNLOADING),
        )
        views.setOnClickPendingIntent(
            R.id.widget_tab_completed,
            broadcastTabIntent(context, widgetId, WidgetDataRepository.TAB_COMPLETED),
        )

        // Speed with trend icon
        val speedText = formatSpeed(dashboard.totalSpeedBytesPerSec)
        val speedIcon = if (dashboard.totalSpeedBytesPerSec > 0) "↓" else "→"
        if (size == SIZE_LIST) {
            views.setTextViewText(R.id.widget_list_speed, speedText)
        } else if (size == SIZE_DASHBOARD) {
            views.setTextViewText(R.id.widget_dash_speed, speedText)
            views.setTextViewText(R.id.widget_dash_speed_icon, speedIcon)
        }
    }

    private fun bindRowActionButton(
        context: Context,
        views: RemoteViews,
        actionViewId: Int,
        task: WidgetTaskSummary,
    ) {
        when {
            task.status == "completed" -> {
                views.setTextViewText(actionViewId, "OPEN")
                views.setTextColor(actionViewId, COLOR_NEON_GREEN)
                views.setInt(actionViewId, "setBackgroundResource", R.drawable.widget_button_resume)
                views.setOnClickPendingIntent(
                    actionViewId,
                    broadcastActionIntent(context, WidgetActionReceiver.ACTION_OPEN_TASK, task.id),
                )
            }
            task.status == "downloading" || task.status == "queued" -> {
                views.setTextViewText(actionViewId, "❚❚")
                views.setTextColor(actionViewId, COLOR_NEON_BLUE)
                views.setInt(actionViewId, "setBackgroundResource", R.drawable.widget_button_pause)
                views.setOnClickPendingIntent(
                    actionViewId,
                    broadcastActionIntent(context, WidgetActionReceiver.ACTION_TOGGLE_TASK, task.id),
                )
            }
            else -> {
                views.setTextViewText(actionViewId, "▶")
                views.setTextColor(actionViewId, COLOR_NEON_GREEN)
                views.setInt(actionViewId, "setBackgroundResource", R.drawable.widget_button_resume)
                views.setOnClickPendingIntent(
                    actionViewId,
                    broadcastActionIntent(context, WidgetActionReceiver.ACTION_TOGGLE_TASK, task.id),
                )
            }
        }
    }

    private fun applyCategoryTag(views: RemoteViews, tagViewId: Int, task: WidgetTaskSummary) {
        val tagText = formatCategoryTag(task)
        val tagColor = when {
            task.isTorrent -> COLOR_NEON_VIOLET
            task.isAppUpdate -> COLOR_NEON_AMBER
            else -> when (task.category.uppercase()) {
                "VIDEO" -> COLOR_NEON_BLUE
                "AUDIO" -> COLOR_NEON_GREEN
                "DOCUMENT" -> COLOR_NEON_AMBER
                "ARCHIVE" -> COLOR_NEON_VIOLET
                "APK" -> COLOR_NEON_RED
                else -> COLOR_TEXT_SECONDARY
            }
        }
        views.setTextViewText(tagViewId, tagText)
        views.setTextColor(tagViewId, tagColor)
        views.setViewVisibility(tagViewId, View.VISIBLE)
    }

    private fun formatCategoryTag(task: WidgetTaskSummary): String {
        if (task.isTorrent) return "TORRENT"
        if (task.isAppUpdate) return "UPDATE"
        val cat = task.category.uppercase()
        return if (cat.isNotEmpty() && cat != "OTHER") cat else "FILE"
    }

    private fun applyAllClear(views: RemoteViews, size: String, dashboard: WidgetDashboard?) {
        val clearId = when (size) {
            SIZE_MINI -> R.id.widget_mini_clear
            SIZE_WIDE -> R.id.widget_wide_clear
            SIZE_DASHBOARD -> R.id.widget_dash_clear
            else -> R.id.widget_list_clear
        }
        views.setViewVisibility(clearId, View.VISIBLE)
        val doneCount = dashboard?.completedTodayCount ?: 0
        val text = when {
            dashboard == null -> "ALL CLEAR\nOpen XDM to start downloading"
            doneCount > 0 -> "ALL CLEAR\n$doneCount completed today"
            else -> "ALL CLEAR\nNo active downloads"
        }
        views.setTextViewText(clearId, text)

        when (size) {
            SIZE_MINI -> {
                views.setViewVisibility(R.id.widget_mini_ring, View.GONE)
                views.setViewVisibility(R.id.widget_mini_tag, View.GONE)
                views.setViewVisibility(R.id.widget_mini_name, View.GONE)
                views.setViewVisibility(R.id.widget_mini_stats, View.GONE)
            }
            SIZE_WIDE -> {
                views.setViewVisibility(R.id.widget_wide_tag, View.GONE)
                views.setViewVisibility(R.id.widget_wide_name, View.GONE)
                views.setViewVisibility(R.id.widget_wide_progress, View.GONE)
                views.setViewVisibility(R.id.widget_wide_speed_badge, View.GONE)
                views.setViewVisibility(R.id.widget_wide_eta, View.GONE)
                views.setViewVisibility(R.id.widget_wide_percent, View.GONE)
            }
            SIZE_DASHBOARD -> {
                views.setViewVisibility(R.id.widget_dash_rows, View.GONE)
                views.setViewVisibility(R.id.widget_dash_actions, View.GONE)
                views.setViewVisibility(R.id.widget_dash_storage, View.GONE)
                views.setViewVisibility(R.id.widget_dash_failures, View.GONE)
            }
            else -> {
                views.setViewVisibility(R.id.widget_list_rows, View.GONE)
                views.setViewVisibility(R.id.widget_list_footer, View.GONE)
            }
        }
    }

    private fun setProgress(views: RemoteViews, viewId: Int, progress: Double) {
        views.setProgressBar(
            viewId,
            100,
            (progress.coerceIn(0.0, 1.0) * 100).toInt(),
            false,
        )
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

    // ── Row ID helpers (dashboard) ──
    private fun dashRowVisibleId(index: Int) = when (index) {
        0 -> R.id.widget_dash_row1
        1 -> R.id.widget_dash_row2
        2 -> R.id.widget_dash_row3
        3 -> R.id.widget_dash_row4
        else -> R.id.widget_dash_row5
    }
    private fun dashRowTagId(index: Int) = when (index) {
        0 -> R.id.widget_dash_row1_tag
        1 -> R.id.widget_dash_row2_tag
        2 -> R.id.widget_dash_row3_tag
        3 -> R.id.widget_dash_row4_tag
        else -> R.id.widget_dash_row5_tag
    }
    private fun dashRowNameId(index: Int) = when (index) {
        0 -> R.id.widget_dash_row1_name
        1 -> R.id.widget_dash_row2_name
        2 -> R.id.widget_dash_row3_name
        3 -> R.id.widget_dash_row4_name
        else -> R.id.widget_dash_row5_name
    }
    private fun dashRowProgressId(index: Int) = when (index) {
        0 -> R.id.widget_dash_row1_progress
        1 -> R.id.widget_dash_row2_progress
        2 -> R.id.widget_dash_row3_progress
        3 -> R.id.widget_dash_row4_progress
        else -> R.id.widget_dash_row5_progress
    }
    private fun dashRowPercentId(index: Int) = when (index) {
        0 -> R.id.widget_dash_row1_percent
        1 -> R.id.widget_dash_row2_percent
        2 -> R.id.widget_dash_row3_percent
        3 -> R.id.widget_dash_row4_percent
        else -> R.id.widget_dash_row5_percent
    }
    private fun dashRowActionId(index: Int) = when (index) {
        0 -> R.id.widget_dash_row1_action
        1 -> R.id.widget_dash_row2_action
        2 -> R.id.widget_dash_row3_action
        3 -> R.id.widget_dash_row4_action
        else -> R.id.widget_dash_row5_action
    }
    private fun dashRowDotId(index: Int) = when (index) {
        0 -> R.id.widget_dash_row1_dot
        1 -> R.id.widget_dash_row2_dot
        2 -> R.id.widget_dash_row3_dot
        3 -> R.id.widget_dash_row4_dot
        else -> R.id.widget_dash_row5_dot
    }
    private fun dashRowMetaId(index: Int) = when (index) {
        0 -> R.id.widget_dash_row1_meta
        1 -> R.id.widget_dash_row2_meta
        2 -> R.id.widget_dash_row3_meta
        3 -> R.id.widget_dash_row4_meta
        else -> R.id.widget_dash_row5_meta
    }
    private fun dashRowSpeedId(index: Int) = when (index) {
        0 -> R.id.widget_dash_row1_speed
        1 -> R.id.widget_dash_row2_speed
        2 -> R.id.widget_dash_row3_speed
        3 -> R.id.widget_dash_row4_speed
        else -> R.id.widget_dash_row5_speed
    }
    private fun dashRowEtaId(index: Int) = when (index) {
        0 -> R.id.widget_dash_row1_eta
        1 -> R.id.widget_dash_row2_eta
        2 -> R.id.widget_dash_row3_eta
        3 -> R.id.widget_dash_row4_eta
        else -> R.id.widget_dash_row5_eta
    }

    // ── Intent helpers ──
    private fun activityIntent(context: Context, uri: String): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            data = Uri.parse(uri)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val reqCode = getOrCreateRequestCode("act_$uri")
        return PendingIntent.getActivity(
            context,
            reqCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun broadcastIntent(context: Context, action: String): PendingIntent {
        val intent = Intent(context, WidgetActionReceiver::class.java).setAction(action)
        val reqCode = getOrCreateRequestCode("bcast_$action")
        return PendingIntent.getBroadcast(
            context,
            reqCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun broadcastTabIntent(context: Context, widgetId: Int, tab: String): PendingIntent {
        val intent = Intent(context, WidgetActionReceiver::class.java).apply {
            action = WidgetActionReceiver.ACTION_SELECT_TAB
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
            putExtra(WidgetActionReceiver.EXTRA_TAB, tab)
        }
        val reqCode = getOrCreateRequestCode("tab_${widgetId}_$tab")
        return PendingIntent.getBroadcast(
            context,
            reqCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun broadcastActionIntent(context: Context, action: String, taskId: String): PendingIntent {
        val intent = Intent(context, WidgetActionReceiver::class.java).apply {
            this.action = action
            putExtra(WidgetActionReceiver.EXTRA_TASK_ID, taskId)
        }
        val reqCode = getOrCreateRequestCode("action_${action}_$taskId")
        return PendingIntent.getBroadcast(
            context,
            reqCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    // ── List/Mini helpers ──
    private fun applyMini(
        context: Context,
        views: RemoteViews,
        dashboard: WidgetDashboard,
        tasks: List<WidgetTaskSummary>,
        selectedTab: String,
    ) {
        val top = tasks.firstOrNull()
        if (top == null) {
            applyAllClear(views, SIZE_MINI, dashboard)
            return
        }
        views.setViewVisibility(R.id.widget_mini_name, View.VISIBLE)
        views.setViewVisibility(R.id.widget_mini_stats, View.VISIBLE)
        applyCategoryTag(views, R.id.widget_mini_tag, top)
        views.setTextViewText(R.id.widget_mini_name, top.fileName)
        if (top.status == "downloading") {
            views.setTextViewText(
                R.id.widget_mini_stats,
                "${formatSpeed(top.speedBytesPerSec)} · ${formatSmartEta(top)}",
            )
            views.setViewVisibility(R.id.widget_mini_ring, View.VISIBLE)
            views.setViewVisibility(R.id.widget_mini_clear, View.GONE)
        } else if (top.status == "completed") {
            views.setViewVisibility(R.id.widget_mini_ring, View.GONE)
            views.setViewVisibility(R.id.widget_mini_clear, View.VISIBLE)
            views.setTextViewText(R.id.widget_mini_clear, "OPEN FILE")
            views.setTextViewText(R.id.widget_mini_stats, formatBytes(top.fileSizeBytes))
        } else {
            views.setViewVisibility(R.id.widget_mini_ring, View.GONE)
            views.setViewVisibility(R.id.widget_mini_clear, View.VISIBLE)
            views.setTextViewText(R.id.widget_mini_clear, statusLabel(top.status))
        }
        val intent = if (top.status == "completed") {
            broadcastActionIntent(context, WidgetActionReceiver.ACTION_OPEN_TASK, top.id)
        } else {
            activityIntent(context, "dmx://download/${top.id}")
        }
        views.setOnClickPendingIntent(R.id.widget_mini_root, intent)
    }

    private fun applyList(
        context: Context,
        widgetId: Int,
        views: RemoteViews,
        dashboard: WidgetDashboard,
        tasks: List<WidgetTaskSummary>,
        selectedTab: String,
    ) {
        views.setViewVisibility(R.id.widget_list_clear, View.GONE)
        views.setViewVisibility(R.id.widget_list_rows, View.VISIBLE)
        views.setViewVisibility(R.id.widget_list_footer, View.VISIBLE)
        bindTabsHeader(context, widgetId, views, dashboard, selectedTab, SIZE_LIST)

        val visible = tasks.take(3)
        for (index in 0 until 3) {
            val task = visible.getOrNull(index)
            val visibleId = rowVisibleId(index)
            views.setViewVisibility(visibleId, if (task != null) View.VISIBLE else View.GONE)
            if (task != null) {
                applyCategoryTag(views, rowTagId(index), task)
                views.setTextViewText(rowNameId(index), task.fileName)
                setProgress(views, rowProgressId(index), if (task.status == "completed") 1.0 else task.progress)
                views.setTextViewText(
                    rowPercentId(index),
                    if (task.status == "completed") formatBytes(task.fileSizeBytes) else "${(task.progress * 100).toInt()}%",
                )
                val actionId = rowActionId(index)
                bindRowActionButton(context, views, actionId, task)
                val itemIntent = if (task.status == "completed") {
                    broadcastActionIntent(context, WidgetActionReceiver.ACTION_OPEN_TASK, task.id)
                } else {
                    activityIntent(context, "dmx://download/${task.id}")
                }
                views.setOnClickPendingIntent(visibleId, itemIntent)
            }
        }
        val footer = buildFooter(dashboard, selectedTab, tasks.size)
        views.setTextViewText(R.id.widget_list_footer, footer)
    }

    private fun buildFooter(dashboard: WidgetDashboard, selectedTab: String, count: Int): String {
        val parts = mutableListOf<String>()
        if (selectedTab == WidgetDataRepository.TAB_COMPLETED) {
            parts.add("$count completed")
        } else {
            if (dashboard.totalActiveCount > 0) parts.add("${dashboard.totalActiveCount} active")
            if (dashboard.queuedCount > 0) parts.add("${dashboard.queuedCount} queued")
        }
        if (dashboard.availableStorageBytes >= 0) {
            parts.add("${formatBytes(dashboard.availableStorageBytes)} free")
        }
        try {
            if (dashboard.lastUpdated.isNotEmpty()) {
                val lastUpdatedMillis = java.time.Instant.parse(dashboard.lastUpdated).toEpochMilli()
                if (System.currentTimeMillis() - lastUpdatedMillis > 30 * 60 * 1000) {
                    val sdf = java.text.SimpleDateFormat("HH:mm", Locale.US)
                    parts.add("· as of " + sdf.format(java.util.Date(lastUpdatedMillis)))
                }
            }
        } catch (_: Exception) {}
        return parts.joinToString(" · ")
    }

    private fun statusLabel(status: String): String = when (status) {
        "downloading" -> "DOWNLOADING"
        "seeding" -> "SEEDING"
        "paused" -> "PAUSED"
        "queued" -> "QUEUED"
        "failed" -> "FAILED"
        else -> "DONE"
    }

    private fun rowVisibleId(index: Int) = when (index) {
        0 -> R.id.widget_row1
        1 -> R.id.widget_row2
        else -> R.id.widget_row3
    }
    private fun rowTagId(index: Int) = when (index) {
        0 -> R.id.widget_row1_tag
        1 -> R.id.widget_row2_tag
        else -> R.id.widget_row3_tag
    }
    private fun rowNameId(index: Int) = when (index) {
        0 -> R.id.widget_row1_name
        1 -> R.id.widget_row2_name
        else -> R.id.widget_row3_name
    }
    private fun rowProgressId(index: Int) = when (index) {
        0 -> R.id.widget_row1_progress
        1 -> R.id.widget_row2_progress
        else -> R.id.widget_row3_progress
    }
    private fun rowPercentId(index: Int) = when (index) {
        0 -> R.id.widget_row1_percent
        1 -> R.id.widget_row2_percent
        else -> R.id.widget_row3_percent
    }
    private fun rowActionId(index: Int) = when (index) {
        0 -> R.id.widget_row1_action
        1 -> R.id.widget_row2_action
        else -> R.id.widget_row3_action
    }
}
