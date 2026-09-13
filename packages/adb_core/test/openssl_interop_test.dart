import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adb_core/src/adb_auth_key.dart';
import 'package:adb_core/src/tls13.dart';
import 'package:adb_core/src/x509.dart';
import 'package:test/test.dart';

Future<bool> _opensslAvailable() async {
  try {
    final result = await Process.run('openssl', ['version']);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<int> _freePort() async {
  final listener = await ServerSocket.bind('127.0.0.1', 0);
  final port = listener.port;
  await listener.close();
  return port;
}

void main() {
  group('与 openssl s_server 的 TLS 1.3 互操作', () {
    test('完整握手（无客户端认证）+ 应用数据往返 + exporter', () async {
      if (!await _opensslAvailable()) {
        markTestSkipped('openssl not available');
      }

      final serverKey = AdbRsaKeyPair.generate();
      final serverCert = buildSelfSignedRsaCertificate(serverKey);

      final dir = await Directory.systemTemp.createTemp('adb_tls_interop_');
      final certFile = File('${dir.path}${Platform.pathSeparator}cert.pem')
        ..writeAsStringSync(serverCert.toPem());
      final keyFile = File('${dir.path}${Platform.pathSeparator}key.pem')
        ..writeAsStringSync(serverKey.toPem());
      final ngtFile = File('${dir.path}${Platform.pathSeparator}keylog.txt');

      Process? proc;
      late String keylog;
      try {
        var started = false;
        for (var attempt = 0; attempt < 5 && !started; attempt++) {
          final port = await _freePort();
          try {
            proc = await Process.start('openssl', [
              's_server',
              '-accept', '127.0.0.1:$port',
              '-cert', certFile.path,
              '-key', keyFile.path,
              '-tls1_3',
              '-no_ticket',
              '-naccept', '1',
              '-quiet',
              '-keylogfile', ngtFile.path,
            ]);
            started = true;
            await _runClient(port, proc);
          } catch (e) {
            proc?.kill();
            if (attempt == 4) rethrow;
          }
        }
        // 服务端应正常退出（-naccept 1）。
        if (proc != null) {
          await proc.exitCode.timeout(const Duration(seconds: 10));
        }
        keylog = await ngtFile.readAsString();
      } finally {
        proc?.kill();
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }

      // openssl 的 keylog 含 EXPORTER_SECRET 即证明协商为 TLS 1.3 且走正常导出。
      expect(keylog.split('\n').any((l) => l.startsWith('EXPORTER_SECRET ')),
          isTrue,
          reason: 'keylog 应包含 EXPORTER_SECRET（即 TLS 1.3）');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}

Future<void> _runClient(int port, Process proc) async {
  final stderrBuf = StringBuffer();
  proc.stderr.transform(utf8.decoder).listen(stderrBuf.write);
  proc.stdout.drain<void>();

  final socket = await Socket.connect('127.0.0.1', port);
  try {
    final conn = await tls13ClientHandshake(
      socket: socket,
      clientKey: AdbRsaKeyPair.generate(),
      clientCertificate: buildSelfSignedRsaCertificate(AdbRsaKeyPair.generate()),
    ).timeout(const Duration(seconds: 15));
    expect(conn.exporterKey.length, 64);

conn.writeApplicationData(Uint8List.fromList(utf8.encode('ping1\n')));
    proc.stdin.write('pong from openssl\n');
    await proc.stdin.flush();

    final received = BytesBuilder();
    var bytes = 0;
    while (bytes < 256) {
      final chunk =
          await conn.readApplicationData().timeout(const Duration(seconds: 10));
      bytes += chunk.length;
      received.add(chunk);
      if (utf8.decode(received.toBytes(), allowMalformed: true).contains('\n')) {
        break;
      }
    }
    expect(utf8.decode(received.toBytes()), contains('pong from openssl\n'),
        reason: 'stderr: $stderrBuf');

    conn.close();
  } on TimeoutException {
    fail('openssl 互操作超时（stderr: $stderrBuf）');
  } finally {
    socket.destroy();
  }
}