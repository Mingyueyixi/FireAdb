/// 本机 ADB Server（默认 `127.0.0.1:5037`）。
///
/// 官方 `adb server` 是 platform-tools 里的 `adb` 进程。这里实现同一套
/// smart socket：`host:devices`、`host:transport`，以及把后续的
/// `shell:` / `exec:` / `sync:` 转到已经握完手的 [AdbConnection]。
/// USB 枚举不在这个库里，由调用方把设备登记进来。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'adb_auth_key.dart';
import 'adb_connection.dart';
import 'adb_device.dart';
import 'adb_smart_socket.dart';
import 'adb_stream_reader.dart';

/// 官方 `ADB_SERVER_VERSION`（`adb.h`）。`host:version` 以四位十六进制返回。
const int adbServerVersion = 41;

const int adbServerPort = 5037;

enum _ClientNext { stay, finish, bridged }

/// 一台已经挂在本机 server 上的设备。
class AdbServerDevice {
  AdbServerDevice({
    required this.connection,
    required this.serial,
    this.state = 'device',
    this.devPath,
    this.product,
    this.model,
    this.deviceName,
    this.usb = false,
    this.transportId = 0,
  });

  final AdbConnection connection;
  String serial;
  String state;
  String? devPath;
  String? product;
  String? model;
  String? deviceName;
  final bool usb;
  int transportId;

  bool get isOnline => state == 'device';

  String line({required bool long}) {
    if (!long) return '$serial\t$state';
    final buffer = StringBuffer('$serial $state');
    final path = devPath;
    if (path != null && path.isNotEmpty) buffer.write(' $path');
    final productName = product;
    if (productName != null && productName.isNotEmpty) {
      buffer.write(' product:$productName');
    }
    final modelName = model;
    if (modelName != null && modelName.isNotEmpty) {
      buffer.write(' model:$modelName');
    }
    final device = deviceName;
    if (device != null && device.isNotEmpty) buffer.write(' device:$device');
    buffer.write(' transport_id:$transportId');
    return buffer.toString();
  }
}

/// 监听本机 smart socket，并把客户端请求转到已登记的设备。
class AdbServer {
  AdbServer({this.signers = const <AdbRsaKeyPair>[]});

  final List<AdbRsaKeyPair> signers;

  ServerSocket? _socket;
  var _closed = false;
  var _nextTransportId = 1;
  final Map<String, AdbServerDevice> _devices = {};
  final Map<Socket, Future<void>> _writes = {};
  final List<void Function()> _trackers = [];

  /// `host:kill` 时通知外面放开 USB。Server 自己会关掉监听。
  void Function()? onKilled;

  int? get port => _socket?.port;

  bool get isRunning => _socket != null && !_closed;

  Iterable<AdbServerDevice> get devices => _devices.values;

  /// 绑定 [port]。端口已被占用时抛 [SocketException]。
  Future<void> start({
    InternetAddress? address,
    int port = adbServerPort,
  }) async {
    _socket = await ServerSocket.bind(
      address ?? InternetAddress.loopbackIPv4,
      port,
    );
    _socket!.listen(_onClient);
  }

  /// 端口空闲时启动，已被占用时返回 null（外面已有官方 adb server）。
  static Future<AdbServer?> tryStart({
    InternetAddress? address,
    int port = adbServerPort,
    List<AdbRsaKeyPair> signers = const <AdbRsaKeyPair>[],
  }) async {
    final server = AdbServer(signers: signers);
    try {
      await server.start(address: address, port: port);
      return server;
    } on SocketException {
      return null;
    }
  }

  void upsert(AdbServerDevice device) {
    final existing = _devices[device.serial];
    if (device.transportId == 0) {
      device.transportId = existing?.transportId ?? _nextTransportId++;
    }
    _devices[device.serial] = device;
    _notify();
  }

  void updateDescription(
    String serial, {
    String? product,
    String? model,
    String? deviceName,
    String? state,
  }) {
    final device = _devices[serial];
    if (device == null) return;
    if (product != null) device.product = product;
    if (model != null) device.model = model;
    if (deviceName != null) device.deviceName = deviceName;
    if (state != null) device.state = state;
    _notify();
  }

