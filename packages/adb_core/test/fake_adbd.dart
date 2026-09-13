/// 内存双端传输 + 一个行为可配置的“伪 adbd”，用于端到端协议测试。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:adb_core/adb_core.dart';

/// 内存传输配对：一端 [host]（给 [AdbConnection]），另一端 [device]（给伪 adbd）。
class MemoryPair {
  MemoryPair._(this.host, this.device);

  final AdbTransport host;
  final AdbTransport device;

  static MemoryPair create() {
    final hostIn = StreamController<Uint8List>(); // 设备写 → 主机读
    final deviceIn = StreamController<Uint8List>(); // 主机写 → 设备读
    return MemoryPair._(
      _MemoryTransport(hostIn, deviceIn),
      _MemoryTransport(deviceIn, hostIn),
    );
  }
}

class _MemoryTransport implements AdbTransport {
  _MemoryTransport(this._in, this._out);

  final StreamController<Uint8List> _in;
  final StreamController<Uint8List> _out;
  bool _closed = false;

  @override
  Stream<Uint8List> get stream => _in.stream;

  @override
  Future<void> write(List<int> data) async {
    if (_closed) throw StateError('transport closed');
    _out.add(Uint8List.fromList(data));
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _out.close();
  }
}

/// 模拟设备协议服务（设备侧行为）。
///
/// 认证行为：
/// - 收到 CNXN 后发送 AUTH(TOKEN)。
/// - 对每个 AUTH(SIGNATURE)：
///   - 经 [verifySignature] 校验成功 → 发送 CNXN，握手完成。
///   - 失败 → 发送新的 AUTH(TOKEN)。
/// - 所有签名失败后客户端会发送 RSAPUBLICKEY：
///   - [autoInstallPublicKey] 为 true → 视为通过并发送 CNXN。
///   - 否则保持沉默（模拟等待用户确认）。
///
/// 连接后按 [serviceHandler] 服务 `shell:xxx` 等流；`sync:` 流走
/// [syncFiles] 内存文件系统（STAT/LIST/SEND/RECV/QUIT，v1 线格式）。
class FakeAdbd {
  FakeAdbd({
    this.serial = 'fake12345',
    this.banner = 'product:model',
    this.autoInstallPublicKey = true,
    this.verifyKey,
    Map<String, Uint8List>? syncFiles,
  }) : _syncFiles = syncFiles ?? {};

  final String serial;
  final String banner;
  final bool autoInstallPublicKey;

  /// 设备“已授权”的主机公钥（用于 SIGNATURE 校验）。null 表示设备没有任何
  /// 已授权密钥，仅接受 RSAPUBLICKEY 途径。
  final AdbRsaKeyPair? verifyKey;

  /// 内存文件系统：路径 → 内容。路径以 / 开头、无尾随 /。
  final Map<String, Uint8List> _syncFiles;

  Uint8List? syncContent(String path) => _syncFiles[path];

  final List<AdbMessage> received = [];
  final List<AdbMessage> sent = [];
  final Completer<void> _done = Completer<void>();

  /// 设备进程结束（对端传输关闭）后完成。
  Future<void> get done => _done.future;

  AdbSizedReader? _reader;
  AdbTransport? _transport;
  Uint8List? _currentToken;
  int _remoteOpenSeq = 500; // 设备侧 local id 空间

  final Set<int> _echoStreams = {};
  final Map<int, _FakeSyncSession> _syncSessions = {};

  /// 处理 OPEN 的 dest。
  ///
  /// 返回非 null：设备发送该字符串一次后立即 CLSE（一次性服务）；
  /// 返回 null：流保持开启（echo 模式），设备仅对 WRTE 回 ONLINE。
  Future<String?> Function(String dest)? serviceHandler;

