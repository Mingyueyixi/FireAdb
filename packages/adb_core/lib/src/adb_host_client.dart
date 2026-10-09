/// ADB 服务端（`adb server`，默认 127.0.0.1:5037）客户端。
///
/// 实现了 AOSP `services.md` 中的 host 服务与传输出层绑定：
/// ```text
/// client → server:  <hex4><service>        (SendProtocolString)
/// server → client:  "OKAY"                 (adb_status)
///                或 "FAIL" <hex4><reason>
/// 带返回数据的请求在 OKAY 后再跟 <hex4><payload>。
/// ```
/// 注意握手不使用版本前缀，先发 `host:tport:any|usb|local|serial:<serial>`，
/// 服务端 OKAY 后追加 8 字节 Little-Endian transport id（`uint64_t`）。
///
/// 参考：`third_party/aosp-adb/client/adb_client.cpp`（`_adb_connect`、
/// `switch_socket_transport`、`adb_status`）与 `adb_io.cpp:SendProtocolString`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'adb_exceptions.dart';
import 'adb_filesync.dart';
import 'adb_smart_socket.dart';
import 'adb_stream_reader.dart';

/// host 服务的 transport 类型（对应 `host:tport:*`）。
enum AdbTransportType {
  /// 任意连接上的设备或模拟器。
  any,

  /// 单台 USB 设备。
  usb,

  /// 单台本地（模拟器）设备。
  local,
}

/// 一条设备记录（来自 `host:devices[ -l]`）。
///
/// 短格式（`host:devices`）：`<serial>\t<state>`；
/// 长格式（`host:devices-l`）：`%-22s <state> [devpath] product:<p> model:<m> device:<d> transport_id:<id>`。
/// Windows 官方 USB 的 devpath 为空，所以长列表里没有 `1-3` 这种端口路径。
/// Linux 的 `/dev/bus/usb/...` 仍会打印。
class AdbDeviceInfo {
  const AdbDeviceInfo(
    this.serial,
    this.state, {
    this.devPath,
    this.product,
    this.model,
    this.device,
    this.transportId,
  });

  final String serial;
  final String state;
  final String? devPath;
  final String? product;
  final String? model;
  final String? device;

  /// 长格式末尾的 `transport_id:<id>`。
  final String? transportId;

  bool get isOnline => state == 'device';

  int? get transportIdValue => int.tryParse(transportId ?? '');

  @override
  String toString() =>
      'AdbDeviceInfo($serial, $state${devPath == null ? '' : ', $devPath'})';
}

/// `host:version` 返回的服务端版本（如 `41`）。
class AdbServerVersion {
  const AdbServerVersion(this.value);

  final int value;

  static AdbServerVersion parse(String hexText) {
    final v = int.tryParse(hexText.trim(), radix: 16);
    if (v == null) {
      throw AdbInvalidResponseError('无法解析服务端版本: "$hexText"');
    }
    return AdbServerVersion(v);
  }
}

/// 连接到 `adb server`（5037）的客户端。
///
/// 请求帧为 `<hex4><service>`；响应是 4 字节 `OKAY`/`FAIL`，带返回数据的查询
/// 在 OKAY 后跟 `<hex4><payload>`，bind 传输则在 OKAY 后跟 8 字节 transport id。
class AdbHostClient {
  AdbHostClient({
    this.host = '127.0.0.1',
    this.port = 5037,
    this.connectTimeout = const Duration(seconds: 10),
  });

  final String host;
  final int port;
  final Duration connectTimeout;

