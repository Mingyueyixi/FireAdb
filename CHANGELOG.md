# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 与
[语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Added

- 设备应用管理：列出已安装应用（图标/大小/路径/名称/版本），支持导出 APK、卸载、多种冻结方式（`pm disable-user` / `pm suspend` / `am freeze`），默认过滤系统应用。
- 工作区共享静态分析配置（根 `analysis_options.yaml`），各成员包继承。
- 补充 `.editorconfig`、`.gitattributes`。

### Changed

- 项目更名为 **FireAdb**：Flutter 应用包名 `adb_toolbox` → `fire_adb`、工作区根 `adb_toolbox_workspace` → `fire_adb_workspace`、Android `namespace`/`applicationId` `com.adbtoolbox.adb_toolbox` → `com.fire.adb`，并同步 Windows / Linux / macOS 的产物名、bundle id 与应用显示名。
- 应用数据目录 `~/.config/adb_toolbox` → `~/.config/fire_adb`（首次运行会重新生成 ADB 密钥，设备需重新授权）。
- `third_party/` 由「手动 clone + 忽略」改为 **git submodule**（aosp-adb、python-adb）。
- `adb_core` / `adb_usb` / `app` 移除 `dart create` 模板残留，重写各包 README。

### Removed

- 误提交的 Gradle 探测缓存（`app/.gradle-probe*`）。
- `adb_core/tool/` 下带本机硬编码路径的一次性调试脚本及其生成产物。

## [0.1.0]

- 项目初始化：Flutter 应用 + `adb_core`（纯协议引擎）+ `adb_usb`（USB 传输骨架）。
