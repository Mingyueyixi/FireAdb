# adb_usb

`package:adb_core` 的 USB 传输层。桌面端通过 `dart_libusb` 打开 ADB 批量接口。

Windows 已实现枚举、声明 WinUSB 接口和 ADB 握手，并由本机 ADB Server 登记到设备列表。Linux / macOS 尚未随包提供 libusb，也未做真机验证。Android USB Host 尚未接入。

方案说明见 [docs/usb.md](docs/usb.md)。实现过程中的问答见 [docs/usb-qa.md](docs/usb-qa.md)。

## 依赖

- `adb_core`（workspace 内路径依赖）
- `dart_libusb`
- `ffi`

## 相关

- 仓库根 `README.md`：整体架构与实现路线
- `packages/adb_core`：协议引擎与本机 ADB Server
