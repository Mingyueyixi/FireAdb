# adb_usb

`package:adb_core` 的 USB 传输层。桌面端通过 `dart_libusb` 打开 ADB 批量接口。

Windows 已实现枚举、声明 WinUSB 接口和 ADB 握手，并由本机 ADB Server 登记到设备列表。`hook/build.dart` 按构建目标把 Windows x64 或 ARM64 的 `libusb-1.0.dll` 登记为随包代码资源，引用方不用再改 CMake。Linux / macOS 登记系统库名 `libusb-1.0.so.0`、`libusb-1.0.dylib`，仓库里没有这两份动态库，也未做真机验证。Android 不提供 USB。应用侧的组装在 `libadb`。

方案说明见 [docs/usb.md](docs/usb.md)。实现过程中的问答见 [docs/usb-qa.md](docs/usb-qa.md)。

## 依赖

- `adb_core`（workspace 内路径依赖）
- `dart_libusb`
- `ffi`

## 相关

- 仓库根 `README.md`：整体架构与实现路线
- `packages/adb_core`：协议引擎与本机 ADB Server
