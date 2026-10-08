/// 桌面端 USB 传输：用 libusb 枚举 ADB 接口，并实现 [AdbTransport]。
///
/// Android 不走这条路径。
library;

export 'src/adb_usb_device.dart';
export 'src/adb_usb_match.dart';
export 'src/adb_usb_session.dart'
    show listUsbAdbDevices, openUsbAdbDevice, AdbUsbTransport;
export 'src/usb_adb_tracker.dart';
