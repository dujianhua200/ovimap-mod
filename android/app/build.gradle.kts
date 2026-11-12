import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.dujianhua.ovimap"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.dujianhua.ovimap"
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

    // 签名 keystore 解析优先级（详见 docs/BUILD-cloud.md）：
    // ① android/key.properties（CI 由 Secret 还原；本机也可自建）
    // ② 本机既有的旧工程 debug.keystore 绝对路径（历史遗留，保持「能覆盖安装」）
    // ③ 都没有 → 退回 AGP 内置 debug 签名（保证任何环境都能出一个可安装包）
    signingConfigs {
        val legacyKeystorePath = "/Users/dujianhua200/Doubao/滑洲云图/outputs/ManualApp/debug.keystore"
        val keystorePropsFile = rootProject.file("key.properties")
        if (keystorePropsFile.exists()) {
            // CI Secret 还原 / 本机自建：四个字段都从 key.properties 读。
            val props = Properties()
            keystorePropsFile.inputStream().use { props.load(it) }
            create("ovimap") {
                // ⚠️ 关键：用 rootProject.file 解析 storeFile，而非 file()。
                // android{} 里的 file() 相对 android/app/，本机 keystore 放在 android/
                // 根，用 file() 会错位导致 "storeFile not found"。
                fun req(key: String): String =
                    props.getProperty(key)
                        ?: error("android/key.properties 缺少必填字段「$key」（应有 storeFile / storePassword / keyAlias / keyPassword 四项）")
                storeFile = rootProject.file(req("storeFile"))
                storePassword = req("storePassword")
                keyAlias = req("keyAlias")
                keyPassword = req("keyPassword")
            }
        } else if (file(legacyKeystorePath).exists()) {
            // 历史遗留：本机旧工程 keystore 绝对路径（绝对路径，file() 直接命中），
            // 保持「与旧版 Java 工程同一签名：真机可直接覆盖安装，旧数据无缝保留」。
            create("ovimap") {
                storeFile = file(legacyKeystorePath)
                storePassword = "android"
                keyAlias = "androiddebugkey"
                keyPassword = "android"
            }
        }
        // 两者都不存在：不创建 ovimap（缺 storeFile 会让 AGP 直接报错）。
        // buildTypes 见下，自动回退到 AGP 内置 debug 签名。
    }

    buildTypes {
        // 有 ovimap 用 ovimap；都没有时回退 AGP 内置 debug 签名
        // （AGP 会自动生成 ~/.android/debug.keystore，能出包、能安装，
        //  但签名与用户手机上的旧版不同 —— 覆盖安装会报 INSTALL_FAILED_UPDATE_INCOMPATIBLE，
        //  需先卸载再装，现场数据会丢；详见 docs/BUILD-cloud.md）。
        val ovimapConfig = signingConfigs.findByName("ovimap")
        debug {
            signingConfig = ovimapConfig ?: signingConfigs.getByName("debug")
        }
        release {
            // 与旧版 Java 工程同一签名：真机可直接覆盖安装，旧数据无缝保留。
            // CI 通过 key.properties 注入同一个 keystore，保证签名一致性（见 docs/BUILD-cloud.md）。
            // 都没有 keystore 时回退 AGP 内置 debug 签名：能出可安装包，但签名与手机旧版不同。
            signingConfig = ovimapConfig ?: signingConfigs.getByName("debug")
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
