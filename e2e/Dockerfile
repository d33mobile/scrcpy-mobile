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

WORKDIR /workspace