  void remove(String serial) {
    if (_devices.remove(serial) != null) _notify();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final trackers = _trackers.toList();
    _trackers.clear();
    for (final tracker in trackers) {
      tracker();
    }
    final socket = _socket;
    _socket = null;
    await socket?.close();
  }

  Future<void> _onClient(Socket socket) async {
    socket.setOption(SocketOption.tcpNoDelay, true);
    final reader = AdbSizedReader(socket);
    try {
      while (!_closed) {
        final service = await _readService(reader);
        final next = await _dispatch(socket, reader, service);
        if (next != _ClientNext.stay) return;
      }
    } catch (_) {
      // 客户端断开，或这一条连接已经转成设备流。
    } finally {
      _writes.remove(socket);
      try {
        await reader.close();
      } catch (_) {}
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  Future<_ClientNext> _dispatch(
    Socket socket,
    AdbSizedReader reader,
    String service,
  ) async {
    if (service == 'host:version') {
      final version = adbServerVersion.toRadixString(16).padLeft(4, '0');
      await _okayPayload(socket, version);
      return _ClientNext.stay;
    }
    if (service == 'host:kill') {
      await _okay(socket);
      final notify = onKilled;
      onKilled = null;
      notify?.call();
      await close();
      return _ClientNext.finish;
    }
    if (service == 'host:devices' || service == 'host:devices-l') {
      await _okayPayload(socket, _devicesText(long: service.endsWith('-l')));
      return _ClientNext.stay;
    }
    if (service == 'host:track-devices' || service == 'host:track-devices-l') {
      await _okay(socket);
      await _track(socket, long: service.endsWith('-l'));
      return _ClientNext.finish;
    }
    if (service.startsWith('host:connect:')) {
      await _connect(socket, service.substring('host:connect:'.length));
      return _ClientNext.stay;
    }
    if (service.startsWith('host:disconnect')) {
      await _disconnect(socket, service);
      return _ClientNext.stay;
    }
    if (service.startsWith('host:tport:')) {
      await _bindTransportId(socket, service.substring('host:tport:'.length));
      return _ClientNext.finish;
    }
    if (service == 'host:transport-any' ||
        service == 'host:transport-usb' ||
        service.startsWith('host:transport:')) {
      return _switchTransport(socket, reader, service);
    }
    if (service.startsWith('host-serial:') ||
        service.startsWith('host-usb:') ||
        service.startsWith('host:')) {
      await _queryDevice(socket, service);
      return _ClientNext.stay;
    }
    await _fail(socket, "unknown host service '$service'");
    return _ClientNext.finish;
  }

  Future<_ClientNext> _switchTransport(
    Socket socket,
    AdbSizedReader reader,
    String service,
  ) async {
    final AdbServerDevice? device;
    if (service == 'host:transport-any' || service == 'host:transport-usb') {
      final picked = _online(usb: service.endsWith('-usb') ? true : null);
      if (picked.many) {
        await _fail(socket, 'more than one device/emulator');
        return _ClientNext.finish;
      }
      device = picked.device;
      if (device == null) {
        await _fail(socket, 'no devices/emulators found');
        return _ClientNext.finish;
      }
    } else {
      final serial = service.substring('host:transport:'.length);
      device = _devices[serial];
      if (device == null) {
        await _fail(socket, "device '$serial' not found");
        return _ClientNext.finish;
      }
    }
    if (!device.isOnline) {
      await _fail(socket, "device '${device.serial}' ${device.state}");
      return _ClientNext.finish;
    }
    await _okay(socket);
    final String nextService;
    try {
      nextService = await _readService(reader);
    } catch (_) {
      return _ClientNext.finish;
    }
    await _bridge(socket, reader, device, nextService);
    return _ClientNext.bridged;
  }

  Future<void> _bridge(
    Socket socket,
    AdbSizedReader reader,
    AdbServerDevice device,
    String service,
  ) async {
    final AdbStream stream;
    try {
      stream = await device.connection.open(service);
    } catch (error) {
      await _fail(socket, '$error');
      return;
    }
    await _okay(socket);
    final incoming = reader.takeRemainingStream();
    final pendingToClient = <Future<void>>[];
    late final StreamSubscription<List<int>> fromClient;
    fromClient = incoming.listen(
      (List<int> data) async {
        if (data.isEmpty) return;
        fromClient.pause();
        try {
          await stream.write(data);
        } catch (_) {
          await stream.close();
          return;
        }
        if (fromClient.isPaused) fromClient.resume();
      },
      onDone: () {
        unawaited(stream.close());
      },
      onError: (Object _) {
        unawaited(stream.close());
      },
    );
    final fromDevice = stream.readStream().listen(
      (List<int> data) {
        pendingToClient.add(_write(socket, data));
      },
      onError: (Object _) {
        unawaited(stream.close());
      },
    );
    try {
      await stream.closed;
      await Future.wait(pendingToClient);
    } finally {
      await fromClient.cancel();
      await fromDevice.cancel();
    }
  }

  ({AdbServerDevice? device, bool many}) _online({required bool? usb}) {
    final online = _devices.values.where((device) {
      if (!device.isOnline) return false;
      if (usb == null) return true;
      return device.usb == usb;
    }).toList();
    if (online.length > 1) return (device: null, many: true);
    if (online.isEmpty) return (device: null, many: false);
    return (device: online.single, many: false);
  }

  Future<void> _bindTransportId(Socket socket, String selector) async {
    final picked = _select(selector);
    if (picked.many) {
      await _fail(socket, 'more than one device/emulator');
      return;
    }
    final device = picked.device;
    if (device == null) {
      await _fail(socket, 'no devices/emulators found');
      return;
    }
    await _okay(socket);
    final id = device.transportId;
    await _write(socket, <int>[
      id & 0xff,
      (id >> 8) & 0xff,
      (id >> 16) & 0xff,
      (id >> 24) & 0xff,
    ]);
  }

  ({AdbServerDevice? device, bool many}) _select(String selector) {
    if (selector.startsWith('serial:')) {
      final device = _devices[selector.substring('serial:'.length)];
      return (device: device, many: false);
    }
    if (selector == 'local') {
      final locals = _devices.values.where((device) => !device.usb).toList();
      if (locals.length > 1) return (device: null, many: true);
      if (locals.isEmpty) return (device: null, many: false);
      return (device: locals.single, many: false);
    }
    final usb = selector == 'usb' ? true : null;
    return _online(usb: usb);
  }

  Future<void> _queryDevice(Socket socket, String service) async {
    const methods = <String>{'get-serialno', 'get-state', 'get-devpath'};
    String? serial;
    String method;
    bool? usb;
    if (service.startsWith('host-serial:')) {
      final rest = service.substring('host-serial:'.length);
      final colon = rest.lastIndexOf(':');
      if (colon <= 0) {
        await _fail(socket, "unknown host service '$service'");
        return;
      }
      serial = rest.substring(0, colon);
      method = rest.substring(colon + 1);
    } else if (service.startsWith('host-usb:')) {
      usb = true;
      method = service.substring('host-usb:'.length);
    } else {
      method = service.substring('host:'.length);
    }
    if (!methods.contains(method)) {
      await _fail(socket, "unknown host service '$service'");
      return;
    }
    final AdbServerDevice? device;
    if (serial != null) {
      device = _devices[serial];
    } else {
      final picked = _online(usb: usb);
      if (picked.many) {
        await _fail(socket, 'more than one device/emulator');
        return;
      }
      device = picked.device;
    }
    if (device == null) {
      await _fail(
        socket,
        serial == null
            ? 'no devices/emulators found'
            : "device '$serial' not found",
      );
      return;
    }
    final value = switch (method) {
      'get-serialno' => device.serial,
      'get-state' => device.state,
      _ => device.devPath ?? '',
    };
    await _okayPayload(socket, value);
  }

  Future<void> _connect(Socket socket, String target) async {
    final parsed = _parseEndpoint(target);
    if (parsed == null) {
      await _fail(socket, 'bad port number');
      return;
    }
    final host = parsed.$1;
    final port = parsed.$2;
    final endpoint = '$host:$port';
    for (final device in _devices.values) {
      if (device.devPath == endpoint || device.serial == endpoint) {
        await _okayPayload(socket, 'already connected to $endpoint');
        return;
      }
    }
    try {
      final connected = await adbConnectTcp(
        host,
        port: port,
        signers: signers,
      );
      final serial = connected.serial.isEmpty ? endpoint : connected.serial;
      upsert(
        AdbServerDevice(
          connection: connected.connection,
          serial: serial,
          devPath: endpoint,
        ),
      );
      await _okayPayload(socket, 'connected to $endpoint');
    } catch (error) {
      await _fail(socket, 'failed to connect to $endpoint: $error');
    }
  }

  Future<void> _disconnect(Socket socket, String service) async {
    final target = service.startsWith('host:disconnect:')
        ? service.substring('host:disconnect:'.length)
        : '';
    if (target.isEmpty) {
      final tcp = _devices.values.where((device) => !device.usb).toList();
      for (final device in tcp) {
        remove(device.serial);
        unawaited(device.connection.close());
      }
      await _okayPayload(socket, 'disconnected everything');
      return;
    }
    final parsed = _parseEndpoint(target);
    final endpoint = parsed == null ? target : '${parsed.$1}:${parsed.$2}';
    AdbServerDevice? match;
    for (final device in _devices.values) {
      if (device.usb) continue;
      if (device.serial == target ||
          device.serial == endpoint ||
          device.devPath == endpoint) {
        match = device;
        break;
      }
    }
    if (match == null) {
      await _fail(socket, 'no such device $target');
      return;
    }
    remove(match.serial);
    unawaited(match.connection.close());
    await _okayPayload(socket, 'disconnected $endpoint');
  }

  Future<void> _track(Socket socket, {required bool long}) async {
    final done = Completer<void>();
    void push() {
      if (done.isCompleted || _closed) {
        if (!done.isCompleted) done.complete();
        return;
      }
      unawaited(
        _write(socket, _frame(_devicesText(long: long))).catchError((
          Object _,
        ) {
          if (!done.isCompleted) done.complete();
        }),
      );
    }

    _trackers.add(push);
    push();
    unawaited(
      socket.done.whenComplete(() {
        if (!done.isCompleted) done.complete();
      }),
    );
    await done.future;
    _trackers.remove(push);
  }

  String _devicesText({required bool long}) {
    if (_devices.isEmpty) return '';
    final lines = _devices.values.map((device) => device.line(long: long));
    return '${lines.join('\n')}\n';
  }

  void _notify() {
    for (final tracker in _trackers.toList()) {
      tracker();
    }
  }

  Future<String> _readService(AdbSizedReader reader) async {
    final lenText = ascii.decode(
      await reader.readExactly(4),
      allowInvalid: true,
    );
    final len = int.tryParse(lenText.trim(), radix: 16);
    if (len == null || len < 0 || len > 65535) {
      throw const FormatException('bad request length');
    }
    if (len == 0) return '';
    return utf8.decode(await reader.readExactly(len), allowMalformed: true);
  }

  List<int> _frame(String payload) {
    final body = utf8.encode(payload);
    return <int>[...ascii.encode(encodeHex4(body.length)), ...body];
  }

  Future<void> _okay(Socket socket) => _write(socket, ascii.encode('OKAY'));

  Future<void> _okayPayload(Socket socket, String payload) {
    return _write(socket, <int>[
      ...ascii.encode('OKAY'),
      ..._frame(payload),
    ]);
  }

  Future<void> _fail(Socket socket, String reason) {
    return _write(socket, <int>[
      ...ascii.encode('FAIL'),
      ..._frame(reason),
    ]);
  }

  Future<void> _write(Socket socket, List<int> bytes) {
    final previous = _writes[socket] ?? Future<void>.value();
    final done = previous.catchError((Object _) {}).then((_) async {
      socket.add(bytes);
      await socket.flush();
    });
    _writes[socket] = done.catchError((Object _) {});
    return done;
  }
}

/// `host[:port]`，缺省端口 5555。
(String, int)? _parseEndpoint(String target) {
  final trimmed = target.trim();
  if (trimmed.isEmpty) return null;
  final colon = trimmed.lastIndexOf(':');
  if (colon <= 0 || colon == trimmed.length - 1) {
    return (trimmed, 5555);
  }
  final port = int.tryParse(trimmed.substring(colon + 1));
  if (port == null || port <= 0 || port > 65535) return null;
  var host = trimmed.substring(0, colon);
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  if (host.isEmpty) return null;
  return (host, port);
}
