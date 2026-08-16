# ProGuard configuration rules for XDM

# libtorrent
-keep class com.frostwire.jlibtorrent.** { *; }
-dontwarn com.frostwire.jlibtorrent.**

# FFmpegKit
-keep class com.arthenica.ffmpegkit.** { *; }
-dontwarn com.arthenica.ffmpegkit.**

# NewPipeExtractor
-keep class org.schabi.newpipe.extractor.** { *; }
-dontwarn org.schabi.newpipe.extractor.**

# Drift (SQLite database library)
-keep class * extends drift.GeneratedDatabase { *; }

# kotlinx.serialization
-keepclassmembers class * {
    *** Companion;
}
-keepclasseswithmembers class * {
    *** serializer(...);
}
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod
-dontwarn kotlinx.serialization.**

# Mozilla Rhino / NewPipeExtractor missing JVM runtime classes on Android
-dontwarn org.mozilla.javascript.**
-dontwarn java.beans.**
-dontwarn javax.script.**