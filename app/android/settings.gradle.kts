pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        // 解析 Gradle 插件（AGP / Kotlin / flutter-plugin-loader）用，与下面的
        // dependencyResolutionManagement 是两套独立配置，两者都要配镜像。
        maven {
            url = uri("https://maven.aliyun.com/repository/gradle-plugin")
        }
        maven {
            url = uri("https://maven.aliyun.com/repository/google")
        }
        maven {
            url = uri("https://maven.aliyun.com/repository/public")
        }
        maven {
            url = uri("https://mirrors.cloud.tencent.com/nexus/repository/maven-public/")
            content {
                // 腾讯云该仓库不代理 jitpack/github/gitee，也不含 Flutter 引擎产物，
                // 声明出来可避免这些坐标在这里白白 404 一轮。
                excludeGroupByRegex("com\\.github.*")
                excludeGroupByRegex("com\\.gitee.*")
                excludeGroupByRegex("com\\.gitlab.*")
                excludeGroupByRegex("org\\.bitbucket.*")
                excludeGroupByRegex("org\\.azure.*")
                excludeGroupByRegex("io\\.flutter.*")
            }
        }
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("com.android.library") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

dependencyResolutionManagement {
    // 约定：仓库全部集中在 settings 里管理，各子工程不再自行声明。
    // 注意 PREFER_SETTINGS 的语义是「忽略项目中声明的仓库」，不是「settings 优先、project 兜底」，
    // 因此凡是原先靠项目级 repositories 注入的仓库，都必须在这里补上（下面第一条就是）。
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)

    repositories {
        // Flutter 引擎产物仓库。io.flutter:armeabi_v7a_debug / arm64_v8a_debug /
        // flutter_embedding_debug 等只发布在这里，Maven Central 与 Google 都没有。
        //
        // 官方地址是 https://storage.googleapis.com/download.flutter.io，
        // 这里用国内镜像 https://storage.flutter-io.cn/download.flutter.io（已实测可用）。
        // flutter-gradle-plugin 拼 URL 的规则是
        //   ${FLUTTER_STORAGE_BASE_URL ?: "https://storage.googleapis.com"}/${engineRealm}download.flutter.io
        // 本机 $FLUTTER_SDK/bin/cache/engine.realm 为空，故无 engineRealm 前缀。
        // 若日后 flutter 工具改从别的域名取引擎产物，这里需同步修改。
        maven {
            url = uri("https://storage.flutter-io.cn/download.flutter.io")
            content {
                // 该仓库只发布 io.flutter 组，限定范围可省去其它坐标的无谓查询。
                includeGroupByRegex("io\\.flutter.*")
            }
        }
        maven {
            url = uri("https://maven.aliyun.com/repository/google")
        }
        maven {
            url = uri("https://maven.aliyun.com/repository/public")
        }
        maven {
            url = uri("https://mirrors.cloud.tencent.com/nexus/repository/maven-public/")
            content {
                // 说明：此镜像不代理 jitpack/github/gitee；若后续引入此类依赖，
                // 必须为其单独保留原始 URL，切勿指向本镜像。
                excludeGroupByRegex("com\\.github.*")
                excludeGroupByRegex("com\\.gitee.*")
                excludeGroupByRegex("com\\.gitlab.*")
                excludeGroupByRegex("org\\.bitbucket.*")
                excludeGroupByRegex("org\\.azure.*")
                excludeGroupByRegex("io\\.flutter.*")
            }
        }
        google()
        mavenCentral()
    }
}

// Flutter 插件工程（如 shared_preferences_android）自带 legacy buildscript 块，里面只写了
// google()/mavenCentral()。pluginManagement 里的镜像对它无效，会直连 dl.google.com 下载 AGP 8.13.1 并超时：
//   Could not download builder-8.13.1.jar (com.android.tools.build:builder:8.13.1) > Read timed out
// buildscript 类路径不受上面的 dependencyResolutionManagement 管辖，唯一生效的位置是
// 「该工程自己的 buildscript 仓库列表」，这里在每个工程求值前插到最前面（顺序靠前优先）。
gradle.beforeProject {
    buildscript.repositories.apply {
        maven {
            url = uri("https://maven.aliyun.com/repository/google")
        }
        maven {
            url = uri("https://maven.aliyun.com/repository/public")
        }
        maven {
            url = uri("https://mirrors.cloud.tencent.com/nexus/repository/maven-public/")
        }
    }
}

include(":app")
include(":fire_app_service")
