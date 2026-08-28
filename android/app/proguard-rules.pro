# Flutter Local Notifications
-keep class com.dexterous.flutterlocalnotifications.** { *; }
-dontwarn com.dexterous.flutterlocalnotifications.**

# FFmpegKit
-keep class com.arthenica.ffmpegkit.** { *; }
-dontwarn com.arthenica.ffmpegkit.**

# NewPipeExtractor and underlying parser libraries
-keep class org.schabi.newpipe.extractor.** { *; }
-keep class com.grack.nanojson.** { *; }
-keep class org.jsoup.** { *; }
-dontwarn org.schabi.newpipe.extractor.**
-dontwarn com.grack.nanojson.**
-dontwarn org.jsoup.**

# Drift & SQLite
-keep class * extends drift.GeneratedDatabase { *; }
-keep class * extends com.simonoid.sqlite3.** { *; }
-keep class sqlite3.** { *; }
-dontwarn drift.**
-dontwarn sqlite3.**

# kotlinx.serialization
-keepclassmembers class * {
    *** Companion;
}
-keepclasseswithmembers class * {
    *** serializer(...);
}
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod
-dontwarn kotlinx.serialization.**

# AndroidX WorkManager & Flutter Background Service
-keep class androidx.work.** { *; }
-keep class id.flutter.flutter_background_service.** { *; }
-dontwarn androidx.work.**
-dontwarn id.flutter.flutter_background_service.**

# Native JNI / FFI Symbols & Libtorrent Bridge
-keepclasseswithmembernames class * {
    native <methods>;
}
-keep class com.frostwire.jlibtorrent.** { *; }
-keep class org.libtorrent4j.** { *; }
-dontwarn com.frostwire.jlibtorrent.**
-dontwarn org.libtorrent4j.**

# Mozilla Rhino / JVM runtime classes compatibility
-dontwarn org.mozilla.javascript.**
-dontwarn java.beans.**
-dontwarn javax.script.**

# XDM Native Classes and Widget Bridge
-keep class com.xdm.downloadmanager.** { *; }
-keep class com.xdm.downloadmanager.widget.** { *; }
-keep class com.xdm.downloadmanager.MainActivity { *; }
-keep class com.xdm.downloadmanager.YoutubeExtractor { *; }
-keep class com.xdm.downloadmanager.BootReceiver { *; }