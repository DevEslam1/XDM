import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.xdm.downloadmanager"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.xdm.downloadmanager"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    val keystorePropertiesFile = rootProject.file("keystore.properties")
    val keyPropertiesFile = rootProject.file("key.properties")
    val propFile = if (keystorePropertiesFile.exists()) keystorePropertiesFile else if (keyPropertiesFile.exists()) keyPropertiesFile else null
    val keystoreProperties = Properties()
    var hasValidKeystore = false
    if (propFile != null) {
        keystoreProperties.load(FileInputStream(propFile))
        val storePath = keystoreProperties.getProperty("storeFile")
        if (storePath != null && (file(storePath).exists() || rootProject.file(storePath).exists())) {
            hasValidKeystore = true
        }
    }

    signingConfigs {
        if (hasValidKeystore) {
            create("release") {
                val storePath = keystoreProperties.getProperty("storeFile")
                val keystoreFile = if (file(storePath).exists()) file(storePath) else rootProject.file(storePath)
                storeFile = keystoreFile
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = if (hasValidKeystore && signingConfigs.findByName("release") != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("com.github.teamnewpipe:newpipeextractor:v0.26.5")
    implementation("androidx.work:work-runtime-ktx:2.9.1")
}

if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}
