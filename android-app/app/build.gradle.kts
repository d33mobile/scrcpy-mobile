plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "net.scrcpy.android"
    compileSdk = 36

    defaultConfig {
        applicationId = "net.scrcpy.android"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1-wip"

        ndk {
            // x86_64 only for now (emulator target); arm64-v8a comes at M4.
            abiFilters += "x86_64"
        }
    }

    sourceSets {
        named("main") {
            // Vendored SDL2 Android Java glue (org.libsdl.app.*). The dir is the
            // source root containing org/libsdl/app/*.java.
            java.srcDir("../../porting/vendor/sdl-android-java")
            // jniLibs default is src/main/jniLibs; the native .so are staged there
            // by stage-natives.sh before assembleDebug (gitignored build artifacts).
            jniLibs.srcDir("src/main/jniLibs")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
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
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
}
