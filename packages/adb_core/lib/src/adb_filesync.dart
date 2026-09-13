/// file_sync（`sync:` 服务）客户端实现。
///
/// 基于 AOSP `sync.md` 与 `file_sync_protocol.h`，兼容 v1 线格式：
/// - 请求/响应帧 = 4 字节 ASCII id + 4 字节 Little-Endian length + 数据；
/// - STAT 响应固定 16 字节（无 length 字段：id/mode/size/mtime）；
/// - LIST 的 DENT 固定 20 字节（id/mode/size/mtime/namelen + name）；
/// - SEND 的 DONE 隐藏 mtime 在 length 字段，设备回 OKAY/FAIL。
///
/// 时序上完全串行：一次打开 sync 流后按需调用 [stat]/[list]/[pull]/[push]，
/// 每个调用内部按帧读回响应，期间不可穿插其它调用。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'adb_connection.dart';
import 'adb_exceptions.dart';
import 'adb_stream_reader.dart';

/// sync 帧 id（4 字节 ASCII）。
const String kSyncIdStat = 'STAT';
const String kSyncIdList = 'LIST';
const String kSyncIdSend = 'SEND';
const String kSyncIdRecv = 'RECV';
const String kSyncIdData = 'DATA';
const String kSyncIdDone = 'DONE';
const String kSyncIdOkay = 'OKAY';
const String kSyncIdFail = 'FAIL';
const String kSyncIdDent = 'DENT';
const String kSyncIdQuit = 'QUIT';

/// 单帧最大数据长度（协议要求 ≤ 64KB）。
const int kMaxSyncData = 64 * 1024;

Uint8List _encodeSyncId(String id) =>
    Uint8List.fromList(id.codeUnits);

int _readUint32LE(Uint8List b, int offset) =>
    (b[offset + 3] << 24) |
    (b[offset + 2] << 16) |
    (b[offset + 1] << 8) |
    b[offset];

void _writeUint32LE(BytesBuilder b, int value) {
  b.addByte(value & 0xff);
  b.addByte((value >> 8) & 0xff);
  b.addByte((value >> 16) & 0xff);
  b.addByte((value >> 24) & 0xff);
}

/// 设备的单个文件属性。
class AdbFileStat {
  const AdbFileStat({required this.mode, required this.size, required this.mtime});

  final int mode;
  final int size;
  final int mtime;

  bool get isDirectory =>
      mode & 0xf000 == 0x4000; // 0o40000 S_IFDIR

  @override
  String toString() =>
      'AdbFileStat(mode=${mode.toRadixString(8)}, size=$size, mtime=$mtime)';
}

/// 目录项。
class AdbFileEntry {
  const AdbFileEntry(this.name, this.mode, this.size, this.mtime);

  final String name;
  final int mode;
  final int size;
  final int mtime;

  bool get isDirectory => mode & 0xf000 == 0x4000;
}

/// [push] 或 [pull] 时接收到的进度回调。
typedef AdbTransferProgress = void Function(int bytesDone, int totalBytes);

/// 绑定到一条 `sync:` 流的 file_sync 客户端。
class AdbSyncClient {
  AdbSyncClient(this._stream)
      : _reader = AdbSizedReader(_stream.readStream());

  final AdbStream _stream;
  final AdbSizedReader _reader;

  /// 读取一帧：返回 (id, length, data)。
  Future<(String, int, Uint8List)> _readFrame() async {
    final header = await _reader.readExactly(8);
    final id = String.fromCharCodes(header.sublist(0, 4));
    final length = _readUint32LE(header, 4);
    final data = length > 0 ? await _reader.readExactly(length) : Uint8List(0);
    return (id, length, data);
  }

  /// 发送一帧。
  /// 发送一帧。
  Future<void> _writeFrame(String id, {Uint8List? data}) async {
    final d = data ?? Uint8List(0);
    final builder = BytesBuilder()..add(_encodeSyncId(id));
    _writeUint32LE(builder, d.length);
    builder.add(d);
    await _stream.write(builder.takeBytes());
  }

  /// 读取 STAT/LIST 的 16/20 字节固定头部响应。
  Future<(String, List<int>)> _readFixedHeader(int len) async {
    final header = await _reader.readExactly(len);
    final id = String.fromCharCodes(header.sublist(0, 4));
    return (id, header.sublist(4));
  }