  /// 设备侧主循环。返回后表示设备已退出。
  Future<void> serve(AdbTransport deviceTransport) async {
    _transport = deviceTransport;
    _reader = AdbSizedReader(deviceTransport.stream);
    try {
      // 等待客户端 CNXN
      while (true) {
        final msg = await readAdbMessage(_reader!, verifyChecksum: false);
        received.add(msg);
        if (msg.command == commandCnxn) {
          break;
        }
      }
      await _runAuth();
      await _serveStreams();
    } catch (_) {
      // 对端关闭或协议错误：设备退出。
    } finally {
      if (!_done.isCompleted) _done.complete();
    }
  }

  Future<void> _runAuth() async {
    while (true) {
      await _sendAuthToken();
      final msg = await readAdbMessage(_reader!, verifyChecksum: false);
      received.add(msg);
      if (msg.command == commandAuth && msg.arg0 == authSignature) {
        final key = verifyKey;
        if (key != null && key.verifyToken(_currentToken!, msg.data)) {
          await _sendConnect();
          return;
        }
        // 验签失败：循环发送新 token。
      } else if (msg.command == commandAuth &&
          msg.arg0 == authRsaPublicKey) {
        if (autoInstallPublicKey) {
          await _sendConnect();
          return;
        }
        // 不回复，等待超时。
        break;
      } else if (msg.command == commandCnxn) {
        return;
      }
    }
  }

  Future<void> _serveStreams() async {
    while (true) {
      final msg = await readAdbMessage(_reader!, verifyChecksum: false);
      received.add(msg);
      switch (msg.command) {
        case commandOpen:
          final dest =
              String.fromCharCodes(msg.data.takeWhile((b) => b != 0));
          final localId = _remoteOpenSeq++;
          // 先回 OPEN 的 OKAY。
          await _send(
              AdbMessage(commandOkay, localId, msg.arg0, const []));
          if (dest == 'sync:') {
            // 二进制的 sync 协议：后续 WRTE 交给会话处理。
            _syncSessions[msg.arg0] = _FakeSyncSession(
                deviceId: localId, hostId: msg.arg0, data: _syncFiles, send: _send);
            continue;
          }
          final out =
              serviceHandler != null ? await serviceHandler!(dest) : '';
          if (out == null) {
            _echoStreams.add(msg.arg0); // 保持开启，进入 echo 模式。
          } else if (out.isNotEmpty) {
            await _send(AdbMessage(commandWrite, localId, msg.arg0,
                Uint8List.fromList(out.codeUnits)));
            await _send(
                AdbMessage(commandClose, localId, msg.arg0, const []));
          } else {
            await _send(
                AdbMessage(commandClose, localId, msg.arg0, const []));
          }
        case commandWrite:
          // 主机的 WRTE：ACK + 若 echo 流则回显。
          final hostId = msg.arg0;
          await _send(
              AdbMessage(commandOkay, msg.arg1, hostId, const []));
          final session = _syncSessions[hostId];
          if (session != null) {
            session.feed(msg.data);
          } else if (_echoStreams.contains(hostId)) {
            await _send(AdbMessage(commandWrite, msg.arg1, hostId,
                Uint8List.fromList(msg.data)));
          }
        case commandOkay:
          // 设备侧 WRTE 的主机 ACK：无需处理。
          break;
        case commandClose:
          _echoStreams.remove(msg.arg0);
          _syncSessions.remove(msg.arg0);
          break;
      }
    }
  }

  Future<void> _sendAuthToken() async {
    final rnd = List<int>.generate(kAdbTokenSize, (i) => i * 7 + 3);
    _currentToken = Uint8List.fromList(rnd);
    await _send(AdbMessage(commandAuth, authToken, 0, _currentToken!));
  }

  Future<void> _sendConnect() async {
    await _send(AdbMessage(
      commandCnxn,
      version,
      maxAdbData,
      encodeConnectPayload(type: 'device', serial: serial, banner: banner),
    ));
  }

