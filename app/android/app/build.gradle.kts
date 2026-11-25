plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.github.mrkleeblatt.mync"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.github.mrkleeblatt.mync"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Fester Signaturschlüssel aus der Umgebung (Workflow „Release“, Secrets
    // KEYSTORE_BASE64/KEYSTORE_PASSWORD/KEY_ALIAS/KEY_PASSWORD). Ohne ihn wird
    // mit dem Debug-Schlüssel signiert – dann lassen sich spätere Versionen
    // nicht über diese installieren.
    val keystoreFile = System.getenv("KEYSTORE_FILE")?.takeIf { it.isNotEmpty() }
    signingConfigs {
        if (keystoreFile != null) {
            create("release") {
                storeFile = file(keystoreFile)
                storePassword = System.getenv("KEYSTORE_PASSWORD")
                keyAlias = System.getenv("KEY_ALIAS")
                keyPassword = System.getenv("KEY_PASSWORD")?.takeIf { it.isNotEmpty() }
                    ?: System.getenv("KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(
                if (keystoreFile != null) "release" else "debug",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// ─── mync-Kern (Zig) ────────────────────────────────────────────────────────
// Baut core/ für alle Android-ABIs mit `zig build` gegen die libc des NDK und
// legt libmync_core.so als jniLib ab. Voraussetzung: `zig` im PATH.
val myncCoreDir = file("../../../core")
val myncJniLibs = layout.buildDirectory.dir("mync_core/jniLibs")
// Flutter-Zielplattform → (ABI, Zig-Ziel)
val myncPlatforms = mapOf(
    "android-arm64" to ("arm64-v8a" to "aarch64-linux-android"),
    "android-arm" to ("armeabi-v7a" to "arm-linux-androideabi"),
    "android-x64" to ("x86_64" to "x86_64-linux-android"),
)
// Nur für die ABIs bauen, für die Flutter baut (`--target-platform` kommt als
// -Ptarget-platform an, `flutter run` setzt es fürs Gerät); ohne Angabe alle.
// Jede ABI kostet im CI Minuten.
val myncAbis = ((findProperty("target-platform") as String?)?.split(",") ?: myncPlatforms.keys)
    .mapNotNull { myncPlatforms[it.trim()] }
    .toMap()
val myncMinApi = 24

val buildMyncCore by tasks.registering {
    group = "build"
    description = "Baut den mync-Kern (Zig) für die Android-ABIs des Builds"
    inputs.dir(myncCoreDir.resolve("src"))
    inputs.file(myncCoreDir.resolve("build.zig"))
    inputs.property("abis", myncAbis.keys.sorted())
    outputs.dir(myncJniLibs)
    doLast {
        // keine .so eines früheren Builds für andere ABIs mitverpacken
        myncJniLibs.get().asFile.deleteRecursively()
        val ndk = android.ndkDirectory.absolutePath
        myncAbis.forEach { (abi, triple) ->
            val prefix = layout.buildDirectory.dir("mync_core/$abi").get().asFile
            providers.exec {
                workingDir = myncCoreDir
                commandLine(
                    "zig", "build",
                    "-Dtarget=$triple.$myncMinApi",
                    "-Doptimize=ReleaseSafe",
                    "-Dandroid-ndk=$ndk",
                    "--prefix", prefix.absolutePath,
                )
            }.result.get()
            val target = myncJniLibs.get().dir(abi).file("libmync_core.so").asFile
            target.parentFile.mkdirs()
            prefix.resolve("lib/libmync_core.so").copyTo(target, overwrite = true)
        }
    }
}

android.sourceSets.getByName("main").jniLibs.srcDir(myncJniLibs.get().asFile)
tasks.named("preBuild") { dependsOn(buildMyncCore) }

dependencies {
    implementation("androidx.core:core:1.13.1") // FileProvider für die Installation von Updates
}
