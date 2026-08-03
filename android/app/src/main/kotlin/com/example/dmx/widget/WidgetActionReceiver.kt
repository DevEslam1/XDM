package com.example.dmx.widget

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import com.example.dmx.MainActivity

/**
 * Receives quick-action taps from the widget buttons and forwards them to the
 * app as `dmx://` deep links:
 *
 *   dmx://pause_all   → DownloadProvider.pauseAllTasks()
 *   dmx://resume_all  → DownloadProvider.resumeAllTasks()
 *   dmx://download/<id> → task details (sent with EXTRA_TASK_ID)
 *
 * The Flutter side performs the actual work via [WidgetDeepLinkHandler], so
 * the widget works even when the app was killed (cold start).
 */
class WidgetActionReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        val deepLink = when (action) {
            ACTION_PAUSE_ALL -> "dmx://pause_all"
            ACTION_RESUME_ALL -> "dmx://resume_all"
            ACTION_TOGGLE_TASK -> {
                val taskId = intent.getStringExtra(EXTRA_TASK_ID)
                if (taskId.isNullOrEmpty()) return
                "dmx://download/$taskId"
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
        const val ACTION_PAUSE_ALL = "com.example.dmx.PAUSE_ALL"
        const val ACTION_RESUME_ALL = "com.example.dmx.RESUME_ALL"
        const val ACTION_TOGGLE_TASK = "com.example.dmx.TOGGLE_TASK"
        const val EXTRA_TASK_ID = "task_id"
    }
}
