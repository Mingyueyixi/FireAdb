/// 本机 ADB Server（默认 `127.0.0.1:5037`）。
///
/// 官方 `adb server` 是 platform-tools 里的 `adb` 进程。这里实现同一套
/// smart socket：`host:devices`、`host:transport`，以及把后续的
/// `shell:` / `exec:` / `sync:` 转到已经握完手的 [AdbConnection]。
/// `forward:` 由本机监听端口再打开设备上的目标服务，不把这条命令本身 OPEN 给设备。
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
import 'adb_tcp_transport.dart';
import 'adb_transport.dart';

/// 官方 `ADB_SERVER_VERSION`（`adb.h`）。`host:version` 以四位十六进制返回。
const int adbServerVersion = 41;

const int adbServerPort = 5037;

/// 官方 `DEFAULT_ADB_LOCAL_TRANSPORT_PORT`。模拟器 adb 端口从这里起，每次加 2。
const int adbEmulatorPortStart = 5555;

/// 官方扫描 16 个模拟器槽位，对应控制台端口 5554、5556……
const int adbEmulatorSlotCount = 16;

/// 本地模拟器的 adb 端口：5555、5557……5585。序列号是 `emulator-<端口-1>`。
List<int> adbEmulatorPorts() {
  final max = adbEmulatorPortStart + adbEmulatorSlotCount * 2 - 1;
  return <int>[
    for (var port = adbEmulatorPortStart; port <= max; port += 2) port,
  ];
}

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
    final shown = serial.isEmpty ? '(no serial number)' : serial;
    // AOSP `append_transport`：`%-22s %s`。Windows 官方不填 devpath。
    final buffer = StringBuffer('${shown.padRight(22)} $state');
    final path = devPath;
    if (path != null && path.contains('/')) buffer.write(' $path');
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
  final List<_ForwardRule> _forwards = [];
  Timer? _emulatorTimer;
  var _emulatorScanRunning = false;
  final Set<int> _emulatorBusy = <int>{};
  Iterable<int> _emulatorPorts = adbEmulatorPorts();
  Future<AdbTransport> Function(int port) _openEmulator = _openLocalEmulator;

  /// `host:kill` 时通知外面放开 USB。Server 自己会关掉监听。
  void Function()? onKilled;

  int? get port => _socket?.port;

  bool get isRunning => _socket != null && !_closed;

  Iterable<AdbServerDevice> get devices => _devices.values;

  /// 绑定 [port]。端口已被占用时抛 [SocketException]。
  Future<void> start({
    InternetAddress? address,
    int port = adbServerPort,
    bool scanEmulators = true,
    Iterable<int>? emulatorPorts,
    Future<AdbTransport> Function(int port)? openEmulator,
  }) async {
    if (emulatorPorts != null) _emulatorPorts = emulatorPorts;
    if (openEmulator != null) _openEmulator = openEmulator;
    _socket = await ServerSocket.bind(
      address ?? InternetAddress.loopbackIPv4,
      port,
    );
    _socket!.listen(_onClient);
    if (!scanEmulators) return;
    _emulatorTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(_scanEmulators());
    });
    unawaited(_scanEmulators());
  }

  /// 端口空闲时启动，已被占用时返回 null（外面已有官方 adb server）。
  static Future<AdbServer?> tryStart({
    InternetAddress? address,
    int port = adbServerPort,
    List<AdbRsaKeyPair> signers = const <AdbRsaKeyPair>[],
    bool scanEmulators = true,
  }) async {
    final server = AdbServer(signers: signers);
    try {
      await server.start(
        address: address,
        port: port,
        scanEmulators: scanEmulators,
      );
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
    final device = _devices.remove(serial);
    if (device == null) return;
    unawaited(_dropForwards(device: device));
    _notify();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _emulatorTimer?.cancel();
    _emulatorTimer = null;
    await _dropForwards();
    final emulators = _devices.values
        .where((device) => device.serial.startsWith('emulator-'))
        .toList();
    for (final device in emulators) {
      unawaited(device.connection.close());
    }
    final trackers = _trackers.toList();
    _trackers.clear();
    for (final tracker in trackers) {
      tracker();
    }
    final socket = _socket;
    _socket = null;
    await socket?.close();
  }

  Future<void> _scanEmulators() async {
    if (_closed || _emulatorScanRunning) return;
    _emulatorScanRunning = true;
    try {
      await Future.wait(_emulatorPorts.map(_tryEmulatorPort));
    } finally {
      _emulatorScanRunning = false;
    }
  }

  Future<void> _tryEmulatorPort(int adbPort) async {
    if (_closed || _emulatorBusy.contains(adbPort)) return;
    final serial = 'emulator-${adbPort - 1}';
    if (_devices.containsKey(serial)) return;
    _emulatorBusy.add(adbPort);
    AdbTransport transport;
    try {
      transport = await _openEmulator(adbPort);
    } catch (_) {
      _emulatorBusy.remove(adbPort);
      return;
    }
    if (_closed) {
      _emulatorBusy.remove(adbPort);
      await transport.close();
      return;
    }
    var published = false;
    late final AdbConnection connection;
    connection = AdbConnection(
      transport,
      signers: signers,
      authTimeout: const Duration(minutes: 30),
      onStateChanged: (state) {
        if (_closed) return;
        if (state == AdbConnectionState.offline) {
          remove(serial);
          return;
        }
        published = true;
        _publishEmulator(serial, connection, state);
      },
    );
    unawaited(() async {
      try {
        await connection.connect();
      } catch (_) {
        if (!published) await transport.close();
      } finally {
        _emulatorBusy.remove(adbPort);
      }
    }());
  }

  void _publishEmulator(
    String serial,
    AdbConnection connection,
    AdbConnectionState state,
  ) {
    final existing = _devices[serial];
    final banner = connection.deviceBanner;
    upsert(
      AdbServerDevice(
        connection: connection,
        serial: serial,
        state: state == AdbConnectionState.device ? 'device' : 'unauthorized',
        transportId: existing?.transportId ?? 0,
        product: _bannerValue(banner, 'ro.product.name') ?? existing?.product,
        model:
            _bannerValue(banner, 'ro.product.model', alphanumeric: true) ??
            existing?.model,
        deviceName:
            _bannerValue(banner, 'ro.product.device') ?? existing?.deviceName,
      ),
    );
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
      return _ClientNext.finish;
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
      return _ClientNext.finish;
    }
    if (service == 'host:track-devices' || service == 'host:track-devices-l') {
      await _okay(socket);
      await _track(socket, long: service.endsWith('-l'));
      return _ClientNext.finish;
    }
    if (service.startsWith('host:connect:')) {
      await _connect(socket, service.substring('host:connect:'.length));
      return _ClientNext.finish;
    }
    if (service.startsWith('host:disconnect')) {
      await _disconnect(socket, service);
      return _ClientNext.finish;
    }
    if (service.startsWith('host:tport:')) {
      return _switchTransportId(
        socket,
        reader,
        service.substring('host:tport:'.length),
      );
    }
    if (service == 'host:transport-any' ||
        service == 'host:transport-usb' ||
        service.startsWith('host:transport:')) {
      return _switchTransport(socket, reader, service);
    }
    final forward = _hostForwardRequest(service);
    if (forward != null) {
      await _handleHostForward(socket, forward);
      return _ClientNext.finish;
    }
    if (service.startsWith('host-serial:') ||
        service.startsWith('host-usb:') ||
        service.startsWith('host:')) {
      await _queryDevice(socket, service);
      return _ClientNext.finish;
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
      device = _find(serial);
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
    return _bridgeNext(socket, reader, device);
  }

  /// 官方客户端先发 `host:tport:`，读完 transport id 后在同一条连接上发送
  /// `shell:` / `exec:`。这条连接不能在回完 id 后关掉。
  Future<_ClientNext> _switchTransportId(
    Socket socket,
    AdbSizedReader reader,
    String selector,
  ) async {
    final picked = _select(selector);
    if (picked.many) {
      await _fail(socket, 'more than one device/emulator');
      return _ClientNext.finish;
    }
    final device = picked.device;
    if (device == null) {
      await _fail(socket, 'no devices/emulators found');
      return _ClientNext.finish;
    }
    if (!device.isOnline) {
      await _fail(socket, "device '${device.serial}' ${device.state}");
      return _ClientNext.finish;
    }
    await _okay(socket);
    // TransportId 是 uint64_t。官方客户端读满 8 字节才发下一条 shell。
    final id = device.transportId;
    await _write(socket, <int>[
      id & 0xff,
      (id >> 8) & 0xff,
      (id >> 16) & 0xff,
      (id >> 24) & 0xff,
      (id >> 32) & 0xff,
      (id >> 40) & 0xff,
      (id >> 48) & 0xff,
      (id >> 56) & 0xff,
    ]);
    return _bridgeNext(socket, reader, device);
  }

  Future<_ClientNext> _bridgeNext(
    Socket socket,
    AdbSizedReader reader,
    AdbServerDevice device,
  ) async {
    final String nextService;
    try {
      nextService = await _readService(reader);
    } catch (_) {
      return _ClientNext.finish;
    }
    final forwardCommand = _serverForwardCommand(nextService);
    if (forwardCommand != null) {
      await _applyForward(socket, device, forwardCommand, statusOkay: true);
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

  Future<void> _handleHostForward(
    Socket socket,
    _HostForwardRequest request,
  ) async {
    if (request.command == 'list-forward' && request.serial == null) {
      await _okayPayload(socket, _forwardText());
      return;
    }
    final AdbServerDevice? device;
    if (request.serial != null) {
      device = _find(request.serial!);
      if (device == null) {
        await _fail(socket, "device '${request.serial}' not found");
        return;
      }
    } else {
      final picked = _online(usb: request.usb);
      if (picked.many) {
        await _fail(socket, 'more than one device/emulator');
        return;
      }
      device = picked.device;
      if (device == null && request.command != 'list-forward') {
        await _fail(socket, 'no devices/emulators found');
        return;
      }
    }
    if (device != null && !device.isOnline) {
      await _fail(socket, "device '${device.serial}' ${device.state}");
      return;
    }
    await _applyForward(socket, device, request.command);
  }

  /// `forward:` / `killforward:` / `list-forward` 都在 server 上完成。
  /// 官方客户端先 `host:tport:`，再发 `host:forward:tcp:0;tcp:<端口>`。
  /// 设备上的 adbd 没有这条服务，直接 OPEN 会被 CLSE。
  ///
  /// [statusOkay] 为真时多回一个 `OKAY`。`adb_connect` 已经读走第一个，
  /// 命令行还要再读一个，然后才读端口数字。少这一个时，端口长度会被当成状态码。
  Future<void> _applyForward(
    Socket socket,
    AdbServerDevice? device,
    String command, {
    bool statusOkay = false,
  }) async {
    if (command == 'list-forward') {
      await _okayPayload(socket, _forwardText(device: device));
      return;
    }
    if (command == 'killforward-all') {
      await _dropForwards(device: device);
      await _forwardOkay(socket, statusOkay: statusOkay);
      return;
    }
    if (command.startsWith('killforward:')) {
      final local = command.substring('killforward:'.length);
      final removed = await _dropForwards(device: device, local: local);
      if (!removed) {
        await _fail(socket, "listener '$local' not found");
        return;
      }
      await _forwardOkay(socket, statusOkay: statusOkay);
      return;
    }

    final parsed = _parseForwardSpec(command);
    if (parsed == null || device == null) {
      await _fail(socket, 'cannot parse forward spec');
      return;
    }
    final existing = _forwards
        .where((rule) => rule.local == parsed.local)
        .toList();
    if (existing.isNotEmpty && parsed.norebind) {
      await _fail(socket, 'cannot rebind existing socket');
      return;
    }
    for (final rule in existing) {
      await _closeForward(rule);
    }
    final ServerSocket listener;
    try {
      listener = await _bindForward(parsed.local);
    } on SocketException catch (error) {
      await _fail(socket, 'cannot bind listener: $error');
      return;
    }
    final resolved = _resolvedLocal(parsed.local, listener.port);
    final rule = _ForwardRule(
      device: device,
      local: resolved,
      remote: parsed.remote,
      socket: listener,
    );
    rule.subscription = listener.listen((client) {
      unawaited(_pipeForward(rule, client));
    });
    _forwards.add(rule);
    await _forwardOkay(
      socket,
      statusOkay: statusOkay,
      payload: parsed.reportPort ? '${listener.port}' : null,
    );
  }

  /// 成功时的应答。需要状态确认时是 `OKAY` + `OKAY`，`tcp:0` 再附上端口。
  Future<void> _forwardOkay(
    Socket socket, {
    required bool statusOkay,
    String? payload,
  }) async {
    if (statusOkay) await _okay(socket);
    if (payload != null) {
      await _okayPayload(socket, payload);
      return;
    }
    await _okay(socket);
  }

  Future<void> _pipeForward(_ForwardRule rule, Socket client) async {
    final AdbStream stream;
    try {
      stream = await rule.device.connection.open(rule.remote);
    } catch (_) {
      client.destroy();
      return;
    }
    final fromClient = client.listen(
      (List<int> data) {
        unawaited(
          stream.write(data).then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {
              unawaited(stream.close());
            },
          ),
        );
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
        client.add(data);
        unawaited(client.flush().catchError((Object _) {}));
      },
      onDone: () {
        client.destroy();
      },
      onError: (Object _) {
        client.destroy();
      },
    );
    try {
      await stream.closed;
    } finally {
      await fromClient.cancel();
      await fromDevice.cancel();
      client.destroy();
    }
  }

  String _forwardText({AdbServerDevice? device}) {
    final lines = <String>[
      for (final rule in _forwards)
        if (device == null || rule.device.serial == device.serial)
          '${rule.device.serial} ${rule.local} ${rule.remote}',
    ];
    if (lines.isEmpty) return '';
    return '${lines.join('\n')}\n';
  }

  Future<bool> _dropForwards({AdbServerDevice? device, String? local}) async {
    final matched = _forwards
        .where(
          (rule) =>
              (device == null || rule.device.serial == device.serial) &&
              (local == null || rule.local == local),
        )
        .toList();
    for (final rule in matched) {
      await _closeForward(rule);
    }
    return matched.isNotEmpty;
  }

  Future<void> _closeForward(_ForwardRule rule) async {
    _forwards.remove(rule);
    await rule.subscription?.cancel();
    await rule.socket.close();
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

  AdbServerDevice? _find(String key) {
    final direct = _devices[key];
    if (direct != null) return direct;
    for (final device in _devices.values) {
      if (device.devPath == key) return device;
      final path = device.devPath;
      if (path != null && key == 'usb:$path') return device;
    }
    return null;
  }

  ({AdbServerDevice? device, bool many}) _select(String selector) {
    if (selector.startsWith('serial:')) {
      return (device: _find(selector.substring('serial:'.length)), many: false);
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
    const methods = <String>{
      'get-serialno',
      'get-state',
      'get-devpath',
      'features',
    };
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
      device = _find(serial);
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
      'features' => device.connection.features,
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
      final connected = await adbConnectTcp(host, port: port, signers: signers);
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
        _write(socket, _frame(_devicesText(long: long))).catchError((Object _) {
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
    return _write(socket, <int>[...ascii.encode('OKAY'), ..._frame(payload)]);
  }

  Future<void> _fail(Socket socket, String reason) {
    return _write(socket, <int>[...ascii.encode('FAIL'), ..._frame(reason)]);
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

class _ForwardRule {
  _ForwardRule({
    required this.device,
    required this.local,
    required this.remote,
    required this.socket,
  });

  final AdbServerDevice device;
  final String local;
  final String remote;
  final ServerSocket socket;
  StreamSubscription<Socket>? subscription;
}

class _HostForwardRequest {
  _HostForwardRequest({this.serial, this.usb, required this.command});

  final String? serial;
  final bool? usb;
  final String command;
}

const List<String> _forwardMarkers = <String>[
  ':forward:norebind:',
  ':forward:',
  ':killforward-all',
  ':killforward:',
  ':list-forward',
];

bool _isServerForward(String command) {
  return command == 'list-forward' ||
      command == 'killforward-all' ||
      command.startsWith('killforward:') ||
      command.startsWith('forward:');
}

/// 传输选中之后，官方 adb 仍带 `host:` 前缀，例如 `host:forward:tcp:0;tcp:9`。
String? _serverForwardCommand(String service) {
  if (_isServerForward(service)) return service;
  if (service.startsWith('host:') &&
      _isServerForward(service.substring('host:'.length))) {
    return service.substring('host:'.length);
  }
  return null;
}

_HostForwardRequest? _hostForwardRequest(String service) {
  final String command;
  String? serial;
  bool? usb;
  if (service.startsWith('host-serial:')) {
    final split = _splitSerialCommand(service.substring('host-serial:'.length));
    if (split == null) return null;
    serial = split.$1;
    command = split.$2;
  } else if (service.startsWith('host-usb:')) {
    usb = true;
    command = service.substring('host-usb:'.length);
  } else if (service.startsWith('host:')) {
    command = service.substring('host:'.length);
  } else {
    return null;
  }
  if (!_isServerForward(command)) return null;
  return _HostForwardRequest(serial: serial, usb: usb, command: command);
}

(String, String)? _splitSerialCommand(String rest) {
  var best = rest.length;
  String? marker;
  for (final candidate in _forwardMarkers) {
    final index = rest.indexOf(candidate);
    if (index <= 0) continue;
    final longer = marker != null && candidate.length > marker.length;
    if (index < best || (index == best && longer)) {
      best = index;
      marker = candidate;
    }
  }
  if (marker == null) return null;
  return (rest.substring(0, best), rest.substring(best + 1));
}

({String local, String remote, bool norebind, bool reportPort})?
_parseForwardSpec(String command) {
  var norebind = false;
  var rest = command;
  if (rest.startsWith('forward:norebind:')) {
    norebind = true;
    rest = rest.substring('forward:norebind:'.length);
  } else if (rest.startsWith('forward:')) {
    rest = rest.substring('forward:'.length);
  } else {
    return null;
  }
  final semi = rest.indexOf(';');
  if (semi <= 0 || semi >= rest.length - 1) return null;
  final local = rest.substring(0, semi);
  final remote = rest.substring(semi + 1);
  final port = _forwardPort(local);
  if (port == null || remote.isEmpty) return null;
  return (
    local: local,
    remote: remote,
    norebind: norebind,
    reportPort: port == 0,
  );
}

/// `tcp:0`、`tcp:8080`、`tcp:127.0.0.1:8080`。端口 0 表示由系统分配。
int? _forwardPort(String local) {
  if (!local.startsWith('tcp:')) return null;
  final spec = local.substring('tcp:'.length);
  final colon = spec.lastIndexOf(':');
  final portText = colon < 0 ? spec : spec.substring(colon + 1);
  final port = int.tryParse(portText);
  if (port == null || port < 0 || port > 65535) return null;
  if (colon >= 0 && spec.substring(0, colon).isEmpty) return null;
  return port;
}

Future<ServerSocket> _bindForward(String local) {
  final spec = local.substring('tcp:'.length);
  final colon = spec.lastIndexOf(':');
  if (colon < 0) {
    return ServerSocket.bind(InternetAddress.loopbackIPv4, int.parse(spec));
  }
  return ServerSocket.bind(
    spec.substring(0, colon),
    int.parse(spec.substring(colon + 1)),
  );
}

String _resolvedLocal(String requested, int port) {
  final spec = requested.substring('tcp:'.length);
  final colon = spec.lastIndexOf(':');
  if (colon < 0) return 'tcp:$port';
  return 'tcp:${spec.substring(0, colon)}:$port';
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

Future<AdbTransport> _openLocalEmulator(int port) {
  return AdbTcpTransport.connect(
    '127.0.0.1',
    port,
    connectTimeout: const Duration(milliseconds: 300),
  );
}

String? _bannerValue(String banner, String key, {bool alphanumeric = false}) {
  final prefix = '$key=';
  for (final prop in banner.split(';')) {
    if (!prop.startsWith(prefix)) continue;
    var value = prop.substring(prefix.length).trim();
    if (value.isEmpty) return null;
    if (alphanumeric) {
      value = value.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
    }
    return value;
  }
  return null;
}
