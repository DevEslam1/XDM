package com.xdm.downloadmanager.widget

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

class WidgetUpdateWorker(context: Context, params: WorkerParameters) :
    CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        refreshAllWidgets(applicationContext)
        return Result.success()
    }

    companion object {
        private const val UNIQUE_NAME = "dmx_widget_refresh"

        /// Android WorkManager enforces a minimum periodic interval of 15 minutes.
        fun schedule(context: Context, activeDownloads: Boolean) {
            val intervalMinutes = if (activeDownloads) 15L else 30L
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.NOT_REQUIRED)
                .build()
            val request = PeriodicWorkRequestBuilder<WidgetUpdateWorker>(
                intervalMinutes,
                TimeUnit.MINUTES,
            )
                .setConstraints(constraints)
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                UNIQUE_NAME,
                ExistingPeriodicWorkPolicy.UPDATE,
                request,
            )
        }

        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(UNIQUE_NAME)
        }

        private fun refreshAllWidgets(context: Context) {
            val manager = android.appwidget.AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(
                android.content.ComponentName(context, DMXWidgetProvider::class.java),
            )
            DMXWidgetProvider().onUpdate(context, manager, ids)
        }
    }
}
