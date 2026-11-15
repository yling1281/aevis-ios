import java.util.Properties

// 正式签名的参数放在 `android/keystore.properties`（不进 git）。
// 文件不在就回退 debug 签名 —— CI 上没有密钥也能出包，只是那个包不能覆盖安装线上版。
val ksProps = Properties().apply {
    val f = rootProject.file("keystore.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasReleaseKey = (ksProps.getProperty("storeFile") ?: "").isNotEmpty()

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.aevis.android"
    compileSdk = 36
    // 共享 C++ 底层（shared-core/aevis_core.cpp）
    ndkVersion = "26.1.10909125"

    defaultConfig {
        applicationId = "com.aevis.android"
        minSdk = 26
        targetSdk = 34
        versionCode = 27
        versionName = "1.0.0"
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(ksProps.getProperty("storeFile"))
                storePassword = ksProps.getProperty("storePassword")
                keyAlias = ksProps.getProperty("keyAlias")
                keyPassword = ksProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // 有正式密钥就用正式的；没有（比如 CI）才退回 debug，保证还能出包。
            signingConfig = if (hasReleaseKey) signingConfigs.getByName("release")
                            else signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // 先出可安装的 debug 包，签名在 CI 里用 debug key（侧载够用）
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    // BuildConfig 默认不生成（AGP 8），版本号要显示在「我」页，得打开
    buildFeatures { compose = true; buildConfig = true }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2024.09.00"))
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.annotation:annotation:1.8.2")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")
    // 扫码（2026-11-13）：只引解码核心，相机用系统 `android.hardware.Camera`，
    // 不再拉 CameraX 那一串依赖 —— 包体只涨 ~500KB。
    implementation("com.google.zxing:core:3.5.3")
}
