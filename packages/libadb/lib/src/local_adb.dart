import 'dart:io';

import 'package:adb_core/adb_core.dart';

import 'usb_adb.dart';

/// Windows、Linux、macOS 才有 libusb。
bool get _usbSupported =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// 本进程的 ADB Server。端口空闲时启动。
///
/// 桌面端在进程内部初始化 USB，和官方 adb server 启动时调用 `usb_init` 一样。
class LocalAdb {
  LocalAdb._(this.server, this._usb);

  final AdbServer server;
  final _UsbErrors _usb;

  /// 5037（或 [port]）已被占用时返回 null，调用方继续用外面的 Server。
  static Future<LocalAdb?> tryStart({
    InternetAddress? address,
    int port = adbServerPort,
    List<AdbRsaKeyPair> signers = const <AdbRsaKeyPair>[],
    bool scanEmulators = true,
    void Function()? onKilled,
  }) async {
    final usb = _UsbErrors();
    final extensions = <AdbDeviceExtension>[
      if (_usbSupported) UsbAdbExtension(onError: usb.report, signers: signers),
    ];
    final server = await AdbServer.tryStart(
      address: address,
      port: port,
      signers: signers,
      scanEmulators: scanEmulators,
      extensions: extensions,
    );
    if (server == null) return null;
    server.onKilled = onKilled;
    return LocalAdb._(server, usb);
  }

  /// USB 枚举失败或恢复时通知。若在监听前已经失败过，会立刻再通知一次。
  void listenUsbError(
    void Function(Object? error, StackTrace? stackTrace) listener,
  ) {
    _usb.listen(listener);
  }

  Future<void> close() => server.close();
}

class _UsbErrors {
  Object? _error;
  StackTrace? _stackTrace;
  var _reported = false;
  void Function(Object? error, StackTrace? stackTrace)? _listener;

  void report(Object? error, StackTrace? stackTrace) {
    _error = error;
    _stackTrace = stackTrace;
    _reported = true;
    _listener?.call(error, stackTrace);
  }

  void listen(void Function(Object? error, StackTrace? stackTrace) listener) {
    _listener = listener;
    if (_reported) listener(_error, _stackTrace);
  }
}
