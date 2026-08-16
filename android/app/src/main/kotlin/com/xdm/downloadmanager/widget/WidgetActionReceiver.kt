package com.xdm.downloadmanager.widget

import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import com.xdm.downloadmanager.MainActivity

/**
 * Receives quick-action taps and tab selection from widget buttons and forwards them
 * to the app as `dmx://` deep links or updates native widget tab state:
 *
 *   dmx://pause_all   → DownloadProvider.pauseAllTasks()
 *   dmx://resume_all  → DownloadProvider.resumeAllTasks()
 *   dmx://toggle/<id> → toggle task pause/resume
 *   dmx://open/<id>   → open completed task file directly
 *   dmx://download/<id> → task details
 *
 * Tab switches (Downloading / Completed) update SharedPreferences and trigger
 * immediate widget timeline re-rendering.
 */
class WidgetActionReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return

        if (action == ACTION_SELECT_TAB) {
            val widgetId = intent.getIntExtra(
                AppWidgetManager.EXTRA_APPWIDGET_ID,
                AppWidgetManager.INVALID_APPWIDGET_ID,
            )
            val tab = intent.getStringExtra(EXTRA_TAB) ?: WidgetDataRepository.TAB_DOWNLOADING
            if (widgetId != AppWidgetManager.INVALID_APPWIDGET_ID) {
                WidgetDataRepository.storeSelectedTab(context, widgetId, tab)
                val manager = AppWidgetManager.getInstance(context)
                DMXWidgetProvider.updateWidget(context, manager, widgetId)
            }
            return
        }

        val deepLink = when (action) {
            ACTION_PAUSE_ALL -> "dmx://pause_all"
            ACTION_RESUME_ALL -> "dmx://resume_all"
            ACTION_TOGGLE_TASK -> {
                val taskId = intent.getStringExtra(EXTRA_TASK_ID)
                if (!isValidTaskId(taskId)) return
                "dmx://toggle/$taskId"
            }
            ACTION_PAUSE_TASK -> {
                val taskId = intent.getStringExtra(EXTRA_TASK_ID)
                if (!isValidTaskId(taskId)) return
                "dmx://pause/$taskId"
            }
            ACTION_CANCEL_TASK -> {
                val taskId = intent.getStringExtra(EXTRA_TASK_ID)
                if (!isValidTaskId(taskId)) return
                "dmx://cancel/$taskId"
            }
            ACTION_OPEN_TASK -> {
                val taskId = intent.getStringExtra(EXTRA_TASK_ID)
                if (!isValidTaskId(taskId)) return
                "dmx://open/$taskId"
            }
            else -> return
        }

        val launch = Intent(context, MainActivity::class.java).apply {
            data = Uri.parse(deepLink)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        context.startActivity(launch)
    }

    companion object {
        const val ACTION_PAUSE_ALL = "com.xdm.downloadmanager.PAUSE_ALL"
        const val ACTION_RESUME_ALL = "com.xdm.downloadmanager.RESUME_ALL"
        const val ACTION_TOGGLE_TASK = "com.xdm.downloadmanager.TOGGLE_TASK"
        const val ACTION_OPEN_TASK = "com.xdm.downloadmanager.OPEN_TASK"
        const val ACTION_SELECT_TAB = "com.xdm.downloadmanager.SELECT_TAB"
        const val ACTION_PAUSE_TASK = "com.xdm.downloadmanager.PAUSE_TASK"
        const val ACTION_CANCEL_TASK = "com.xdm.downloadmanager.CANCEL_TASK"

        const val EXTRA_TASK_ID = "task_id"
        const val EXTRA_TAB = "tab"
    }

    /**
     * VALIDATION: task IDs must be non-blank and alphanumeric + hyphens only.
     * Rejects null/empty/malformed values that could be injected via a
     * spoofed broadcast.
     */
    private fun isValidTaskId(taskId: String?): Boolean {
        if (taskId.isNullOrBlank()) {
            Log.w("DMX", "Widget action rejected: null or empty task_id")
            return false
        }
        if (!taskId.matches(Regex("^[a-zA-Z0-9\\-_]+$"))) {
            Log.w("DMX", "Widget action rejected: invalid task_id format")
            return false
        }
        return true
    }
}
