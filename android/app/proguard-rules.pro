# Required by NewPipe Extractor when shrinking the Android release build.
-keep class org.schabi.newpipe.extractor.** { *; }
-keep class org.schabi.newpipe.extractor.services.** { *; }
-keep class org.mozilla.javascript.** { *; }
-keep class org.mozilla.classfile.ClassFileWriter
-dontwarn org.mozilla.javascript.tools.**
-dontwarn java.beans.**
-dontwarn javax.script.**
-dontwarn jdk.dynalink.**