  Future<void> _send(AdbMessage msg) async {
    if (_transport == null) return;
    sent.add(msg);
    await _transport!.write(msg.pack());
  }

  /// 关闭设备端（供测试清理）。
  Future<void> close() async {
    await _transport?.close();
  }
}

const int _syncModeFile = 0x81a4; // 0o100644
const int _syncModeDir = 0x41ed; // 0o40755

Uint8List _u32le(int value) => Uint8List.fromList([
      value & 0xff,
      (value >> 8) & 0xff,
      (value >> 16) & 0xff,
      (value >> 24) & 0xff,
    ]);

int _le32(List<int> b, int offset) =>
    (b[offset + 3] << 24) |
    (b[offset + 2] << 16) |
    (b[offset + 1] << 8) |
    b[offset];

int _syncNow() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// `sync:` 会话：解析请求帧并回复（v1 线格式）。
///
/// 帧规则（对应 `file_sync_protocol.h`）：
/// - 请求（STAT/LIST/RECV/SEND/DATA/DONE/QUIT）都带 4 字节 LE 长度；
/// - STAT 回复 = 4 字节 id + mode/size/time 各 4 字节（无长度字段）；
/// - LIST 回复条目 = DENT 固定 20 字节 + name；结束 = DONE 固定 20 字节；
/// - RECV 回复 = DATA + 4 字节 LE 长度 + 块，收尾 DONE + 4 字节实际长度；
/// - SEND 回复 = OKAY/FAIL + 4 字节长度字段。
///
/// 所有回复经 WRTE 发往主机流（[hostId]）。
class _FakeSyncSession {
  _FakeSyncSession({
    required this.deviceId,
    required this.hostId,
    required Map<String, Uint8List> data,
    required this.send,
    // ignore: prefer_initializing_formals
  }) : _data = data;

  final int deviceId;
  final int hostId;
  final Map<String, Uint8List> _data;
  final Future<void> Function(AdbMessage) send;

  final BytesBuilder _buffer = BytesBuilder();
  Future<void> _lock = Future<void>.value();
  String? _pendingSendPath;
  BytesBuilder? _pendingSendData;

  /// 设备侧写一条 WRTE 数据帧。
  void _frame(String id, {List<int>? body, required bool withPrefix}) {
    final frame = BytesBuilder()
      ..add(Uint8List.fromList(id.codeUnits));
    if (withPrefix) {
      final b = body ?? const <int>[];
      frame.add(_u32le(b.length));
      if (b.isNotEmpty) frame.add(b);
    } else {
      frame.add(body ?? const <int>[]);
    }
    send(AdbMessage(commandWrite, deviceId, hostId, frame.takeBytes()));
  }

  /// 供设备侧处理 WRTE 数据。串行化以防条目被交错。
  void feed(List<int> chunk) {
    final next = _lock.then((_) async {
      _buffer.add(chunk);
      final bytes = _buffer.takeBytes();
      var offset = 0;
      // 完成所有完整请求。SEND 的 DATA/DONE 也各是一帧。
      while (offset < bytes.length) {
        if (bytes.length - offset < 8) {
          _buffer.add(Uint8List.sublistView(bytes, offset));
          return;
        }
        final idString =
            String.fromCharCodes(bytes.sublist(offset, offset + 4));
        final length = _le32(bytes, offset + 4);
        if (idString == 'DONE') {
          // DONE 帧没有 body：length 字段携带 mtime。
          await _handleRequest('DONE', length, const <int>[]);
          offset += 8;
          continue;
        }
        if (bytes.length - offset < 8 + length) {
          _buffer.add(Uint8List.sublistView(bytes, offset));
          return;
        }
        final body = bytes.sublist(offset + 8, offset + 8 + length);
        await _handleRequest(idString, length, body);
        offset += 8 + length;
      }
    });
    _lock = next.catchError((_) {});
  }

