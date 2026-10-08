/// ADB 连接：CNXN/AUTH 握手 + 多流 OPEN/OKAY/WRTE/CLSE 生命周期。
///
/// 模型对应 AOSP `docs/dev/protocol.md` 与 `google/python-adb` 的
/// `AdbConnection`，设计为单后台读循环统一收发：
/// - 握手阶段由循环内置的 AUTH 状态机驱动（TOKEN→SIGNATURE→RSAPUBLICKEY→CNXN）；
/// - 连接建立后可并发打开多条流，按 local-id 分发 OKAY/WRTE/CLSE。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'adb_auth_key.dart';
import 'adb_commands.dart' as cmd;
import 'adb_exceptions.dart';
import 'adb_message.dart';
import 'adb_stream_reader.dart';
import 'adb_transport.dart';

/// 设备/主机连接结果状态。
enum AdbConnectionState {
  /// 已握手并交换 CNXN。
  device,

  /// 连接未建立 / 传输断开。
  offline,

  /// 设备要求认证但未能通过。
  unauthorized,
}

/// 一条与设备之间的数据流（对应一次 OPEN）。
///
/// 协议要求每流同一时刻至多一个未决 WRTE（收到 OKAY 才能再发下一条），
/// 因此 [write] 以内部互斥锁串行化；对端 WRTE 数据进入 [readStream]。
class AdbStream {
  AdbStream._(this._connection, this.localId);

  final AdbConnection _connection;
  final int localId;

  /// 设备端分配给这条流的 remote id；OPEN 成功的 OKAY 之后才有值。
  int? _remoteId;
  Future<void> _writeLock = Future.value();
  final StreamController<Uint8List> _incoming = StreamController(sync: true);
  final Queue<Completer<int>> _pendingAcks = Queue();
  final Completer<void> _closed = Completer<void>();
  bool _peerClosed = false;
  bool _localClosed = false;

  int get remoteId => _remoteId ?? -1;
  bool get isClosed => _peerClosed || _localClosed;

  Future<void> _completeOpen(int remoteId) {
    _remoteId = remoteId;
    return Future.value();
  }

