import 'dart:async';
import 'dart:io';

import 'package:adb_core/adb_core.dart';
import 'package:adb_usb/adb_usb.dart';

/// Windows、Linux、macOS 才有 libusb。Android 只启动本机 Server。
bool get libadbUsbSupported =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// 本进程的 ADB Server。端口空闲时启动，桌面端再挂上 USB 枚举。
class LocalAdb {
  LocalAdb._(this.server, UsbAdbTracker? usbTracker) : _usbTracker = usbTracker;

  final AdbServer server;
  UsbAdbTracker? _usbTracker;

  UsbAdbTracker? get usbTracker => _usbTracker;

  /// 5037（或 [port]）已被占用时返回 null，调用方继续用外面的 Server。
  static Future<LocalAdb?> tryStart({
    InternetAddress? address,
    int port = adbServerPort,
    List<AdbRsaKeyPair> signers = const <AdbRsaKeyPair>[],
    bool scanEmulators = true,
    bool usb = true,
    bool Function()? usbSupported,
    void Function()? onKilled,
    void Function(Object? error, StackTrace? stackTrace)? onUsbError,
  }) async {
    final server = await AdbServer.tryStart(
      address: address,
      port: port,
      signers: signers,
      scanEmulators: scanEmulators,
    );
    if (server == null) return null;
    final attachUsb = usb && (usbSupported?.call() ?? libadbUsbSupported);
    final tracker = attachUsb
        ? UsbAdbTracker(server: server, signers: signers, onError: onUsbError)
        : null;
    final local = LocalAdb._(server, tracker);
    server.onKilled = () {
      final running = local._usbTracker;
      local._usbTracker = null;
      if (running != null) unawaited(running.close());
      onKilled?.call();
    };
    tracker?.start();
    return local;
  }

  Future<void> close() async {
    final tracker = _usbTracker;
    _usbTracker = null;
    if (tracker != null) await tracker.close();
    await server.close();
  }
}
