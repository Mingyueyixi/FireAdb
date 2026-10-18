import 'dart:io';

import 'package:adb_core/adb_core.dart';

import 'fire_usb.dart';
import 'mdns_adb.dart';
import 'usb_adb.dart';

/// Windows、Linux、macOS 才有 libusb。
bool get _usbSupported =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// 本进程的 ADB Server。端口空闲时启动。
///
/// USB 握上手之后进入 `host:devices`。mDNS 只通过 [listenMdnsServices] 交出来，
/// 配对服务和可连接服务都在这份回调里，不占用 USB 的错误通道。
class LocalAdb {
  LocalAdb._(
    this.server,
    this._usb,
    this._mdns,
    this._services,
    this._mdnsExtension,
  );

  final AdbServer server;
  final _ErrorReplay _usb;
  final _ErrorReplay _mdns;
  final _Replay<List<MdnsService>> _services;
  final MdnsAdbExtension _mdnsExtension;

  /// 5037（或 [port]）已被占用时返回 null，调用方继续用外面的 Server。
  static Future<LocalAdb?> tryStart({
    InternetAddress? address,
    int port = adbServerPort,
    List<AdbRsaKeyPair> signers = const <AdbRsaKeyPair>[],
    bool scanEmulators = true,
    void Function()? onKilled,
  }) async {
    // 热重启后上一轮的 usbWorker 可能还堵在 libusb_handle_events。
    // 先清掉进程内句柄，让旧 isolate 有机会退出来，避免退出时空等 check in。
    FireUsb.tryLoad()?.closeAll();
    final usb = _ErrorReplay();
    final mdns = _ErrorReplay();
    final services = _Replay<List<MdnsService>>(const <MdnsService>[]);
    final mdnsExtension = MdnsAdbExtension(
      onError: mdns.report,
      onServices: services.report,
    );
    final extensions = <AdbDeviceExtension>[
      if (_usbSupported) UsbAdbExtension(onError: usb.report, signers: signers),
      mdnsExtension,
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
    return LocalAdb._(server, usb, mdns, services, mdnsExtension);
  }

  /// USB 枚举失败或恢复时通知。若在监听前已经失败过，会立刻再通知一次。
  void listenUsbError(
    void Function(Object? error, StackTrace? stackTrace) listener,
  ) {
    _usb.listen(listener);
  }

  /// mDNS 扫描失败或恢复时通知。和 USB 错误分开。
  void listenMdnsError(
    void Function(Object? error, StackTrace? stackTrace) listener,
  ) {
    _mdns.listen(listener);
  }

  /// 当前扫到的无线服务，含配对端口和可连接端口。
  ///
  /// 后来才监听的调用方会立刻拿到最近一轮。时间到但没有应答的轮次不会覆盖它。
  void listenMdnsServices(void Function(List<MdnsService> services) listener) {
    _services.listen(listener);
  }

  Future<void> refreshMdns() => _mdnsExtension.scan();

  Future<void> close() async {
    await server.close();
    FireUsb.tryLoad()?.closeAll();
  }
}

class _ErrorReplay {
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

class _Replay<T> {
  _Replay(this._value);

  T _value;
  var _reported = false;
  void Function(T value)? _listener;

  void report(T value) {
    _value = value;
    _reported = true;
    _listener?.call(value);
  }

  void listen(void Function(T value) listener) {
    _listener = listener;
    if (_reported) listener(_value);
  }
}
