# FireAdb

跨平台 ADB 工具箱（可不调用系统 adb 二进制，协议自实现）。

## 平台

- Windows / Linux / macOS：Flutter，桌面 USB 走 libusb
- Android：Flutter，设备列表走本机 5037

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
