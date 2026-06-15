package com.example.dmx

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.dmx/widget"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Request maximum refresh rate on supported devices (Android 11+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window?.attributes?.preferredRefreshRate = 120f
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "updateWidget") {
                val activeCount = call.argument<Int>("activeCount") ?: 0
                val totalSpeed = call.argument<String>("totalSpeed") ?: "0 B/s"

                val prefs = getSharedPreferences("DMX_WIDGET_PREFS", Context.MODE_PRIVATE)
                prefs.edit().apply {
                    putInt("active_count", activeCount)
                    putString("total_speed", totalSpeed)
                    apply()
                }

                // Broadcast update intent to DmxWidgetProvider
                val intent = Intent(this, DmxWidgetProvider::class.java).apply {
                    action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                    val ids = AppWidgetManager.getInstance(application).getAppWidgetIds(
                        ComponentName(application, DmxWidgetProvider::class.java)
                    )
                    putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
                }
                sendBroadcast(intent)

                result.success(true)
            } else {
                result.notImplemented()
            }
        }
    }
}
