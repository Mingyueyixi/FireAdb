/// FireAdb 的 ADB 入口。
///
/// [LocalAdb.tryStart] 在端口空闲时启动 server。桌面端在进程里初始化 USB，
/// 扫到的设备进入同一份 `host:devices`。
library;

export 'package:adb_core/adb_core.dart';

export 'src/adb_usb_device.dart';
export 'src/adb_usb_session.dart' show listUsbAdbDevices;
export 'src/local_adb.dart';
export 'src/usb_adb.dart' show openUsbAdbTransport;
