package com.example.dmx.widget

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle

/**
 * Launcher widget provider. Renders the dashboard pushed by the Flutter
 * engine via [WidgetDataRepository] into an adaptive, neon-themed layout.
 */
class DMXWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        if (appWidgetIds.isEmpty()) return
        for (appWidgetId in appWidgetIds) {
            updateWidget(context, appWidgetManager, appWidgetId)
        }
        // Keep the widget fresh while downloads are active (15 min) or idle (30 min).
        val active = WidgetDataRepository.load(context)?.hasActiveDownloads == true
        WidgetUpdateWorker.schedule(context, active)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        super.onAppWidgetOptionsChanged(context, appWidgetManager, appWidgetId, newOptions)
        val minWidthDp = newOptions.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 250)
        WidgetDataRepository.storeSizeClass(
            context,
            appWidgetId,
            DMXRemoteViewsFactory.sizeClassFromWidth(minWidthDp),
        )
        updateWidget(context, appWidgetManager, appWidgetId)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == ACTION_UPDATE_WIDGETS) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, DMXWidgetProvider::class.java))
            onUpdate(context, manager, ids)
        }
    }

    companion object {
        const val ACTION_UPDATE_WIDGETS = "com.example.dmx.UPDATE_WIDGETS"

        fun updateWidget(context: Context, manager: AppWidgetManager, widgetId: Int) {
            val dashboard = WidgetDataRepository.load(context)
            val views = DMXRemoteViewsFactory.build(context, widgetId, dashboard)
            manager.updateAppWidget(widgetId, views)
        }
    }
}