  Future<void> _handleRequest(String id, int length, List<int> body) async {
    switch (id) {
      case 'STAT':
        final path =
            utf8.decode(body, allowMalformed: true).split('\x00').first;
        final info = _statInfo(path);
        _frame('STAT', body: info, withPrefix: false);
      case 'LIST':
        final path =
            utf8.decode(body, allowMalformed: true).split('\x00').first;
        await _sendList(path);
      case 'RECV':
        final path =
            utf8.decode(body, allowMalformed: true).split('\x00').first;
        await _sendRecv(path);
      case 'SEND':
        // body = "path,mode\0"
        final spec =
            utf8.decode(body, allowMalformed: true).split('\x00').first;
        final comma = spec.lastIndexOf(',');
        _pendingSendPath = spec.substring(0, comma);
        _pendingSendData = BytesBuilder();
      case 'DATA':
        _pendingSendData!.add(body);
      case 'DONE':
        // DONE 帧没有 body，length 字段携带 mtime（本伪设备不保存）。
        final content = _pendingSendData!.takeBytes();
        _data[_pendingSendPath!] = content;
        _pendingSendPath = null;
        _pendingSendData = null;
        _frame('OKAY', withPrefix: true);
      case 'QUIT':
        break;
    }
  }

  Uint8List _statInfo(String path) {
    final content = _data[path];
    if (content != null) {
      final b = BytesBuilder()
        ..add(_u32le(_syncModeFile))
        ..add(_u32le(content.length))
        ..add(_u32le(_syncNow()));
      return b.takeBytes();
    }
    if (_isImplicitDir(path)) {
      final b = BytesBuilder()
        ..add(_u32le(_syncModeDir))
        ..add(_u32le(0))
        ..add(_u32le(_syncNow()));
      return b.takeBytes();
    }
    // 不存在：真实 adbd 对缺失文件回 mode=0。
    return Uint8List(12);
  }

  bool _isImplicitDir(String path) {
    final base = path == '/' ? '' : path;
    final prefix = '$base/';
    return _data.keys.any((k) => k.startsWith(prefix));
  }

  Future<void> _sendList(String path) async {
    final base = path == '/' ? '' : path;
    final prefix = '$base/';
    final seen = <String>{};
    final entries = <(String, int, int)>[]; // name, mode, size
    for (final k in _data.keys.where((k) => k.startsWith(prefix))) {
      final rest = k.substring(prefix.length);
      final slash = rest.indexOf('/');
      final name = slash < 0 ? rest : rest.substring(0, slash);
      final isFile = slash < 0;
      if (seen.add(name)) {
        final content = isFile ? _data[k] : null;
        entries.add((
          name,
          isFile ? _syncModeFile : _syncModeDir,
          content?.length ?? 0,
        ));
      }
    }
    entries.sort((a, b) => a.$1.compareTo(b.$1));
    for (final (name, mode, size) in entries) {
      final nameBytes = utf8.encode(name);
      final body = BytesBuilder()
        ..add(_u32le(mode))
        ..add(_u32le(size))
        ..add(_u32le(_syncNow()))
        ..add(_u32le(nameBytes.length))
        ..add(nameBytes);
      _frame('DENT', body: body.takeBytes(), withPrefix: false);
    }
    // LIST 结束：DONE 固定 20 字节（mode/size/time/namelen=0）。
    _frame('DONE', body: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        withPrefix: false);
  }

  Future<void> _sendRecv(String path) async {
    final content = _data[path];
    if (content == null) {
      _frame('FAIL', body: utf8.encode('open failed: no such file or directory'),
          withPrefix: true);
      return;
    }
    var offset = 0;
    while (offset < content.length) {
      final n = content.length - offset < 64000
          ? content.length - offset
          : 64000;
      _frame('DATA',
          body: Uint8List.sublistView(content, offset, offset + n),
          withPrefix: true);
      offset += n;
    }
    _frame('DONE', body: _u32le(0), withPrefix: true);
  }
}