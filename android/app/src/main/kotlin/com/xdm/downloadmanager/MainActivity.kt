package com.xdm.downloadmanager

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.PackageInfo
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.StatFs
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
import java.io.File
import java.util.concurrent.Executors
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.xdm.downloadmanager.widget.WidgetDataRepository

class MainActivity : FlutterActivity() {
    private val WIDGET_BRIDGE_CHANNEL = "com.dmx.app/widget_bridge"
    private val MEDIA_CHANNEL = "com.dmx.app/media"
    private val YOUTUBE_CHANNEL = "com.xdm.downloadmanager/youtube_extractor"
    private val SAF_CHANNEL = "com.xdm.downloadmanager/saf"
    private val WAKE_LOCK_CHANNEL = "com.dmx.app/wakelock"
    private val backgroundExecutor = Executors.newSingleThreadExecutor { r -> Thread(r, "xdm-bg").apply { isDaemon = true } }
    private var wakeLock: PowerManager.WakeLock? = null

    private var widgetBridgeChannel: MethodChannel? = null
    private var pendingDeepLink: String? = null
    private var forwardAttempts = 0
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onDestroy() {
        // Release all resources to prevent leaks
        backgroundExecutor.shutdownNow()
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        widgetBridgeChannel?.setMethodCallHandler(null)
        widgetBridgeChannel = null
        super.onDestroy()
    }

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
        // Request maximum refresh rate on supported devices
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window?.addFlags(WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED)
            val display = windowManager?.defaultDisplay
            val modes = display?.supportedModes
            val maxMode = modes?.maxByOrNull { it.refreshRate }
            if (maxMode != null) {
                val attrs = window?.attributes
                if (attrs != null) {
                    attrs.preferredDisplayModeId = maxMode.modeId
                    window.attributes = attrs
                }
            }
            window?.decorView?.post {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    try {
                        val decor = window?.decorView
                        if (decor != null) {
                            val viewRoot = decor.javaClass.getMethod("getViewRootImpl").invoke(decor)
                            if (viewRoot != null) {
                                val viewRootImplClass = Class.forName("android.view.ViewRootImpl")
                                val surfaceControlClass = Class.forName("android.view.SurfaceControl")
                                val surfaceControl = viewRootImplClass.getMethod("getSurfaceControl").invoke(viewRoot)
                                if (surfaceControl != null) {
                                    val surface = surfaceControlClass.getMethod("getSurface").invoke(surfaceControl) as? android.view.Surface
                                    if (surface != null && surface.isValid) {
                                        surface.setFrameRate(
                                            120f,
                                            android.view.Surface.FRAME_RATE_COMPATIBILITY_DEFAULT,
                                            android.view.Surface.CHANGE_FRAME_RATE_ALWAYS
                                        )
                                    }
                                }
                            }
                        }
                    } catch (e: Exception) {
                        Log.e("MainActivity", "Failed to set Surface frame rate: " + e.message)
                    }
                }
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val display = windowManager?.defaultDisplay
            val maxRefreshRate = display?.supportedModes?.maxOfOrNull { it.refreshRate } ?: 60f
            val attrs = window?.attributes
            if (attrs != null) {
                attrs.preferredRefreshRate = maxRefreshRate
                window.attributes = attrs
            }
        }
        // Smart launcher widget deep link (cold start)
        handleDeepLink(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleDeepLink(intent)
    }

    private fun handleDeepLink(intent: Intent?) {
        val uri = intent?.data ?: return
        val url = uri.toString()
        val scheme = uri.scheme?.lowercase() ?: ""

        val isDmx = url.startsWith("dmx://")
        val isMagnet = url.startsWith("magnet:") || scheme == "magnet"
        val isTorrent = url.endsWith(".torrent", ignoreCase = true) ||
                        scheme == "file" || scheme == "content" ||
                        (intent.type?.contains("bittorrent", ignoreCase = true) == true)

        // VALIDATION: Accept dmx://, magnet:, and torrent file schemes
        if (!isDmx && !isMagnet && !isTorrent) {
            Log.w("DMX", "Rejected deep link with invalid scheme: ${uri.scheme}")
            return
        }

        // VALIDATION: Reject excessively long URLs (>16384 chars for complex magnet links)
        if (url.length > 16384) {
            Log.w("DMX", "Rejected deep link: URL too long (${url.length} chars)")
            return
        }

        // VALIDATION: Reject URLs with null bytes
        if (url.contains('\u0000')) {
            Log.w("DMX", "Rejected deep link: contains null bytes")
            return
        }

        if (widgetBridgeChannel != null && pendingDeepLink == null) {
            forwardDeepLink(url)
        } else {
            pendingDeepLink = url
        }
    }

    private fun forwardDeepLink(url: String) {
        val channel = widgetBridgeChannel ?: return
        channel.invokeMethod("onOpenUrl", url, object : MethodChannel.Result {
            override fun success(result: Any?) {
                pendingDeepLink = null
                forwardAttempts = 0
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                // Flutter side has not registered its handler yet — retry shortly.
                if (forwardAttempts < 20) {
                    forwardAttempts++
                    mainHandler.postDelayed({ forwardDeepLink(url) }, 250)
                } else {
                    pendingDeepLink = null
                    forwardAttempts = 0
                }
            }

            override fun notImplemented() {
                pendingDeepLink = null
                forwardAttempts = 0
            }
        })
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.dmx.app/monotonic_clock").setMethodCallHandler { call, result ->
            if (call.method == "elapsedRealtime") {
                result.success(android.os.SystemClock.elapsedRealtime())
            } else {
                result.notImplemented()
            }
        }
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
                // Validate fileName doesn't contain path separators or traversal
                if (fileName.contains("/") || fileName.contains("\\") || fileName.contains("..")) {
                    result.error("INVALID_ARGS", "fileName contains invalid characters", null)
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WIDGET_BRIDGE_CHANNEL).apply {
            widgetBridgeChannel = this
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "pushDashboard" -> {
                        val json = call.arguments as? String
                        if (json == null) {
                            result.error("INVALID_ARGS", "json is required", null)
                            return@setMethodCallHandler
                        }
                        WidgetDataRepository.save(this@MainActivity, json)
                        result.success(true)
                    }
                    "getFreeDiskSpace" -> {
                        val path = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                            !Environment.isExternalStorageManager()
                        ) {
                            filesDir.absolutePath
                        } else {
                            Environment.getExternalStoragePublicDirectory(
                                Environment.DIRECTORY_DOWNLOADS
                            ).absolutePath
                        }
                        try {
                            result.success(StatFs(path).availableBytes)
                        } catch (e: Exception) {
                            result.error("STAT_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
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
                        acquire(45 * 60 * 1000L) // A4: 45-minute timeout — 3× the 15-min Dart renewal interval to survive Doze delays
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.dmx.app/thermal").setMethodCallHandler { call, result ->
            if (call.method == "getThermalStatus") {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                val status = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    when (pm.currentThermalStatus) {
                        PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
                        PowerManager.THERMAL_STATUS_SEVERE -> "severe"
                        PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
                        PowerManager.THERMAL_STATUS_LIGHT -> "fair"
                        else -> "none"
                    }
                } else "none"
                result.success(status)
            } else {
                result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.dmx.app/power").setMethodCallHandler { call, result ->
            if (call.method == "requestIgnoreBatteryOptimizations") {
                try {
                    val intent = Intent(
                        Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                        Uri.parse("package:$packageName")
                    )
                    startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("IGNORE_BATTERY_OPTIMIZATIONS_FAILED", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.dmx.app/security").setMethodCallHandler { call, result ->
            if (call.method == "verifyApkSignature") {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("INVALID_ARGS", "path is required", null)
                    return@setMethodCallHandler
                }
                try {
                    val packageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        packageManager.getPackageArchiveInfo(path, PackageManager.GET_SIGNING_CERTIFICATES)
                    } else {
                        @Suppress("DEPRECATION")
                        packageManager.getPackageArchiveInfo(path, PackageManager.GET_SIGNATURES)
                    }
                    val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        packageInfo?.signingInfo?.apkContentsSigners
                    } else {
                        @Suppress("DEPRECATION")
                        packageInfo?.signatures
                    }
                    if (signatures != null && signatures.isNotEmpty()) {
                        val certBytes = signatures[0].toByteArray()
                        val digest = java.security.MessageDigest.getInstance("SHA-256")
                        val hashBytes = digest.digest(certBytes)
                        val hexString = hashBytes.joinToString("") { "%02x".format(it) }
                        result.success(hexString)
                    } else {
                        result.error("NO_SIGNATURE", "Could not extract APK signatures", null)
                    }
                } catch (e: Exception) {
                    result.error("VERIFY_FAILED", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }
}
