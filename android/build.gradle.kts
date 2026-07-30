buildscript {
    repositories {
        google()
        mavenCentral()
        maven(url = "https://jitpack.io")
    }
    dependencies {
        classpath("com.android.tools.build:gradle:8.11.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.2.20")
        classpath("com.google.gms:google-services:4.4.2")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
        maven(url = "https://jitpack.io")
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Align JVM target across ALL plugin subprojects to avoid
// "Inconsistent JVM Target Compatibility" errors (e.g. disk_space).
// NOTE: Only align the Kotlin jvmTarget here. Do NOT force
// sourceCompatibility/targetCompatibility on the Android plugins'
// JavaCompile tasks: doing so makes Gradle drop AGP's android.jar
// bootclasspath, causing "package android does not exist" errors
// for Java-based plugins (open_filex, flutter_background_service_android).
gradle.projectsEvaluated {
    subprojects {
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }
        tasks.withType<JavaCompile>().configureEach {
            sourceCompatibility = "17"
            targetCompatibility = "17"
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

subprojects {
    plugins.withId("com.android.library") {
        val libraryExt = extensions.getByType<com.android.build.gradle.LibraryExtension>()
        libraryExt.compileOptions {
            sourceCompatibility = JavaVersion.VERSION_17
            targetCompatibility = JavaVersion.VERSION_17
        }
    }

    val proj = this
    val setNamespace: () -> Unit = {
        val androidExt = proj.extensions.findByName("android")
        if (androidExt != null && androidExt is com.android.build.gradle.LibraryExtension) {
            if (androidExt.namespace == null) {
                val groupStr = proj.group.toString()
                androidExt.namespace = if (groupStr.isNotEmpty()) groupStr else "com.example.plugin.\${proj.name}"
            }
        }
    }
    
    if (proj.state.executed) {
        setNamespace()
    } else {
        proj.afterEvaluate {
            setNamespace()
        }
    }
}