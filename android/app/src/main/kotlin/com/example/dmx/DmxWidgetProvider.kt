package com.example.dmx

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.widget.RemoteViews

class DmxWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        val prefs = context.getSharedPreferences("DMX_WIDGET_PREFS", Context.MODE_PRIVATE)
        val activeCount = prefs.getInt("active_count", 0)
        val totalSpeed = prefs.getString("total_speed", "0 B/s") ?: "0 B/s"

        for (appWidgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.dmx_widget)
            views.setTextViewText(R.id.widget_active_count, "ACTIVE: $activeCount")
            views.setTextViewText(R.id.widget_total_speed, totalSpeed)
            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}
