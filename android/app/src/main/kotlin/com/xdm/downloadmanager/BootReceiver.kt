package com.xdm.downloadmanager

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.xdm.downloadmanager.widget.WidgetUpdateWorker

/// Receives system boot and package update broadcasts to restore background workers and widget state.
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (Intent.ACTION_BOOT_COMPLETED == action ||
            Intent.ACTION_MY_PACKAGE_REPLACED == action ||
            "android.intent.action.QUICKBOOT_POWERON" == action) {
            Log.i("DMX_BootReceiver", "Boot completed broadcast received ($action). Initializing background tasks and widget sync.")
            try {
                // Refresh widget data and schedule WorkManager periodic sync
                WidgetUpdateWorker.schedule(context, activeDownloads = false)
            } catch (e: Exception) {
                Log.e("DMX_BootReceiver", "Error handling boot broadcast", e)
            }
        }
    }
}
