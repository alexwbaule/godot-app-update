// GodotAppUpdate — Android plugin (Godot 4 Android plugin v2) for Google Play In-App Updates.
//
// Build: ./gradlew assemble   (or ./gradlew copyToAddon to also copy the .aar files into ../addons)

plugins {
    id("com.android.library")
}

val pluginName = "GodotAppUpdate"
val pluginPackageName = "io.github.alexwbaule.godotappupdate"

// Versions used by the AAR. The Godot library is compileOnly: the game provides it at runtime.
val godotVersion = "4.7.2.stable"
val playAppUpdateVersion = "2.1.0"

android {
    namespace = pluginPackageName
    compileSdk = 36

    defaultConfig {
        consumerProguardFiles("consumer-rules.pro")
        minSdk = 24
        manifestPlaceholders["godotPluginName"] = pluginName
        manifestPlaceholders["godotPluginPackageName"] = pluginPackageName
        buildConfigField("String", "GODOT_PLUGIN_NAME", "\"$pluginName\"")
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

base {
    archivesName.set(pluginName)
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    compileOnly("org.godotengine:godot:$godotVersion")
    // Must match ANDROID_DEPENDENCIES in addons/app_update/plugin.gd.
    implementation("com.google.android.play:app-update:$playAppUpdateVersion")
}

// Copies the built AARs to ../addons/app_update/bin/{debug,release}/ (the layout the editor plugin expects).
val copyDebugAARToAddon by tasks.registering(Copy::class) {
    description = "Copies the debug AAR into the addon"
    from("build/outputs/aar")
    include("$pluginName-debug.aar")
    into("../../addons/app_update/bin/debug")
}

val copyReleaseAARToAddon by tasks.registering(Copy::class) {
    description = "Copies the release AAR into the addon"
    from("build/outputs/aar")
    include("$pluginName-release.aar")
    into("../../addons/app_update/bin/release")
}

tasks.register("copyToAddon") {
    description = "Builds both AARs and copies them into ../addons/app_update/bin"
    group = "godot"
    dependsOn("assemble")
    finalizedBy(copyDebugAARToAddon, copyReleaseAARToAddon)
}
