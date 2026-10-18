plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.adelhajjaj.tasmo_hub"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.adelhajjaj.tasmo_hub"
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

    // F-Droid (and IzzyOnDroid) reject APKs that carry Google's encrypted
    // dependency metadata block, which only the Play Store can read.
    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }

    // CI writes the release keystore from repository secrets. One stable key
    // means each new APK installs over the previous one and keeps app data.
    // Without the secrets (local builds) it falls back to the debug key.
    // TASMOHUB_UNSIGNED=1 builds an unsigned release APK instead, which is
    // what F-Droid's build server expects before it signs with its own key.
    val unsigned = System.getenv("TASMOHUB_UNSIGNED") == "1"
    val releaseStore = System.getenv("TASMOHUB_KEYSTORE")?.let { file(it) }
    signingConfigs {
        if (releaseStore != null && releaseStore.exists()) {
            create("release") {
                storeFile = releaseStore
                storePassword = System.getenv("TASMOHUB_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("TASMOHUB_KEY_ALIAS")
                keyPassword = System.getenv("TASMOHUB_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (unsigned) null
                else signingConfigs.findByName("release")
                    ?: signingConfigs.getByName("debug")
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
