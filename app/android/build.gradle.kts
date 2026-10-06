// 依赖仓库统一在 settings.gradle.kts 的 dependencyResolutionManagement 中声明
// （repositoriesMode = PREFER_SETTINGS）。原先这里的 allprojects { repositories { … } }
// 在 PREFER_SETTINGS 下会被整体忽略，只会产生
//   "Build was configured to prefer settings repositories over project repositories but
//    repository 'maven' was added by build file 'build.gradle.kts'"
// 这类噪声警告，故移除；需要新增仓库请改 settings.gradle.kts。

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    if (name == "fire_app_service") {
        return@subprojects
    }
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
