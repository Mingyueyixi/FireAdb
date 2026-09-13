/// adb_usb：`package:adb_core` 的 USB 传输层实现。
///
/// 该包目前**尚未实现**（见仓库 README 的实现路线第 7、8 步），仅保留库入口，
/// 计划提供：
///
/// - 桌面端（Windows / Linux / macOS）：基于 `dart_libusb` 的 USB 枚举与 bulk 传输；
/// - Android 端：基于 `android.hardware.usb` 的插件化实现；
///
/// 两者最终都实现 `package:adb_core` 中的 `AdbTransport` 接口，从而与 TCP 传输
/// 保持一致的调用方式。
library;

// TODO(adb_usb): 实现 AdbUsbTransport 并在此导出公开 API。