  Future<void> _sendPath(String id, String path) {
    return _writeFrame(id, data: Uint8List.fromList([...utf8.encode(path), 0]));
  }

  /// stat 远端文件。
  Future<AdbFileStat> stat(String path) async {
    await _sendPath(kSyncIdStat, path);
    final (id, fields) = await _readFixedHeader(16);
    if (id != kSyncIdStat && id != kSyncIdDone) {
      throw AdbInvalidResponseError('期望 STAT/DONE，收到 $id');
    }
    return AdbFileStat(
      mode: _readUint32LE(Uint8List.fromList(fields), 0),
      size: _readUint32LE(Uint8List.fromList(fields), 4),
      mtime: _readUint32LE(Uint8List.fromList(fields), 8),
    );
  }

  /// 列出远端目录。
  Future<List<AdbFileEntry>> list(String path) async {
    await _sendPath(kSyncIdList, path);
    final entries = <AdbFileEntry>[];
    while (true) {
      final (id, fields) = await _readFixedHeader(20);
      final nameLen = _readUint32LE(Uint8List.fromList(fields), 12);
      if (id == kSyncIdDone) {
        break;
      }
      if (id != kSyncIdDent) {
        throw AdbInvalidResponseError('期望 DENT/DONE，收到 $id');
      }
      final nameBytes = nameLen > 0 ? await _reader.readExactly(nameLen) : Uint8List(0);
      entries.add(AdbFileEntry(
        utf8.decode(nameBytes, allowMalformed: true),
        _readUint32LE(Uint8List.fromList(fields), 0),
        _readUint32LE(Uint8List.fromList(fields), 4),
        _readUint32LE(Uint8List.fromList(fields), 8),
      ));
    }
    return entries;
  }

  /// 拉取远端文件为字节。
  Future<Uint8List> pull(
    String path, {
    AdbTransferProgress? onProgress,
  }) async {
    await _sendPath(kSyncIdRecv, path);
    final builder = BytesBuilder();
    while (true) {
      final (id, length, data) = await _readFrame();
      if (id == kSyncIdDone) break;
      if (id == kSyncIdData) {
        builder.add(data);
        onProgress?.call(builder.length, -1);
      } else if (id == kSyncIdFail) {
        throw AdbSyncError(utf8.decode(data, allowMalformed: true));
      } else {
        throw AdbInvalidResponseError('期望 DATA/DONE/FAIL，收到 $id');
      }
    }
    return builder.takeBytes();
  }

  /// 推送字节到远端。
  Future<void> push(
    List<int> bytes,
    String remotePath, {
    int mode = 0x81a4, // 0o100644
    int? mtime,
    AdbTransferProgress? onProgress,
  }) async {
    final spec = '$remotePath,$mode';
    await _writeFrame(kSyncIdSend,
        data: Uint8List.fromList([...utf8.encode(spec), 0]));
    final data = Uint8List.fromList(bytes);
    var written = 0;
    while (written < data.length) {
      final n = _chunkSize(data.length - written);
      final chunk = Uint8List.sublistView(data, written, written + n);
      await _writeFrame(kSyncIdData, data: chunk);
      written += n;
      onProgress?.call(written, data.length);
    }
    final m = mtime ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    final done = BytesBuilder()..add(_encodeSyncId(kSyncIdDone));
    _writeUint32LE(done, m);
    await _stream.write(done.takeBytes());
    final (id, _, failData) = await _readFrame();
    if (id == kSyncIdFail) {
      throw AdbSyncError(utf8.decode(failData, allowMalformed: true));
    }
    if (id != kSyncIdOkay && id != kSyncIdDone) {
      throw AdbInvalidResponseError('期望 OKAY/FAIL，收到 $id');
    }
  }

  static int _chunkSize(int remaining) =>
      remaining < kMaxSyncData ? remaining : kMaxSyncData;

  /// 通知设备结束 sync 会话。
  Future<void> quit() async {
    try {
      await _writeFrame(kSyncIdQuit);
    } catch (_) {
      // 对端可能已关闭。
    }
    await _stream.close();
  }
}

/// [push]/[pull]/[stat]/[list] 等失败（设备回 FAIL）。
class AdbSyncError implements Exception {
  AdbSyncError(this.message);

  final String message;

  @override
  String toString() => 'AdbSyncError: $message';
}