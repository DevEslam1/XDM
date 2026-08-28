package com.xdm.downloadmanager.widget

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

    @Volatile
    private var lastBroadcastTime = 0L
    @Volatile
    private var lastTotalProgress = 0.0
    @Volatile
    private var lastTotalDownloaded = 0L
    @Volatile
    private var lastActiveCount = -1
    @Volatile
    private var lastFailedCount = -1

    fun save(context: Context, json: String, force: Boolean = false) {
        // Persist synchronously with commit() so receivers read fresh prefs immediately (W-6)
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_DASHBOARD, json)
            .commit()

        val dashboard = WidgetDashboard.fromJson(json)
        val now = System.currentTimeMillis()
        val totalProgress = dashboard?.tasks?.sumOf { it.progress } ?: 0.0
        val totalDownloaded = dashboard?.totalDownloadedBytes ?: 0L
        val activeCount = dashboard?.totalActiveCount ?: 0
        val failedCount = dashboard?.failedCount ?: 0

        // Synchronize static throttle state against concurrent races (W-2 b)
        synchronized(this) {
            val progressDelta = Math.abs(totalProgress - lastTotalProgress)
            val bytesDelta = Math.abs(totalDownloaded - lastTotalDownloaded)
            // Compare failedCount integer delta (W-2 a) instead of boolean hasFailures
            val stateChanged = activeCount != lastActiveCount || failedCount != lastFailedCount

            val shouldBroadcast = force || stateChanged || (now - lastBroadcastTime >= 2000L && (progressDelta >= 0.01 || bytesDelta >= 64 * 1024))

            if (shouldBroadcast) {
                lastBroadcastTime = now
                lastTotalProgress = totalProgress
                lastTotalDownloaded = totalDownloaded
                lastActiveCount = activeCount
                lastFailedCount = failedCount

                // Wake all placed widgets so they re-render with fresh data.
                val intent = Intent(context, WidgetActionReceiver::class.java).apply {
                    action = WidgetActionReceiver.ACTION_UPDATE_WIDGETS
                }
                context.sendBroadcast(intent)
            }
        }
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
