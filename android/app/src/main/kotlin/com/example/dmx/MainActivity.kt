package com.example.dmx

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ContentValues
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import android.view.WindowManager
import android.os.PowerManager
import java.io.File
import java.util.concurrent.Executors
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.dmx/widget"
    private val MEDIA_CHANNEL = "com.dmx.app/media"
    private val YOUTUBE_CHANNEL = "com.example.dmx/youtube_extractor"
    private val SAF_CHANNEL = "com.example.dmx/saf"
    private val WAKE_LOCK_CHANNEL = "com.dmx.app/wakelock"
    private val backgroundExecutor = Executors.newSingleThreadExecutor()
    private var wakeLock: PowerManager.WakeLock? = null

    override fun getBackgroundMode(): FlutterActivityLaunchConfigs.BackgroundMode {
        return FlutterActivityLaunchConfigs.BackgroundMode.transparent
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        val action = intent?.action
        if (Intent.ACTION_SEND != action && Intent.ACTION_SEND_MULTIPLE != action) {
            // Normal launch — show splash/launch theme
            setTheme(R.style.LaunchTheme)
        }
        // For share intents, the manifest already sets TranslucentShareTheme
        // so no splash/white flash is shown.
        super.onCreate(savedInstanceState)
        // Request maximum refresh rate on supported devices (Android 11+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window?.attributes?.preferredRefreshRate = 120f
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, YOUTUBE_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method != "getStreams") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val url = call.argument<String>("url")
            if (url.isNullOrBlank()) {
                result.error("invalid_url", "A YouTube URL is required.", null)
                return@setMethodCallHandler
            }
            backgroundExecutor.execute {
                try {
                    val streams = YoutubeExtractor.getStreams(url)
                    runOnUiThread { result.success(streams) }
                } catch (error: Exception) {
                    runOnUiThread { result.error("extractor_failed", error.message, null) }
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIA_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "scanMedia") {
                val path = call.argument<String>("path")
                if (path != null) {
                    MediaScannerConnection.scanFile(this, arrayOf(path), null) { _, _ -> }
                    result.success(true)
                } else {
                    result.error("INVALID_PATH", "Path cannot be null", null)
                }
            } else if (call.method == "insertDownload") {
                val fileName = call.argument<String>("fileName")
                val mimeType = call.argument<String>("mimeType")
                val sourcePath = call.argument<String>("sourcePath")
                if (fileName.isNullOrBlank() || mimeType.isNullOrBlank() || sourcePath.isNullOrBlank()) {
                    result.error("INVALID_ARGS", "fileName, mimeType, and sourcePath are required", null)
                    return@setMethodCallHandler
                }
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                    // SDK 29: copy to public Downloads directly
                    backgroundExecutor.execute {
                        try {
                            val publicDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                            val xdmDir = File(publicDir, "XDM")
                            if (!xdmDir.exists()) xdmDir.mkdirs()
                            val destFile = File(xdmDir, fileName)
                            // Actually copy the file from source to destination
                            val sourceFile = File(sourcePath)
                            if (sourceFile.exists()) {
                                sourceFile.copyTo(destFile, overwrite = true)
                            }
                            // Trigger media scan on the copied file
                            MediaScannerConnection.scanFile(context, arrayOf(destFile.path), arrayOf(mimeType), null)
                            runOnUiThread { result.success(destFile.path) }
                        } catch (e: Exception) {
                            Log.e("MainActivity", "SDK29 fallback failed", e)
                            runOnUiThread { result.success(null) }
                        }
                    }
                    return@setMethodCallHandler
                }
                backgroundExecutor.execute {
                    try {
                        val resolver = contentResolver
                        val values = ContentValues().apply {
                            put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                            put(MediaStore.Downloads.MIME_TYPE, mimeType)
                            put(MediaStore.Downloads.IS_PENDING, 1)
                        }
                        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
                        val uri = resolver.insert(collection, values)
                        if (uri == null) {
                            runOnUiThread { result.success(null) }
                            return@execute
                        }
                        val sourceFile = File(sourcePath)
                        if (!sourceFile.exists()) {
                            Log.w("MainActivity", "insertDownload skipped: sourceFile does not exist at $sourcePath")
                            runOnUiThread { result.success(null) }
                            return@execute
                        }
                        resolver.openOutputStream(uri)?.use { output ->
                            sourceFile.inputStream().use { input ->
                                input.copyTo(output)
                            }
                        }
                        values.clear()
                        values.put(MediaStore.Downloads.IS_PENDING, 0)
                        resolver.update(uri, values, null, null)
                        // After successful copy to MediaStore, do NOT delete source file if it resides in app save path.
                        runOnUiThread { result.success(uri.toString()) }
                    } catch (e: Exception) {
                        Log.e("MainActivity", "insertDownload failed", e)
                        runOnUiThread { result.success(null) }
                    }
                }
            } else {
                result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SAF_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getPublicDownloadsDirectory" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        if (Environment.isExternalStorageManager()) {
                            val downloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                            result.success(downloads.absolutePath)
                        } else {
                            result.success(null)
                        }
                    } else {
                        val downloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                        result.success(downloads.absolutePath)
                    }
                }
                "canManageExternalStorage" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        result.success(Environment.isExternalStorageManager())
                    } else {
                        result.success(true)
                    }
                }
                "requestManageExternalStorage" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        try {
                            val intent = Intent(android.provider.Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION).apply {
                                data = android.net.Uri.parse("package:$packageName")
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            try {
                                val intent = Intent(android.provider.Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                                startActivity(intent)
                                result.success(true)
                            } catch (e2: Exception) {
                                result.success(false)
                            }
                        }
                    } else {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WAKE_LOCK_CHANNEL).setMethodCallHandler { call, result ->
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            when (call.method) {
                "acquire" -> {
                    // Release existing lock if held, then acquire fresh one
                    wakeLock?.let {
                        if (it.isHeld) it.release()
                    }
                    wakeLock = powerManager.newWakeLock(
                        PowerManager.PARTIAL_WAKE_LOCK,
                        "dmx:download_wakelock"
                    ).apply {
                        setReferenceCounted(false)
                        acquire(30 * 60 * 1000L) // 30-minute max timeout as safety net
                    }
                    result.success(true)
                }
                "release" -> {
                    wakeLock?.let {
                        if (it.isHeld) it.release()
                    }
                    wakeLock = null
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
