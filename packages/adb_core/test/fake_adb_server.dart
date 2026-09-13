/// 模拟 `adb server`（5037 端口协议）用于 host 客户端测试。
///
/// 帧格式（对应 AOSP `adb_io.cpp:SendProtocolString/ReadProtocolString`）：
/// ```text
/// client → server: <hex4><service>
/// server → client: "OKAY"            或 "FAIL" <hex4><reason>
/// 查询:            再跟 <hex4><payload>
/// transport:       OKAY 后追加 4 字节 Little-Endian transport id
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adb_core/adb_core.dart';

String _hex4(int length) => length.toRadixString(16).padLeft(4, '0');

class FakeAdbServer {
  FakeAdbServer({this.devices = const <String>[]});

  /// 设备列表文本，如 `['emulator-5554\tdevice', '12345\tunauthorized']`。
  final List<String> devices;

  /// 等待期间收到 `host:track-devices` 时额外推送的设备列表文本。
  final StreamController<String> trackUpdates = StreamController();

  final List<String> requests = [];
  final Set<Socket> _connections = {};
  ServerSocket? _server;
  int _nextTransportId = 1;

  int? get port => _server?.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_onConnection);
  }

  Future<void> close() async {
    for (final s in _connections.toList()) {
      try {
        s.destroy();
      } catch (_) {}
    }
    _connections.clear();
    await _server?.close();
    unawaited(trackUpdates.close());
  }

  String get devicesPayload => devices.join('\n') + (devices.isEmpty ? '' : '\n');

  Future<void> _onConnection(Socket socket) async {
    _connections.add(socket);
    try {
      socket.done.then((_) => _connections.remove(socket),
          onError: (_) => _connections.remove(socket));
      final reader = AdbSizedReader(socket);
      final lenText =
          ascii.decode(await reader.readExactly(4), allowInvalid: true);
      final len = int.tryParse(lenText.trim(), radix: 16);
      if (len == null || len <= 0 || len > 1024 * 1024) {
        await _fail(socket, 'bad request length');
        return;
      }
      final service = utf8.decode(await reader.readExactly(len));
      requests.add(service);
      await _dispatch(socket, service);
    } catch (_) {
      // 客户端断开等。
    }
  }

  Future<void> _dispatch(Socket socket, String service) async {
    if (service == 'host:version') {
      await _okayPayload(socket, '0039');
    } else if (service == 'host:kill') {
      await _okay(socket);
      await socket.close();
    } else if (service == 'host:devices' || service == 'host:devices-l') {
      await _okayPayload(socket, devicesPayload);
    } else if (service == 'host:track-devices' ||
        service == 'host:track-devices-l') {
      await _okay(socket);
      await _trackLoop(socket);
    } else if (service.startsWith('host:connect:')) {
      final target = service.substring('host:connect:'.length);
      await _okayPayload(socket, 'connected to $target');
    } else if (service.startsWith('host:disconnect')) {
      await _okayPayload(socket, 'disconnected everything');
    } else if (service.startsWith('host:tport:')) {
      await _okay(socket);
      final id = _nextTransportId++;
      socket.add(
          Uint8List.fromList([id & 0xff, (id >> 8) & 0xff, (id >> 16) & 0xff, (id >> 24) & 0xff]));
      await socket.flush();
    } else if (service == 'host:transport-any' ||
        service.startsWith('host:transport:')) {
      // 旧式键控传输：只回 OKAY 后关闭连接，不附带 transport id。
      await _okay(socket);
      await socket.close();
    } else if (service.startsWith('host-serial:') ||
        service.startsWith('host-usb:') ||
        service.startsWith('host:')) {
      // host 前缀设备查询：get-serialno / get-state / get-devpath。
      final method = service.split(':').last;
      final serialMatch =
          RegExp(r'^host-serial:([^:]+):').firstMatch(service);
      if (serialMatch != null && serialMatch.group(1) != 'fake12345') {
        await _fail(socket, 'device \'${serialMatch.group(1)}\' not found');
        return;
      }
      switch (method) {
        case 'get-serialno':
          await _okayPayload(socket, 'fake12345');
        case 'get-state':
          await _okayPayload(socket, 'device');
        case 'get-devpath':
          await _okayPayload(socket, '/dev/bus/usb/001/002');
        default:
          await _fail(socket, 'unknown host service \'$service\'');
      }
    } else {
      await _fail(socket, 'unknown host service \'$service\'');
    }
  }

  Future<void> _trackLoop(Socket socket) async {
    await _sendPayloadFrame(socket, devicesPayload);
    await for (final update in trackUpdates.stream) {
      await _sendPayloadFrame(socket, update);
    }
  }

  Future<void> _sendPayloadFrame(Socket socket, String payload) async {
    socket.add(ascii.encode(_hex4(utf8.encode(payload).length)));
    socket.add(utf8.encode(payload));
    await socket.flush();
  }

  Future<void> _okay(Socket socket) async {
    socket.add(ascii.encode('OKAY'));
    await socket.flush();
  }

  Future<void> _okayPayload(Socket socket, String payload) async {
    socket.add(ascii.encode('OKAY'));
    socket.add(ascii.encode(_hex4(utf8.encode(payload).length)));
    socket.add(utf8.encode(payload));
    await socket.flush();
  }

  Future<void> _fail(Socket socket, String reason) async {
    socket.add(ascii.encode('FAIL'));
    socket.add(ascii.encode(_hex4(utf8.encode(reason).length)));
    socket.add(utf8.encode(reason));
    await socket.flush();
  }
}