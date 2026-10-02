import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// 作者: long
// Kotlin 预览包和 Flutter 正式包共用同一套本地签名约定；没有密钥时仍允许构建测试包，
// 但不会把 debug 证书误标成正式分发签名。真实 key.properties 由 .gitignore 排除。
val signingProperties = Properties()
val signingPropertiesFile = rootProject.file("key.properties")
if (signingPropertiesFile.isFile) {
    signingPropertiesFile.inputStream().use { signingProperties.load(it) }
}
val hasReleaseKeystore = listOf(
    "storeFile",
    "storePassword",
    "keyAlias",
    "keyPassword",
).all { signingProperties[it]?.toString()?.isNotBlank() == true }

android {
    namespace = "dev.fluxdown.android"
    compileSdk = 36

    // 作者: long
    // 日常回归继续使用 Debug 变体；只有 Release 验收显式打开开关时，才生成
    // releaseTest instrumentation，避免普通 connectedDebugAndroidTest 被混淆产物拖慢。
    testBuildType = if (project.findProperty("fluxdownReleaseInstrumentation") == "true") {
        "releaseTest"
    } else {
        "debug"
    }

    defaultConfig {
        applicationId = "dev.fluxdown.mobile.kotlin"
        minSdk = 24
        targetSdk = 36
        versionCode = 2033
        versionName = "1.0.28-kotlin-alpha.6"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        testProguardFiles("test-proguard-rules.pro")

        ndk {
            // 作者: long
            // Kotlin 迁移预览先锁定 arm64，避免在验证阶段重新引入旧架构的 native 体积。
            abiFilters += "arm64-v8a"
        }
    }

    signingConfigs {
        create("release") {
            if (hasReleaseKeystore) {
                keyAlias = signingProperties["keyAlias"] as String
                keyPassword = signingProperties["keyPassword"] as String
                storeFile = file(signingProperties["storeFile"] as String)
                storePassword = signingProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }

        // 作者: long
        // releaseTest 复用正式 Release 的 R8/资源收缩规则，但保持可调试并使用独立包名，
        // 这样可以在不覆盖用户安装的 Release APK 的情况下运行 connected instrumentation，
        // 直接验证混淆后的 JNI、队列和协议入口，而不是把 Debug 测试 APK 强行套到 Release 包上。
        create("releaseTest") {
            initWith(getByName("release"))
            applicationIdSuffix = ".releaseTest"
            isDebuggable = false
            signingConfig = signingConfigs.getByName("debug")
            proguardFile("release-test-proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
    }

    packaging {
        jniLibs {
            useLegacyPackaging = false
        }
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.16.0")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.documentfile:documentfile:1.0.1")
    implementation("androidx.camera:camera-camera2:1.5.3")
    implementation("androidx.camera:camera-lifecycle:1.5.3")
    implementation("androidx.camera:camera-view:1.5.3")
    implementation("com.google.mlkit:barcode-scanning:17.3.0")
    implementation("androidx.compose.ui:ui:1.7.5")
    implementation("androidx.compose.ui:ui-tooling-preview:1.7.5")
    implementation("androidx.compose.foundation:foundation:1.7.5")
    implementation("androidx.compose.material3:material3:1.3.1")
    implementation("androidx.compose.material:material-icons-extended:1.7.5")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    // 作者: long
    // releaseTest 会对测试 APK 也执行 R8；AndroidX Test 的 tracing 代码把这两个
    // 可选类型作为签名引用，显式放进测试 classpath，避免 Release 验收在打包阶段失败。
    androidTestImplementation("androidx.concurrent:concurrent-futures:1.1.0")
    androidTestImplementation("com.google.errorprone:error_prone_annotations:2.36.0")
    androidTestImplementation("androidx.tracing:tracing:1.2.0")
    androidTestImplementation("com.google.zxing:core:3.4.1")
    debugImplementation("androidx.compose.ui:ui-tooling:1.7.5")
}
