// Top-level build file. Plugin versions pinned to the SAME known-good combo as
// android-app/ and target-app/ (AGP 8.7.3 + Gradle 8.9 + Kotlin 2.0.21), so this
// standalone draw project builds with the identical toolchain in the e2e container.
plugins {
    id("com.android.application") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
}
