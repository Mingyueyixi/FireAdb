/// 基于 `dart:io` 的 TCP 传输，用于直连设备（WiFi 5555 / 模拟器端口）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'adb_transport.dart';

/// 链路本地 IPv6 必须带上网卡标识，否则 `connect` 会返回 EINVAL。
///
/// 已带 `%` 的地址、IPv4 和全局 IPv6 原样返回。
List<String> linkLocalConnectHosts(
  String host,
  Iterable<({String name, int index})> interfaces,
) {
  final parsed = InternetAddress.tryParse(host);
  if (parsed == null ||
      parsed.type != InternetAddressType.IPv6 ||
      !parsed.isLinkLocal ||
      host.contains('%')) {
    return <String>[host];
  }
  final hosts = <String>[];
  for (final iface in interfaces) {
    hosts.add('$host%${iface.name}');
    hosts.add('$host%${iface.index}');
  }
  if (hosts.isEmpty) hosts.add(host);
  return hosts;
}

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
    final socket = await _connectSocket(host, port, connectTimeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    return AdbTcpTransport._(socket);
  }

  static Future<Socket> _connectSocket(
    String host,
    int port,
    Duration connectTimeout,
  ) async {
    final targets = await _connectTargets(host);
    if (targets.length == 1) {
      return Socket.connect(targets.single, port, timeout: connectTimeout);
    }
    final completer = Completer<Socket>();
    var pending = targets.length;
    Object? lastError;
    StackTrace? lastStack;
    for (final target in targets) {
      unawaited(
        Socket.connect(target, port, timeout: connectTimeout).then(
          (socket) {
            if (completer.isCompleted) {
              socket.destroy();
              return;
            }
            completer.complete(socket);
          },
          onError: (Object error, StackTrace stackTrace) {
            lastError = error;
            lastStack = stackTrace;
            pending -= 1;
            if (pending == 0 && !completer.isCompleted) {
              completer.completeError(
                lastError ?? error,
                lastStack ?? stackTrace,
              );
            }
          },
        ),
      );
    }
    return completer.future;
  }

  static Future<List<String>> _connectTargets(String host) async {
    final parsed = InternetAddress.tryParse(host);
    if (parsed == null ||
        parsed.type != InternetAddressType.IPv6 ||
        !parsed.isLinkLocal ||
        host.contains('%')) {
      return <String>[host];
    }
    final interfaces = await NetworkInterface.list(
      includeLinkLocal: true,
      type: InternetAddressType.IPv6,
    );
    return linkLocalConnectHosts(host, <({String name, int index})>[
      for (final iface in interfaces)
        if (iface.addresses.any((address) => address.isLinkLocal))
          (name: iface.name, index: iface.index),
    ]);
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
