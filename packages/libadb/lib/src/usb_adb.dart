import 'dart:async';
import 'dart:typed_data';

import 'package:adb_core/adb_core.dart';

import 'adb_usb_device.dart';
import 'adb_usb_session.dart';

/// 桌面 USB 扩展。自己每 2 秒枚举一次，握手后把结果交给 server 的设备列表。
class UsbAdbExtension implements AdbDeviceExtension {
  UsbAdbExtension({
    this.onError,
    List<AdbRsaKeyPair> signers = const <AdbRsaKeyPair>[],
  }) : _signers = signers;

  static const Duration _interval = Duration(seconds: 2);

  final void Function(Object? error, StackTrace? stackTrace)? onError;
  final List<AdbRsaKeyPair> _signers;
  final Map<String, _UsbLink> _links = {};
  final Map<String, Future<void>> _releasing = {};
  AdbScanListener? _listener;
  Timer? _timer;
  var _scanning = false;

  @override
  void listen(AdbScanListener listener) {
    unawaited(cancel());
    _listener = listener;
    _timer = Timer.periodic(_interval, (_) {
      unawaited(_scan());
    });
    unawaited(_scan());
  }

  @override
  Future<void> cancel() async {
    _timer?.cancel();
    _timer = null;
    _listener = null;
    final pending = <Future<void>>[];
    for (final path in _links.keys.toList()) {
      final link = _links.remove(path);
      if (link == null || link.closed) continue;
      link.closed = true;
      pending.add(_releaseLink(link));
    }
    if (pending.isEmpty) return;
    await Future.wait(pending);
  }

  Future<void> _scan() async {
    final listener = _listener;
    if (listener == null || _scanning) return;
    _scanning = true;
    try {
      final found = await listUsbAdbDevices();
      if (_listener != listener) return;
      onError?.call(null, null);
      final alive = found.map((device) => device.portPath).toSet();
      for (final path in _links.keys.toList()) {
        final link = _links[path];
        final gone = link == null || !alive.contains(path);
        final dropped = link?.connection?.state == AdbConnectionState.offline;
        if (gone || dropped) await _closeLink(path);
      }
      for (final device in found) {
        final releasing = _releasing[device.portPath];
        if (releasing != null) await releasing;
        if (_listener != listener) return;
        if (_links.containsKey(device.portPath)) continue;
        final link = _UsbLink(device);
        _links[device.portPath] = link;
        unawaited(_run(link));
      }
    } catch (error, stackTrace) {
      if (_listener != listener) return;
      onError?.call(error, stackTrace);
    } finally {
      _scanning = false;
    }
  }

  Future<void> _run(_UsbLink link) async {
    try {
      final transport = await openUsbAdbDevice(link.device);
      if (_listener == null || link.closed) {
        await transport.close();
        return;
      }
      link.transport = transport;
      final connection = AdbConnection(
        _UsbPipe(transport),
        signers: _signers,
        authTimeout: const Duration(minutes: 30),
        onStateChanged: (state) => _publish(link, state),
      );
      link.connection = connection;
      await connection.connect();
    } on AdbDeviceAuthError catch (error, stackTrace) {
      if (link.connection?.state == AdbConnectionState.unauthorized) return;
      onError?.call(error, stackTrace);
      await _closeLink(link.device.portPath);
    } catch (error, stackTrace) {
      if (link.closed || _listener == null) return;
      onError?.call(error, stackTrace);
      await _closeLink(link.device.portPath);
    }
  }

  void _publish(_UsbLink link, AdbConnectionState state) {
    if (link.closed || _listener == null) return;
    final connection = link.connection;
    if (connection == null) return;
    if (state == AdbConnectionState.offline) {
      unawaited(_closeLink(link.device.portPath));
      return;
    }
    link.listState = state == AdbConnectionState.device
        ? 'device'
        : 'unauthorized';
    link.registeredSerial = _serial(link, connection);
    if (state == AdbConnectionState.device) {
      onError?.call(null, null);
      unawaited(_fillProps(link));
    }
    _emit();
  }

  Future<void> _fillProps(_UsbLink link) async {
    if (link.propsLoaded || link.closed) return;
    link.propsLoaded = true;
    final connection = link.connection;
    if (connection == null || link.registeredSerial == null) return;
    try {
      final properties = await connection.getSystemProperties();
      if (link.closed) return;
      link.product = _token(properties['ro.product.name']);
      link.model = _token(properties['ro.product.model']);
      link.deviceName = _token(properties['ro.product.device']);
      _emit();
    } catch (_) {}
  }

  void _emit() {
    final listener = _listener;
    if (listener == null) return;
    listener.onScan(<AdbScannedDevice>[
      for (final link in _links.values)
        if (!link.closed &&
            link.connection != null &&
            link.registeredSerial != null)
          AdbScannedDevice(
            id: link.device.portPath,
            connection: link.connection!,
            serial: link.registeredSerial!,
            state: link.listState,
            devPath: link.device.portPath,
            usb: true,
            product: link.product,
            model: link.model,
            deviceName: link.deviceName,
          ),
    ]);
  }

  String _serial(_UsbLink link, AdbConnection connection) {
    final usbSerial = link.transport?.serialNumber?.trim();
    if (usbSerial != null && usbSerial.isNotEmpty) return usbSerial;
    final listed = link.device.serialNumber?.trim();
    if (listed != null && listed.isNotEmpty) return listed;
    if (connection.deviceSerial.isNotEmpty) return connection.deviceSerial;
    return link.device.address;
  }

  Future<void> _closeLink(String portPath, {bool notify = true}) async {
    final link = _links.remove(portPath);
    if (link == null || link.closed) return;
    link.closed = true;
    if (notify) _emit();
    final pending = _releaseLink(link);
    _releasing[portPath] = pending;
    try {
      await pending;
    } finally {
      if (identical(_releasing[portPath], pending)) {
        _releasing.remove(portPath);
      }
    }
  }

  Future<void> _releaseLink(_UsbLink link) async {
    final transport = link.transport;
    final connection = link.connection;
    // 先启动 transport.close：同步段立刻 libusb_close，不依赖调用方再关一次。
    final closingUsb = transport?.close();
    try {
      await connection?.close();
    } catch (_) {}
    try {
      await closingUsb;
    } catch (_) {}
  }
}

/// 把 libusb 打开的字节流接成 [AdbTransport]，供不经过 server 的直连使用。
Future<AdbTransport> openUsbAdbTransport(UsbAdbDevice device) async {
  final usb = await openUsbAdbDevice(device);
  return _UsbPipe(usb);
}

class _UsbLink {
  _UsbLink(this.device);

  final UsbAdbDevice device;
  AdbUsbTransport? transport;
  AdbConnection? connection;
  String? registeredSerial;
  String listState = 'device';
  String? product;
  String? model;
  String? deviceName;
  var propsLoaded = false;
  var closed = false;
}

class _UsbPipe implements AdbTransport {
  _UsbPipe(this._usb);

  final AdbUsbTransport _usb;

  @override
  Stream<Uint8List> get stream => _usb.stream;

  @override
  Future<void> write(List<int> data) => _usb.write(data);

  @override
  Future<void> close() => _usb.close();
}

String? _token(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return null;
  return text.replaceAll(RegExp(r'\s+'), '_');
}