  /// 把 [data] 写入设备并等待 OKAY（自动遵循 single-write-in-flight 约束）。
  Future<int> write(List<int> data) {
    final prev = _writeLock;
    final completer = Completer<int>();
    final chunk = Uint8List.fromList(data);
    _writeLock = prev.catchError((_) {}).then((_) async {
      try {
        if (isClosed) {
          throw AdbInvalidResponseError('stream closed before write');
        }
        final ack = Completer<int>();
        _pendingAcks.add(ack);
        await _connection._sendMessage(
          cmd.commandWrite,
          localId,
          _remoteId ?? 0,
          chunk,
        );
        await ack.future.timeout(
          _connection.writeTimeout ?? const Duration(seconds: 10),
        );
        completer.complete(chunk.length);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    _writeLock = _writeLock.catchError((_) {});
    return completer.future;
  }

  /// 写数据并立即发送 CLSE（用于 `getprop` 等一次性服务）。
  Future<void> writeAndClose(List<int> data) async {
    await write(data);
    await close();
  }

  /// 设备侧数据到达 + 回复 OKAY。
  ///
  /// 设备发来 WRITE(remote=device, local=host)，我们应答
  /// OKAY(local=host, remote=device)。
  Future<void> _onDeviceData(Uint8List data) async {
    if (!_incoming.isClosed) {
      _incoming.add(data);
    }
    await _connection._sendMessage(
      cmd.commandOkay,
      localId,
      _remoteId ?? 0,
      const [],
    );
  }

  void _onAck() {
    if (_pendingAcks.isNotEmpty) {
      final ack = _pendingAcks.removeFirst();
      ack.complete(0);
    }
  }

  void _onPeerClose() {
    if (_peerClosed) return;
    _peerClosed = true;
    if (!_incoming.isClosed) {
      _incoming.close();
    }
    if (!_closed.isCompleted) {
      _closed.complete();
    }
  }

  void _onError(Object error, StackTrace st) {
    _peerClosed = true;
    if (!_incoming.isClosed) {
      _incoming.addError(error, st);
    }
    if (!_closed.isCompleted) {
      _closed.completeError(error, st);
    }
  }

  /// 一次读取（累计 buffer），方便交互式服务流式读取。
  Future<Uint8List> readAll() async {
    final builder = BytesBuilder();
    await for (final chunk in _incoming.stream) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Stream<Uint8List> readStream() => _incoming.stream;

  Stream<String> readUtf8Lines() {
    return _incoming.stream
        .transform(
          StreamTransformer<Uint8List, String>.fromHandlers(
            handleData: (data, sink) {
              // LineSplitter 按 \n 切分；这里只负责把字节流转为字符串块。
              sink.add(utf8.decode(data, allowMalformed: true));
            },
          ),
        )
        .transform(const LineSplitter());
  }

  /// 主动关闭本地流。
  Future<void> close() async {
    if (_localClosed) return;
    _localClosed = true;
    await _connection._sendMessage(
      cmd.commandClose,
      localId,
      _remoteId ?? 0,
      const [],
    );
    if (!_incoming.isClosed) _incoming.close();
    if (!_closed.isCompleted) _closed.complete();
  }

  /// 流结束（对端 CLSE 或本地 close）后的 Future。
  Future<void> get closed => _closed.future;
}

/// 已建立的 ADB 连接（CNXN 交互完成），可并发打开多条流。
class AdbConnection {
  AdbConnection(
    AdbTransport transport, {
    this.signers,
    this.banner = 'dart-adb',
    this.authTimeout = const Duration(seconds: 30),
    this.writeTimeout,
    this.onStateChanged,
  }) : _transport = transport {
    _reader = AdbSizedReader(transport.stream);
  }

  final AdbTransport _transport;
  final List<AdbRsaKeyPair>? signers;
  final String banner;
  final Duration authTimeout;
  final Duration? writeTimeout;

  /// 握手状态变化。本机 ADB Server 用它把设备标成 `unauthorized` 或 `device`。
  final void Function(AdbConnectionState state)? onStateChanged;

  late final AdbSizedReader _reader;
  final Map<int, AdbStream> _streams = {};
  final Map<int, Completer<AdbStream>> _openWaiters = {};
  int _nextLocalId = 1;

  bool _connected = false;
  String _deviceBanner = '';
  String _deviceSerial = '';
  String _features = '';

  // AUTH 状态机。
  int _authSignaturesSent = 0;
  bool _awaitingUserAuth = false;

  AdbConnectionState _state = AdbConnectionState.offline;

  AdbConnectionState get state => _state;
  String get deviceBanner => _deviceBanner;

  /// CNXN banner 里的 `features=`。官方 `adb shell` 会先查 `host:features`。
  String get features => _features;
  String get deviceSerial => _deviceSerial;
  bool get isConnected => _connected;

  final Completer<void> _connectCompleter = Completer<void>();
  Object? _connectError;

  /// 串行化所有线上帧（含 ACK）：`Socket.add` + `flush` 并发会触发
  /// Dart `StreamSink is bound to a stream`（flush 置 `_isBound`），
  /// 读循环的流 ACK 与主线程帧写入必须排队。
  Future<void> _writeQueue = Future.value();

  Future<void> _sendMessage(int command, int arg0, int arg1, List<int> data) {
    final msg = AdbMessage(command, arg0, arg1, data);
    final bytes = msg.pack();
    final prev = _writeQueue;
    final done = Completer<void>();
    _writeQueue = prev.catchError((_) {}).then((_) async {
      try {
        await _transport.write(bytes);
        done.complete();
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  /// 建立连接：发送 CNXN 并驱动握手，成功返回设备 banner。
  Future<String> connect() async {
    await _sendMessage(
      cmd.commandCnxn,
      cmd.version,
      cmd.maxAdbData,
      encodeConnectPayload(type: 'host', serial: '', banner: banner),
    );
    _readLoop();
    await _connectCompleter.future.timeout(
      authTimeout,
      onTimeout: () {
        if (!_connectCompleter.isCompleted) {
          _connectCompleter.complete();
          _connectError ??= _awaitingUserAuth
              ? AdbDeviceAuthError('等待设备确认公钥授权超时（${authTimeout.inSeconds}s）')
              : AdbInvalidResponseError('连接超时');
        }
      },
    );
    if (_connectError != null) {
      throw _connectError!;
    }
    return _deviceBanner;
  }

  Future<void> _readLoop() {
    return () async {
      try {
        while (true) {
          final msg = await readAdbMessage(_reader);
          await _dispatch(msg);
        }
      } catch (e, st) {
        _setState(AdbConnectionState.offline);
        if (!_connectCompleter.isCompleted) {
          _connectCompleter.complete();
          _connectError = e;
        }
        _failAllStreams(e, st);
      }
    }();
  }

  Future<void> _dispatch(AdbMessage msg) async {
    switch (msg.command) {
      case cmd.commandCnxn:
        _onCnxn(msg);
      case cmd.commandAuth:
        await _onAuth(msg);
      case cmd.commandOkay:
        _onOkay(msg);
      case cmd.commandWrite:
        await _onWrite(msg);
      case cmd.commandClose:
        _onClose(msg);
      default:
        throw AdbInvalidCommandError('未知命令: ${msg.command}', data: msg);
    }
  }

  void _onCnxn(AdbMessage msg) {
    // 记录设备版本/序列号/banner。
    final payload = msg.data;
    final text = utf8.decode(
      payload.takeWhile((b) => b != 0).toList(),
      allowMalformed: true,
    );
    final parts = text.split(':');
    if (parts.length >= 2) {
      _deviceSerial = parts[1];
    }
    if (parts.length >= 3) {
      _deviceBanner = parts.sublist(2).join(':');
    } else {
      _deviceBanner = text;
    }
    if (!_connected) {
      _connected = true;
      _awaitingUserAuth = false;
      _features = _bannerFeatures(_deviceBanner);
      _setState(AdbConnectionState.device);
      if (!_connectCompleter.isCompleted) _connectCompleter.complete();
    }
  }

  String _bannerFeatures(String banner) {
    for (final prop in banner.split(';')) {
      if (!prop.startsWith('features=')) continue;
      return prop.substring('features='.length);
    }
    return '';
  }

  Future<void> _onAuth(AdbMessage msg) async {
    if (msg.arg0 == cmd.authToken) {
      final signers = this.signers;
      if (signers == null || signers.isEmpty) {
        throw AdbDeviceAuthError('设备要求认证但没有可用的 RSA 私钥');
      }
      final idx = _authSignaturesSent;
      if (idx < signers.length) {
        _authSignaturesSent++;
        final sig = signers[idx].signToken(msg.data);
        await _sendMessage(cmd.commandAuth, cmd.authSignature, 0, sig);
      } else {
        // 所有密钥都被拒绝，发送公钥等待用户授权。
        final key = signers.first;
        final pub = Uint8List.fromList([
          ...utf8.encode(key.base64PublicKey()),
          0,
        ]);
        await _sendMessage(cmd.commandAuth, cmd.authRsaPublicKey, 0, pub);
        _awaitingUserAuth = true;
        _setState(AdbConnectionState.unauthorized);
      }
    }
  }

  void _setState(AdbConnectionState value) {
    if (_state == value) return;
    _state = value;
    onStateChanged?.call(value);
  }

  void _onOkay(AdbMessage msg) {
    final localId = msg.arg1;
    final remoteId = msg.arg0;
    final waiter = _openWaiters.remove(localId);
    if (waiter != null) {
      // 首次 OKAY：OPEN 成功，建立 remote id。
      final stream = _streams[localId];
      if (stream != null) {
        stream._completeOpen(remoteId);
        waiter.complete(stream);
      } else {
        waiter.completeError(
          AdbInvalidResponseError('OPEN 批复丢失流: local=$localId'),
        );
      }
      return;
    }
    final stream = _streams[localId];
    if (stream != null) {
      stream._onAck();
    }
  }

  Future<void> _onWrite(AdbMessage msg) async {
    final localId = msg.arg1;
    final stream = _streams[localId];
    if (stream == null) return;
    // 设备 WRITE(local=device, remote=host)。若设备在 OKAY 前就先发数据，
    // 用帧里的设备侧 id 补记 remote id，保证 ACK 的 arg1 正确。
    stream._remoteId ??= msg.arg0;
    await stream._onDeviceData(msg.data);
  }

  void _onClose(AdbMessage msg) {
    final localId = msg.arg1;
    final waiter = _openWaiters.remove(localId);
    final stream = _streams.remove(localId);
    if (waiter != null) {
      // 失败的 OPEN：设备直接 CLSE，不给 OKAY。
      if (stream != null) {
        stream._completeOpen(msg.arg0);
        stream._onPeerClose();
      }
      waiter.completeError(
        AdbInvalidResponseError(
          '设备拒绝服务 OPEN(local=$localId)（remoteId=${msg.arg0}）',
        ),
      );
      return;
    }
    if (stream != null) {
      stream._onPeerClose();
    }
  }

  /// 打开一条服务流，如 `shell:getprop`、`shell:ls -l /`、`sync:`。
  Future<AdbStream> open(String destination) async {
    if (!_connected) {
      throw StateError('连接尚未建立，无法打开流');
    }
    final localId = _nextLocalId++;
    final stream = AdbStream._(this, localId);
    _streams[localId] = stream;
    final waiter = Completer<AdbStream>();
    _openWaiters[localId] = waiter;
    await _sendMessage(cmd.commandOpen, localId, 0, [
      ...utf8.encode(destination),
      0,
    ]);
    return waiter.future;
  }

  /// 单条服务：打开流，读取所有响应，返回字节。可选附带一次输入。
  ///
  /// 对无需客户端输入的 `shell:xxx` / `getprop` 等服务，设备运行完毕会主动
  /// 关闭流；对需要输入的服务（如交互 shell）请使用 [open] 后手动控制。
  Future<Uint8List> service(String destination, {List<int>? input}) async {
    final stream = await open(destination);
    if (input != null && input.isNotEmpty) {
      await stream.writeAndClose(input);
    }
    return await stream.readAll();
  }

  /// 便捷：向 `shell:<command>` 运行命令并返回全部输出。
  Future<String> shell(String command) async {
    final data = await service('shell:$command');
    return utf8.decode(data, allowMalformed: true);
  }

  /// 便捷：运行 getprop 并解析为键值对。
  Future<Map<String, String>> getSystemProperties() async {
    final out = await shell('getprop');
    final props = <String, String>{};
    for (final line in const LineSplitter().convert(out)) {
      final match = RegExp(r'^\[(.*)\]:\s*\[(.*)\]\s*$').firstMatch(line);
      if (match != null) {
        props[match.group(1)!] = match.group(2)!;
      }
    }
    return props;
  }

  void _failAllStreams(Object e, StackTrace st) {
    for (final s in _streams.values.toList()) {
      s._onError(e, st);
    }
    _streams.clear();
    for (final w in _openWaiters.values.toList()) {
      if (!w.isCompleted) w.completeError(e, st);
    }
    _openWaiters.clear();
  }

  Future<void> close() async {
    for (final s in _streams.values.toList()) {
      s._onPeerClose();
    }
    _streams.clear();
    for (final w in _openWaiters.values.toList()) {
      if (!w.isCompleted) {
        w.completeError(StateError('连接已关闭'));
      }
    }
    _openWaiters.clear();
    await _transport.close();
  }
}