  Future<Socket> _connectRaw() async {
    final socket = await Socket.connect(host, port, timeout: connectTimeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    return socket;
  }

  /// 发送 `<hex4><service>` 请求帧。
  Future<void> _sendRequest(Socket s, String service) async {
    s.add(encodeServiceRequest(service));
    await s.flush();
  }

  /// 读取 4 字节状态；OKAY 返回 true，FAIL 抛 [AdbHostError]。
  static Future<bool> _readStatus(AdbSizedReader reader, String service) async {
    final status = ascii.decode(
      await reader.readExactly(4),
      allowInvalid: true,
    );
    if (status == 'OKAY') {
      return true;
    }
    if (status == 'FAIL') {
      final lenText = ascii.decode(
        await reader.readExactly(4),
        allowInvalid: true,
      );
      final len = decodeHex4(lenText.trim());
      final reason = len > 0
          ? utf8.decode(await reader.readExactly(len), allowMalformed: true)
          : '';
      throw AdbHostError('$service: $reason');
    }
    throw AdbInvalidResponseError('非法服务端状态: $status');
  }

  /// 发送请求，读状态；若 OKAY 则读取 `hex4 + payload`，返回 payload。
  Future<Uint8List> _query(String service) async {
    final socket = await _connectRaw();
    try {
      await _sendRequest(socket, service);
      final reader = AdbSizedReader(socket);
      await _readStatus(reader, service);
      final lenText = ascii.decode(
        await reader.readExactly(4),
        allowInvalid: true,
      );
      final len = decodeHex4(lenText.trim());
      return await reader.readExactly(len);
    } finally {
      await socket.close();
    }
  }

  /// 服务端内部版本号。
  Future<AdbServerVersion> version() async {
    final payload = await _query('host:version');
    return AdbServerVersion.parse(
      utf8.decode(payload, allowMalformed: true).trim(),
    );
  }

  /// 请求服务端退出（等价于 `adb kill-server`）。
  Future<void> killServer() async {
    final socket = await _connectRaw();
    try {
      await _sendRequest(socket, 'host:kill');
      final reader = AdbSizedReader(socket);
      final status = ascii.decode(
        await reader.readExactly(4),
        allowInvalid: true,
      );
      if (status != 'OKAY') {
        if (status == 'FAIL') {
          final lenText = ascii.decode(
            await reader.readExactly(4),
            allowInvalid: true,
          );
          final len = decodeHex4(lenText.trim());
          final reason = len > 0
              ? utf8.decode(await reader.readExactly(len), allowMalformed: true)
              : '';
          throw AdbHostError('host:kill: $reason');
        }
        throw AdbInvalidResponseError('非法服务端状态: $status');
      }
    } finally {
      await socket.close();
    }
  }

  /// 列出已连接设备（`host:devices` 或 `host:devices-l`）。
  Future<List<AdbDeviceInfo>> devices({bool long = false}) async {
    final payload = await _query(long ? 'host:devices-l' : 'host:devices');
    return _parseDevices(payload, long: long);
  }

  /// Opens a shell service on any device managed by the ADB server, including
  /// USB devices. The returned stream contains raw shell output.
  Future<AdbHostShell> openShell(String serial, String command) async {
    final socket = await _connectRaw();
    final reader = AdbSizedReader(socket);
    try {
      final transportService = 'host:transport:$serial';
      await _sendRequest(socket, transportService);
      await _readStatus(reader, transportService);

      final shellService = 'shell:$command';
      await _sendRequest(socket, shellService);
      await _readStatus(reader, shellService);
      return AdbHostShell(socket, reader);
    } catch (_) {
      await reader.close();
      await socket.close();
      rethrow;
    }
  }

  /// 经 `host:transport:<serial>` 打开任意设备服务（`shell:` / `exec:` 等）。
  Future<AdbHostShell> openDeviceService(String serial, String service) async {
    final session = await _openTransport(serial);
    try {
      await _sendRequest(session.socket, service);
      await _readStatus(session.reader, service);
      return AdbHostShell(session.socket, session.reader);
    } catch (_) {
      await session.reader.close();
      await session.socket.close();
      rethrow;
    }
  }

  /// 经 host 打开设备 `sync:` 会话，用于 pull/stat。
  ///
  /// [AdbSyncChannel.close] 关掉这条 socket。上层持有它即可停止传输。
  Future<AdbSyncChannel> openSync(String serial) async {
    final session = await _openTransport(serial);
    var closed = false;
    Future<void> close() async {
      if (closed) return;
      closed = true;
      try {
        await session.reader.close();
      } catch (_) {}
      try {
        await session.socket.close();
      } catch (_) {}
    }

    try {
      await _sendRequest(session.socket, 'sync:');
      await _readStatus(session.reader, 'sync:');
      return AdbSyncChannel(
        AdbSyncClient.fromChannel(
          reader: session.reader,
          write: (data) async {
            session.socket.add(data);
            await session.socket.flush();
          },
          close: close,
        ),
        close,
      );
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<({Socket socket, AdbSizedReader reader})> _openTransport(
    String serial,
  ) async {
    final socket = await _connectRaw();
    final reader = AdbSizedReader(socket);
    try {
      final transportService = 'host:transport:$serial';
      await _sendRequest(socket, transportService);
      await _readStatus(reader, transportService);
      return (socket: socket, reader: reader);
    } catch (_) {
      await reader.close();
      await socket.close();
      rethrow;
    }
  }

  static List<AdbDeviceInfo> _parseDevices(
    Uint8List payload, {
    required bool long,
  }) {
    final text = utf8.decode(payload, allowMalformed: true);
    final list = <AdbDeviceInfo>[];
    for (final rawLine in const LineSplitter().convert(text)) {
      final tokens = rawLine.trim().split(RegExp(r'\s+'));
      if (tokens.isEmpty) continue;
      final serial = tokens[0].trim();
      final state = tokens.length > 1 ? tokens[1].trim() : '';
      if (!long) {
        list.add(AdbDeviceInfo(serial, state));
        continue;
      }

      String? devPath;
      String? product;
      String? model;
      String? device;
      String? transportId;
      for (var i = 2; i < tokens.length; i++) {
        final token = tokens[i];
        final colon = token.indexOf(':');
        if (colon >= 0) {
          final key = token.substring(0, colon);
          final value = token.substring(colon + 1);
          if (key == 'product') {
            product = value;
          } else if (key == 'model') {
            model = value;
          } else if (key == 'device') {
            device = value;
          } else if (key == 'transport_id') {
            transportId = value;
          }
        } else {
          // 无冒号裸 token = devpath（AOSP 输出里只有 devpath 不带 key）。
          devPath ??= token;
        }
      }
      list.add(
        AdbDeviceInfo(
          serial,
          state,
          devPath: devPath,
          product: product,
          model: model,
          device: device,
          transportId: transportId,
        ),
      );
    }
    return list;
  }

  /// 追踪设备列表变化（`host:track-devices`）。每个事件为最新设备列表；
  /// 取消订阅即断开连接。
  Stream<List<AdbDeviceInfo>> trackDevices({bool long = false}) {
    late StreamController<List<AdbDeviceInfo>> controller;
    late AdbSizedReader reader;
    Socket? socket;
    var closed = false;

    Future<void> run() async {
      final s = await _connectRaw();
      socket = s;
      reader = AdbSizedReader(s);
      try {
        await _sendRequest(
          s,
          long ? 'host:track-devices-l' : 'host:track-devices',
        );
        await _readStatus(reader, 'host:track-devices');
        while (!closed) {
          final lenText = ascii.decode(
            await reader.readExactly(4),
            allowInvalid: true,
          );
          final len = decodeHex4(lenText.trim());
          final payload = await reader.readExactly(len);
          if (closed) break;
          controller.add(_parseDevices(payload, long: long));
        }
      } catch (e) {
        if (!closed) {
          controller.addError(e);
        }
      } finally {
        if (!closed) {
          closed = true;
          controller.close();
        }
        await s.close();
      }
    }

    controller = StreamController<List<AdbDeviceInfo>>(
      onListen: run,
      onCancel: () {
        closed = true;
        socket?.close();
      },
    );
    return controller.stream;
  }

  /// `host:connect:<host>:<port>`。成功/失败均返回服务端描述文本。
  Future<String> connectToDevice(String targetHost, int targetPort) async {
    final payload = await _query('host:connect:$targetHost:$targetPort');
    return utf8.decode(payload, allowMalformed: true).trim();
  }

  /// `host:disconnect`。未指定目标则断开全部 TCP 设备。
  Future<String> disconnect({String? targetHost, int? targetPort}) async {
    final service = targetHost != null
        ? 'host:disconnect:$targetHost:${targetPort ?? 5555}'
        : 'host:disconnect:';
    final payload = await _query(service);
    return utf8.decode(payload, allowMalformed: true).trim();
  }

  /// `<host-prefix>:get-serialno` 等设备元信息查询。
  Future<String> _deviceQuery(
    String prefix,
    String method, {
    String? serial,
  }) async {
    final service = serial != null
        ? 'host-serial:$serial:$method'
        : '$prefix:$method';
    final payload = await _query(service);
    return utf8.decode(payload, allowMalformed: true).trim();
  }

  /// 通过序列号查询设备序列号（自描述查询）。
  Future<String> serialNo({String? serial}) => _deviceQuery(
    serial != null ? 'host-serial:$serial' : 'host',
    'get-serialno',
    serial: serial,
  );

  /// 查询设备状态：`device` / `offline` / `unauthorized` 等。
  Future<String> state({String? serial}) =>
      _deviceQuery('host', 'get-state', serial: serial);

  /// 绑定到一条传输（`host:tport:*`），返回服务端分配的 transport id。
  Future<int> bindTransport({
    String? serial,
    AdbTransportType type = AdbTransportType.any,
  }) async {
    final service = serial != null
        ? 'host:tport:serial:$serial'
        : 'host:tport:${type.name}';
    final socket = await _connectRaw();
    try {
      await _sendRequest(socket, service);
      final reader = AdbSizedReader(socket);
      await _readStatus(reader, service);
      return _readUint64LE(await reader.readExactly(8));
    } finally {
      await socket.close();
    }
  }

  /// 兼容旧式服务端：`host:transport:<serial>` / `host:transport-any`。
  /// 旧式服务端在 OKAY 后不返回 transport id（连接随之关闭），返回 0。
  Future<int> bindTransportLegacy({String? serial}) async {
    final service = serial != null
        ? 'host:transport:$serial'
        : 'host:transport-any';
    final socket = await _connectRaw();
    try {
      await _sendRequest(socket, service);
      final reader = AdbSizedReader(socket);
      await _readStatus(reader, service);
      try {
        return _readUint32LE(await reader.readExactly(4));
      } on StateError {
        return 0;
      }
    } finally {
      await socket.close();
    }
  }

  static int _readUint32LE(Uint8List b) {
    if (b.length != 4) {
      throw AdbInvalidResponseError('transport id 应为 4 字节，实际 ${b.length}');
    }
    return (b[3] << 24) | (b[2] << 16) | (b[1] << 8) | b[0];
  }

  static int _readUint64LE(Uint8List b) {
    if (b.length != 8) {
      throw AdbInvalidResponseError('transport id 应为 8 字节，实际 ${b.length}');
    }
    var value = 0;
    for (var i = 0; i < 8; i++) {
      value |= b[i] << (8 * i);
    }
    return value;
  }
}

/// 一条 `sync:` 通道：协议客户端，以及关掉底层 socket 的方法。
class AdbSyncChannel {
  AdbSyncChannel(this.client, this.close);

  final AdbSyncClient client;
  final Future<void> Function() close;
}

/// A shell stream routed through the local ADB server.
class AdbHostShell {
  AdbHostShell(this._socket, AdbSizedReader reader)
    : readStream = reader.takeRemainingStream(),
      _reader = reader;

  final Socket _socket;
  final AdbSizedReader _reader;
  final Stream<List<int>> readStream;
  bool _closed = false;

  Future<void> write(List<int> data) async {
    if (_closed) throw StateError('Shell 连接已关闭');
    _socket.add(data);
    await _socket.flush();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _reader.close();
    await _socket.close();
  }
}
