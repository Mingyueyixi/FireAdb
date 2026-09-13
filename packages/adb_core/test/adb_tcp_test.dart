import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:adb_core/adb_core.dart';
import 'package:test/test.dart';

import 'fake_adbd.dart';

/// 把真实的 [Socket] 包装成设备侧 [AdbTransport]，让伪 adbd 跑在真实 TCP 上。
class _SocketTransport implements AdbTransport {
  _SocketTransport(this._socket) {
    _subscription = _socket.listen(
      _incoming.add,
      onDone: _incoming.close,
      onError: (Object e, StackTrace st) => _incoming.addError(e, st),
      cancelOnError: true,
    );
  }

  final Socket _socket;
  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>();
  late final StreamSubscription<Uint8List> _subscription;
  bool _closed = false;

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  Future<void> write(List<int> data) async {
    if (_closed) throw StateError('transport closed');
    _socket.add(data);
    await _socket.flush();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    await _incoming.close();
    _socket.destroy();
  }
}

Future<void> _runTcpServer(
  ServerSocket server,
  FakeAdbd device,
) async {
  await for (final socket in server) {
    device.serve(_SocketTransport(socket)).catchError((_) {});
  }
}

void main() {
  test('真实 loopback TCP：握手（CNXN/AUTH）+ shell 往返', () async {
    final server =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final key = AdbRsaKeyPair.generate();
    final device = FakeAdbd(verifyKey: key)
      ..serviceHandler = (dest) async =>
          dest == 'shell:echo tcp-ok' ? 'tcp-ok\n' : null;
    unawaited(_runTcpServer(server, device));

    final transport = await AdbTcpTransport.connect('127.0.0.1', server.port);
    final conn = AdbConnection(transport, signers: [key],
        authTimeout: const Duration(seconds: 5));
    await conn.connect();

    expect(conn.deviceBanner, 'product:model');
    expect(conn.deviceSerial, 'fake12345');
    expect(await conn.shell('echo tcp-ok'), 'tcp-ok\n');

    await conn.close();
    await device.done;
    await server.close();
  });
}