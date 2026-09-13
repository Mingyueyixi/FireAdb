# adb_usb

`package:adb_core` 的 **USB 传输层**实现：让 ADB 会话直接跑在 USB 上，而不是 TCP。

> 状态：规划中（尚未实现）。对应仓库实现路线第 7、8 步。

## 计划能力

| 平台 | 依赖 | 说明 |
|---|---|---|
| Windows / Linux / macOS | [`dart_libusb`](https://pub.dev/packages/dart_libusb) | USB 设备枚举 + bulk 传输；Windows 需 WinUSB 驱动、Linux 需 udev 规则、macOS 需相机/串口权限例外 |
| Android | `android.hardware.usb` | 插件化的 USB Host 访问 |

两种实现最终都实现 `package:adb_core` 的 `AdbTransport` 接口，从而与内置的
`AdbTcpTransport` 保持一致的上层调用方式。

## 依赖

- `adb_core`（workspace 内路径依赖）
- `dart_libusb`

## 用法

待 API 落地后补充，届时见 `example/`。

## 相关

- 仓库根 `README.md`：整体架构与实现路线
- `packages/adb_core`：协议引擎
