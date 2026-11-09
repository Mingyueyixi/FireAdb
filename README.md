# FireAdb

跨平台 ADB 工具箱（可不调用系统 adb 二进制，协议自实现）。

## 平台

- Windows / Linux / macOS：Flutter，桌面 USB 走 libusb
- Android：Flutter，设备列表走本机 5037

## 功能

**设备连接**

- 设备列表：USB / 模拟器 / 无线设备统一展示，支持自动刷新（间隔可配、可后台刷新）
- 无线调试（Android 11+）：mDNS 发现服务，配对码配对 / 二维码扫码配对，配对后自动连接
- 手动连接：输入主机地址与端口直连；历史连接快速重连

**设备工作区**（连接后按设备打开，断线自动重连）

- 设备总览：型号、品牌、制造商、系统版本、API 级别等基本信息
- 设备应用：查看已安装应用、导出 APK、卸载与冻结
- 文件传输：推送文件到设备 / 从设备拉取文件
- 文件管理：浏览设备文件，支持删除、重命名、复制粘贴、编辑、搜索、改权限、导出和上传
- 截图：screencap 截取屏幕，PNG 保存到本机
- 录屏：可选系统或内置录屏，保存到本机
- 命令面板：执行 adb shell 命令并查看输出

## 源码

`third_party/` 是参考源（git submodule），不参与构建。需要对照时再 `git submodule update --init --recursive`。

## 开发

pub workspace，命令在仓库根执行。

| 目的 | 命令 |
|---|---|
| 拉取依赖 | `flutter pub get` |
| 静态分析 | `dart analyze` |
| 格式化 | `dart format .` |
| adb_core 测试 | `dart test packages/adb_core` |
| 应用测试 | `flutter test app` |
| 运行 | `cd app && flutter run` |

## 编译环境

- Dart SDK：`^3.13.1`
- Flutter：3.48
- JDK：17
- Android Gradle Plugin：9.1.0
- Kotlin：2.4.0
- Gradle：9.4.1
- NDK：Flutter 默认版本
- 应用字节码：Java 17
- `fire_app_service` 字节码：Java 8
- `app/android/gradlew`、`gradlew.bat` 已修改：启动 Java 前读取 `app/android/local.properties` 的 `org.gradle.java.home`，覆盖 `JAVA_HOME`。

```properties
org.gradle.java.home=C:/Program Files/Java/jdk-17
```

- Zig + Ninja + Python：仅 Linux 交叉编译 `fire_usb` 时需要（在 Windows / macOS 上产出 Linux 各架构 `.so`）。
  全平台一键编译（Windows x64/arm64 + Linux x64/arm64，产物进 `vendor/`）：
  `python packages/libadb/native/fire_usb/tool/build_all.py`；
  只编 Linux 换成 `tool/build_linux.py`，只编 Windows（无需 Zig/Ninja）换成 `tool/build_windows.py`。
  工具清单与细节见 [`packages/libadb/native/fire_usb/README.md`](packages/libadb/native/fire_usb/README.md#linux-交叉编译zig)。
