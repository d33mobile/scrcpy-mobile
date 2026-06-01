# Android e2e image for scrcpy-mobile: builds the android-app debug APK AND runs
# two headless x86_64 emulators (B = target running scrcpy-server, A = controller
# running our client). One image does both jobs so the harness has a single,
# hermetic, version-pinned environment.
#
# Derived from the proven d-claude sibling images (material-files-build:dev +
# mf-e2e-emulator:dev): same eclipse-temurin:21-jdk + cmdline-tools + sdkmanager
# pattern, extended with the system-image + headless-emulator deps.
#
# Must be run with `--device /dev/kvm` so the x86_64 emulators get hardware
# acceleration; without KVM the AVDs are unusably slow / will not boot in time.
FROM eclipse-temurin:21-jdk

# ANDROID_HOME is the modern var; ANDROID_SDK_ROOT kept for tools that still read
# the legacy name. noninteractive so apt never blocks the build on a prompt.
ENV ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_HOME=/opt/android-sdk \
    DEBIAN_FRONTEND=noninteractive

# Two groups of apt deps, in one layer to keep the image lean:
#  - build/util: unzip (cmdline-tools zip), wget/ca-certificates (SDK downloads),
#    git (Gradle version plugins), apksigner (sign the debug APK).
#  - headless-emulator runtime: the qemu-based emulator links these X11/audio/GL
#    libs even with -no-window, so they must exist or it crashes at startup.
#    This is exactly the set the proven mf-e2e-emulator image installs; libxdamage1
#    and libxrandr2 are added because the official android-emulator-container-scripts
#    pull them too and some system-images dlopen them.
RUN apt-get update && apt-get install -y --no-install-recommends \
        unzip wget git ca-certificates apksigner \
        libpulse0 libnss3 libxcomposite1 libxcursor1 libxdamage1 \
        libxi6 libxtst6 libxrandr2 libgl1 libasound2t64 \
    && rm -rf /var/lib/apt/lists/*

# Android command-line tools (sdkmanager/avdmanager). Pinned to the same
# 11076708 build the sibling images use so the toolchain is reproducible.
RUN mkdir -p ${ANDROID_SDK_ROOT}/cmdline-tools \
    && wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -O /tmp/cmdline.zip \
    && unzip -q /tmp/cmdline.zip -d ${ANDROID_SDK_ROOT}/cmdline-tools \
    && mv ${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools ${ANDROID_SDK_ROOT}/cmdline-tools/latest \
    && rm /tmp/cmdline.zip

# Put the SDK binaries on PATH so run.sh can call sdkmanager/avdmanager/adb/emulator
# without absolute paths.
ENV PATH=${PATH}:${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${ANDROID_SDK_ROOT}/emulator

# Accept licenses once, then install every pinned component. Exact-version pins
# (build-tools, ndk, cmake) keep the native cross-compile (M1) reproducible;
# floating only on platform-tools/emulator which Google ships as single-channel.
#  - platforms;android-36  : compileSdk/targetSdk 36 for android-app.
#  - build-tools;37.0.0     : matches the sibling build image.
#  - ndk;27.2.12479018      : pinned recent stable LTS NDK (r27c) for the porting/
#                             cross-compile in M1.
#  - cmake;3.22.1           : the NDK-bundled CMake version, as in the sibling.
#  - emulator + system-images;android-30;google_apis;x86_64 : known-good headless
#                             API 30 Google-APIs x86_64 system image for the two
#                             AVDs the e2e boots. API 30 is the most reliable
#                             headless boot under KVM in Docker.
RUN yes | sdkmanager --licenses >/dev/null \
    && sdkmanager \
        "platform-tools" \
        "platforms;android-36" \
        "build-tools;37.0.0" \
        "ndk;27.2.12479018" \
        "cmake;3.22.1" \
        "emulator" \
        "system-images;android-30;google_apis;x86_64"

# Pin the EMULATOR binary to build 11237101 (v33.1.24), overlaying the one
# sdkmanager installs (currently v36.5.11). The current emulator SEGFAULTS under
# KVM-in-Docker on this host: every launch (any -gpu / -cpu / -feature combo)
# stalls all vCPU threads ("detected a hanging thread 'QEMU2 CPU0 thread'. No
# response for ~19000 ms") right after "Starting QEMU main loop" and then
# core-dumps at ~40s, so the AVD never boots. v33.1.24 boots API 30 cleanly
# (~73s to sys.boot_completed) in the same container. We keep the sdkmanager
# `emulator` install above so its package.xml + shared libs land, then replace
# only the binaries with the pinned build (restoring package.xml so avdmanager
# still recognises the package). Empirically verified on d-claude 2026-06-01.
RUN cp ${ANDROID_SDK_ROOT}/emulator/package.xml /tmp/emu-package.xml \
    && wget -q https://dl.google.com/android/repository/emulator-linux_x64-11237101.zip -O /tmp/emu.zip \
    && rm -rf ${ANDROID_SDK_ROOT}/emulator \
    && unzip -q /tmp/emu.zip -d ${ANDROID_SDK_ROOT} \
    && cp /tmp/emu-package.xml ${ANDROID_SDK_ROOT}/emulator/package.xml \
    && rm /tmp/emu.zip /tmp/emu-package.xml \
    && emulator -version | grep -i "version" | head -1

# Native-build toolchain, baked so `bash e2e/run.sh` needs ZERO network apt at
# runtime (hermetic). This is the UNION of every package the per-run
# `apt-get install` in the build path used to add:
#   - run.sh ensure_build_tools : make meson nasm rsync socat pkg-config golang-go
#   - lib-net.sh / m3-net-diag* : socat
#   - porting/scripts/make-*-android.sh requirements (documented in their headers):
#       * ffmpeg   : nasm (x86 asm), pkg-config
#       * openssl  : perl (already in base image), make
#       * adb-mobile: make, go (boringssl codegen), a host C/C++ compiler (for the
#                     host protoc build) -> build-essential, and patch (apply the
#                     vendored adb patches; make-adb-mobile asserts `command -v patch`)
#       * scrcpy/sdl/adb cmake+ninja come from the Android-SDK cmake package above,
#         which the scripts put on PATH; ninja-build is also baked as a safety net.
# build-essential supplies gcc/g++/make; make/patch are kept explicit for clarity.
# IMPORTANT: this layer is APPENDED AFTER the expensive SDK/NDK/system-image layers
# so a rebuild only re-runs this apt layer and does NOT re-download the Android SDK.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential make nasm golang-go ninja-build pkg-config \
        patch socat rsync meson \
    && rm -rf /var/lib/apt/lists/*

# Pre-staged NATIVE SOURCE (hermeticity). The three native deps (FFmpeg, SDL2,
# OpenSSL) used to fetch their SOURCE over the network at cold-build time
# (make-ffmpeg-android.sh git-cloned FFmpeg, make-libsdl/openssl curled tarballs),
# so a truly cold `bash e2e/run.sh` under `--network none` failed at the first
# native step. We bake the EXACT pinned sources into the image here (image build
# MAY use the network — only the e2e RUNTIME must be hermetic); the build scripts
# honour $NATIVE_SRC_DIR and copy/extract from these instead of fetching, falling
# back to the network only when absent (so dev outside the image still works).
# Versions/URLs match the scripts 1:1 (FFmpeg release/6.0, SDL2 2.32.8,
# OpenSSL 1.1.1w) — nothing changes but provenance. The same source serves BOTH
# the x86_64 and arm64-v8a ABIs (per-ABI build trees are copied from it).
# APPENDED AFTER the SDK/NDK + apt layers so a rebuild keeps those layers CACHED.
ENV NATIVE_SRC_DIR=/opt/native-src
RUN mkdir -p ${NATIVE_SRC_DIR} \
    && git clone --depth 1 --branch release/6.0 \
        https://github.com/FFmpeg/FFmpeg.git ${NATIVE_SRC_DIR}/ffmpeg \
    && wget -q https://www.libsdl.org/release/SDL2-2.32.8.tar.gz \
        -O ${NATIVE_SRC_DIR}/SDL2-2.32.8.tar.gz \
    && ( wget -q https://www.openssl.org/source/old/1.1.1/openssl-1.1.1w.tar.gz \
        -O ${NATIVE_SRC_DIR}/openssl-1.1.1w.tar.gz \
       || wget -q https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1w/openssl-1.1.1w.tar.gz \
        -O ${NATIVE_SRC_DIR}/openssl-1.1.1w.tar.gz ) \
    && ls -la ${NATIVE_SRC_DIR}

# ---------------------------------------------------------------------------
# Pre-primed OFFLINE Gradle home (FULL COLD hermeticity).
# ---------------------------------------------------------------------------
# Even with the native source baked, a TRULY cold run (the persistent
# scrcpy-gradle-cache volume cleared / not mounted) still fetched the Gradle
# DISTRIBUTION (gradle-8.9-bin.zip from services.gradle.org) plus the AGP 8.7.3 /
# Kotlin 2.0.21 / AndroidX Maven artifacts from dl.google.com + repo.maven.* over
# the network -> UnknownHostException under `--network none`.
#
# Here we PRIME an offline GRADLE_USER_HOME=/opt/gradle-home at IMAGE-build time
# (network allowed during build; only the RUNTIME must be hermetic): we COPY the
# two real Gradle projects (android-app + e2e/target-app) and the SDL Java glue
# they reference, then run `assembleDebug` for BOTH with GRADLE_USER_HOME pointing
# at /opt/gradle-home. That single resolve downloads (a) the gradle-8.9 wrapper
# distribution into wrapper/dists, and (b) every AGP/Kotlin/AndroidX/Maven
# artifact the build needs into caches/modules-2 — exactly what a runtime
# `--offline` build replays. The native .so / scrcpy-server asset are NOT staged
# here (they're build artifacts) — assembleDebug simply packages an empty jniLibs /
# no scrcpy-server asset, which is fine: the SOLE purpose is populating the dep cache
# (the runtime build stages the real libs/assets and packages them).
#
# Requires the repo ROOT as the docker build context (see e2e/run.sh `outer`):
# COPY paths are repo-root-relative. The COPY'd projects live under /opt/prime and
# do NOT shadow the mounted /workspace at runtime — they only seed /opt/gradle-home.
ENV GRADLE_USER_HOME=/opt/gradle-home
COPY android-app /opt/prime/android-app
COPY e2e/target-app /opt/prime/target-app
COPY porting/vendor/sdl-android-java /opt/prime/porting/vendor/sdl-android-java
RUN set -eux; \
    sdk_cmake_dir="$(ls -d ${ANDROID_SDK_ROOT}/cmake/*/bin 2>/dev/null | sort -V | tail -1)"; \
    export PATH="$sdk_cmake_dir:$PATH"; \
    # android-app's sourceSets reference ../../porting/vendor/sdl-android-java; the
    # COPY above places it at /opt/prime/porting/vendor/... so the relative path
    # (/opt/prime/android-app -> ../../porting/...) resolves identically.
    ( cd /opt/prime/android-app \
        && ./gradlew --no-daemon assembleDebug ); \
    ( cd /opt/prime/target-app \
        && ./gradlew --no-daemon assembleDebug ); \
    # Stop any lingering daemon, drop the primed projects' build outputs (keep only
    # the populated /opt/gradle-home cache), and make the gradle home world-writable
    # so the runtime (non-root or root) can write lock files / new caches into it.
    ( cd /opt/prime/android-app && ./gradlew --stop >/dev/null 2>&1 || true ); \
    rm -rf /opt/prime/android-app/app/build /opt/prime/android-app/.gradle \
           /opt/prime/target-app/app/build /opt/prime/target-app/.gradle; \
    chmod -R a+rwX /opt/gradle-home; \
    ls /opt/gradle-home/wrapper/dists; \
    du -sh /opt/gradle-home

WORKDIR /workspace
