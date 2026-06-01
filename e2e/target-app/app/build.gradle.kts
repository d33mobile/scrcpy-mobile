plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "net.scrcpy.e2etarget"
    compileSdk = 36

    defaultConfig {
        applicationId = "net.scrcpy.e2etarget"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    // No AndroidX / appcompat: a deliberately minimal, dependency-free target so
    // the APK builds fast and has no extra views to confuse uiautomator dumps.
}
