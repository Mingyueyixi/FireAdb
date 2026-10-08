import 'dart:async';

import 'package:adb_core/adb_core.dart';

import 'adb_usb_device.dart';
import 'adb_usb_session.dart';

/// 定时枚举 USB 上的 ADB 接口，握手后登记到 [AdbServer]。
///
/// 本机 server 占着接口。界面上的设备来自 `host:devices`，不要再对同一台
/// 手机做一次直连打开。
class UsbAdbTracker {
  UsbAdbTracker({
    required this.server,
    required this.signers,
    this.listDevices = listUsbAdbDevices,
    this.openDevice = openUsbAdbDevice,
    this.interval = const Duration(seconds: 2),
    this.onError,
  });

  final AdbServer server;
  final List<AdbRsaKeyPair> signers;
  final Future<List<UsbAdbDevice>> Function() listDevices;
  final Future<AdbTransport> Function(UsbAdbDevice device) openDevice;
  final Duration interval;
  final void Function(Object? error, StackTrace? stackTrace)? onError;

  final Map<String, _UsbLink> _links = {};
  Timer? _timer;
  var _scanning = false;
  var _closed = false;

  void start() {
    _timer ??= Timer.periodic(interval, (_) {
      unawaited(scan());
    });
    unawaited(scan());
  }

  Future<void> scan() async {
    if (_closed || _scanning) return;
    _scanning = true;
    try {
      final found = await listDevices();
      if (_closed) return;
      if (found.isEmpty) onError?.call(null, null);
      final alive = found.map((device) => device.portPath).toSet();
      for (final path in _links.keys.toList()) {
        if (!alive.contains(path)) await _closeLink(path);
      }
      for (final device in found) {
        if (_links.containsKey(device.portPath)) continue;
        final link = _UsbLink(device);
        _links[device.portPath] = link;
        unawaited(_run(link));
      }
    } catch (error, stackTrace) {
      onError?.call(error, stackTrace);
    } finally {
      _scanning = false;
    }
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    for (final path in _links.keys.toList()) {
      await _closeLink(path);
    }
  }

  Future<void> _run(_UsbLink link) async {
    try {
      final transport = await openDevice(link.device);
      if (_closed || link.closed) {
        await transport.close();
        return;
      }
      link.transport = transport;
      final connection = AdbConnection(
        transport,
        signers: signers,
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
      if (link.closed || _closed) return;
      onError?.call(error, stackTrace);
      await _closeLink(link.device.portPath);
    }
  }

  void _publish(_UsbLink link, AdbConnectionState state) {
    if (link.closed || _closed) return;
    final connection = link.connection;
    if (connection == null) return;
    if (state == AdbConnectionState.offline) {
      unawaited(_closeLink(link.device.portPath));
      return;
    }
    final serial = _serial(link, connection);
    final previous = link.registeredSerial;
    if (previous != null && previous != serial) server.remove(previous);
    server.upsert(
      AdbServerDevice(
        connection: connection,
        serial: serial,
        state: state == AdbConnectionState.device ? 'device' : 'unauthorized',
        devPath: link.device.portPath,
        usb: true,
        product: link.product,
        model: link.model,
        deviceName: link.deviceName,
      ),
    );
    link.registeredSerial = serial;
    if (state == AdbConnectionState.device) {
      onError?.call(null, null);
      unawaited(_fillProps(link));
    }
  }

  Future<void> _fillProps(_UsbLink link) async {
    if (link.propsLoaded || link.closed) return;
    link.propsLoaded = true;
    final connection = link.connection;
    final serial = link.registeredSerial;
    if (connection == null || serial == null) return;
    try {
      final properties = await connection.getSystemProperties();
      if (link.closed) return;
      link.product = _token(properties['ro.product.name']);
      link.model = _token(properties['ro.product.model']);
      link.deviceName = _token(properties['ro.product.device']);
      server.updateDescription(
        serial,
        product: link.product,
        model: link.model,
        deviceName: link.deviceName,
      );
    } catch (_) {}
  }

  String _serial(_UsbLink link, AdbConnection connection) {
    final usbSerial = _usbSerial(link);
    if (usbSerial != null) return usbSerial;
    if (connection.deviceSerial.isNotEmpty) return connection.deviceSerial;
    return link.device.address;
  }

  String? _usbSerial(_UsbLink link) {
    final listed = link.device.serialNumber?.trim();
    if (listed != null && listed.isNotEmpty) return listed;
    final transport = link.transport;
    if (transport is AdbUsbTransport) {
      final opened = transport.serialNumber?.trim();
      if (opened != null && opened.isNotEmpty) return opened;
    }
    return null;
  }

  Future<void> _closeLink(String portPath) async {
    final link = _links.remove(portPath);
    if (link == null || link.closed) return;
    link.closed = true;
    final serial = link.registeredSerial;
    if (serial != null) server.remove(serial);
    try {
      await link.connection?.close();
    } catch (_) {}
    try {
      await link.transport?.close();
    } catch (_) {}
  }
}

class _UsbLink {
  _UsbLink(this.device);

  final UsbAdbDevice device;
  AdbTransport? transport;
  AdbConnection? connection;
  String? registeredSerial;
  String? product;
  String? model;
  String? deviceName;
  var propsLoaded = false;
  var closed = false;
}

String? _token(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return null;
  return text.replaceAll(RegExp(r'\s+'), '_');
}
