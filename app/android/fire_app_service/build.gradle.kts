plugins {
    id("com.android.application")
}

// 可编译、可在 Android Studio 里解析框架类。不安装到手机。
// classes.dex 由 AGP 的打包流程生成，再装进 app_process 用的 jar。
// 改了本模块源码后，把 service.version 加一，Flutter 构建才会重新打 jar。
val serviceVersionFile = layout.projectDirectory.file("service.version")
val serviceVersion = serviceVersionFile.asFile.readText().trim()

android {
    namespace = "com.fire.adb.appservice"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.fire.adb.appservice"
        minSdk = 21
        targetSdk = 36
        versionCode = serviceVersion.toIntOrNull() ?: 1
        versionName = serviceVersion
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    lint {
        checkReleaseBuilds = false
    }
}

// 只打包本模块自己的 dex。release APK 里的 classes.dex 还会并进 Kotlin 标准库，
// app_process 用不到，体积会到 2MB 以上。
val builtVersionFile = rootProject.layout.projectDirectory.file(
    "../assets/fire-app-service.version",
)

tasks.register<Zip>("packageAppServiceJar") {
    group = "build"
    description = "把 AGP dexBuilder 产出的工程 dex 装进 fire-app-service.jar。"
    dependsOn("dexBuilderRelease")
    inputs.file(serviceVersionFile)
    archiveFileName.set("fire-app-service.jar")
    destinationDirectory.set(rootProject.layout.projectDirectory.dir("../assets"))
    doLast {
        val stamp = builtVersionFile.asFile
        stamp.parentFile.mkdirs()
        stamp.writeText(serviceVersion + "\n")
    }
    val dexOut = layout.buildDirectory.dir(
        "intermediates/project_dex_archive/release/dexBuilderRelease/out",
    )
    var dexIndex = 0
    from(dexOut) {
        include("**/*.dex")
        eachFile {
            val entry = if (dexIndex == 0) "classes.dex" else "classes${dexIndex + 1}.dex"
            dexIndex += 1
            path = entry
        }
    }
    includeEmptyDirs = false
}

tasks.named("assemble") {
    finalizedBy("packageAppServiceJar")
}
