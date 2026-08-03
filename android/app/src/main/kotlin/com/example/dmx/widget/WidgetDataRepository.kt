package com.example.dmx.widget

import android.content.Context
import android.content.Intent

/**
 * Stores the latest dashboard JSON pushed by the Flutter engine and notifies
 * every placed widget to refresh itself.
 */
object WidgetDataRepository {
    private const val PREFS_NAME = "dmx_widget_data"
    private const val KEY_DASHBOARD = "widget_dashboard"

    /** Size class per widget id, chosen in onAppWidgetOptionsChanged. */
    private const val KEY_SIZE = "widget_size_"

    /** Selected tab per widget id ("downloading" or "completed"). */
    private const val KEY_TAB = "widget_tab_"
    const val TAB_DOWNLOADING = "downloading"
    const val TAB_COMPLETED = "completed"

    fun save(context: Context, json: String) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_DASHBOARD, json)
            .apply()

        // Wake all placed widgets so they re-render with fresh data.
        val intent = Intent(DMXWidgetProvider.ACTION_UPDATE_WIDGETS)
        intent.setPackage(context.packageName)
        context.sendBroadcast(intent)
    }

    fun load(context: Context): WidgetDashboard? {
        val json = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(KEY_DASHBOARD, null)
            ?: return null
        return WidgetDashboard.fromJson(json)
    }

    fun storeSizeClass(context: Context, widgetId: Int, sizeClass: String) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_SIZE + widgetId, sizeClass)
            .apply()
    }

    fun sizeClass(context: Context, widgetId: Int): String {
        return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(KEY_SIZE + widgetId, DMXRemoteViewsFactory.SIZE_LIST) ?: DMXRemoteViewsFactory.SIZE_LIST
    }

    fun storeSelectedTab(context: Context, widgetId: Int, tab: String) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_TAB + widgetId, tab)
            .apply()
    }

    fun selectedTab(context: Context, widgetId: Int): String {
        return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(KEY_TAB + widgetId, TAB_DOWNLOADING) ?: TAB_DOWNLOADING
    }
}
