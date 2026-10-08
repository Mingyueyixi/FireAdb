/// FireAdb 的 ADB 入口。
///
/// 协议、本机 Server 和 TCP 在 `adb_core`。桌面 USB 在 `adb_usb`。
/// 本库把两者组装成一次启动：5037 空闲时监听，Windows / Linux / macOS 再挂上 USB。
library;

export 'package:adb_core/adb_core.dart';
export 'package:adb_usb/adb_usb.dart';

export 'src/local_adb.dart';
