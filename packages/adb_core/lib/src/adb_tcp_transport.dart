/// 基于 `dart:io` 的 TCP 传输，用于直连设备（WiFi 5555 / 模拟器端口）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'adb_transport.dart';

class AdbTcpTransport implements AdbTransport {
  AdbTcpTransport._(this._socket);

  final Socket _socket;
  bool _closed = false;

  /// 连接到 [host]:[port]（默认为 adb 的 5555 端口）。
  static Future<AdbTcpTransport> connect(
    String host,
    int port, {
    Duration connectTimeout = const Duration(seconds: 10),
  }) async {
    final socket = await Socket.connect(
      host,
      port,
      timeout: connectTimeout,
    );
    socket.setOption(SocketOption.tcpNoDelay, true);
    return AdbTcpTransport._(socket);
  }

  @override
  Stream<Uint8List> get stream => _socket;

  @override
  Future<void> write(List<int> data) async {
    if (_closed) {
      throw StateError('传输已关闭，无法写入');
    }
    _socket.add(Uint8List.fromList(data));
    await _socket.flush();
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _socket.close();
  }
}