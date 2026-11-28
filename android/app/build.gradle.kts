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
        versionCode = 200
        // 2026-11-16（113）：版本名跟着 build 走（112 → 1.1.02，113 → 1.1.03）；
        // 界面上只显示 versionName，versionCode 只给系统覆盖安装用。
        // 2026-11-24：1.1.91 → 1.1.92，带「App 内直接下载安装 APK」，开更新提醒。
        // 2026-11-25：1.1.92 → 1.1.93，versionCode 192 → 193。
        // 2026-11-27：1.1.93 → 1.1.94。商城「额度」独立栏 + 会员单档 19.9 接入
        //             /v1/shop/order（与 iOS 同源），老 7/30/90 天档位全部下线。
        // 2026-11-27：1.1.95 → 1.1.96。聚合支付（不再选微信/支付宝，直接出码）；
        //             额度改「百分比 + 万 token」口径；线路收敛为 独立IP(4-4) 主 / 北京 备。
        // 2026-11-27：1.1.96 → 1.1.97。内置 CA 换成补全 keyUsage 的 v2（同一把 CA 密钥，
        // 老客户端照样验得过）；主线路 4-4 证书补齐 AKI/SKI，严格校验不再报链缺陷。
        // 2026-11-28：1.1.97 → 1.1.98。QQ 接入改成「扫码即绑」（不再手输六位码）；
        //             「发现 → 群聊」接上后台配置的官方群；充值到账自动检测。
        versionName = "1.1.100"
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
    // QQ 登录（2026-11-16，97）：坐标 3.53.0（3.52.0 用 apache http，Android 9+ 必崩），只在阿里云镜像上有。
    // 客户端只需要 AppID；AppKey 在服务端 .env（进 APK 等于泄漏）。
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")
    // 扫码（2026-11-13）：只引解码核心，相机用系统 `android.hardware.Camera`，
    // 不再拉 CameraX 那一串依赖 —— 包体只涨 ~500KB。
    implementation("com.google.zxing:core:3.5.3")
}
