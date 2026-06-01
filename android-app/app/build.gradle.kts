plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "net.scrcpy.android"
    compileSdk = 36
    // Pin to the build-tools baked into scrcpy-e2e:dev (e2e/Dockerfile). Without
    // this, AGP 8.7.3 defaults to build-tools 34.0.0 and silently downloads it
    // from dl.google.com at build time — breaking hermetic / offline runs.
    buildToolsVersion = "37.0.0"

    defaultConfig {
        applicationId = "net.scrcpy.android"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1-wip"

        ndk {
            // x86_64 = the emulator target (the proven, e2e-green path).
            // arm64-v8a = real-device ABI (M4 stretch): the native stack
            // cross-compiles + libscrcpy.so links as AArch64 (ELF/symbol-proven),
            // but is NOT yet tested on real hardware. abiFilters is a *filter*:
            // each ABI is only packaged when its jniLibs/<abi>/*.so are staged
            // (see stage-natives.sh <OUTPUT_DIR> <abi>), so listing both here is
            // safe for the x86_64-only e2e build (it stages x86_64 only).
            abiFilters += "x86_64"
            abiFilters += "arm64-v8a"
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
