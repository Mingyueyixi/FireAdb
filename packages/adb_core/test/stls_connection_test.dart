import 'dart:async';
import 'dart:io';

import 'package:adb_core/adb_core.dart';
import 'package:test/test.dart';

void main() {
  test('无线调试：STLS 之后在 TLS 里收到 CNXN', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final hostKey = AdbRsaKeyPair.generate();
    final deviceKey = AdbRsaKeyPair.generate();
    final deviceCert = buildSelfSignedRsaCertificate(deviceKey);
    final deviceError = Completer<Object>();

    final serve = () async {
      final socket = await server.first;
      socket.setOption(SocketOption.tcpNoDelay, true);
      final reader = AdbSizedReader(socket);
      final cnxn = await readAdbMessage(reader);
      if (cnxn.command != commandCnxn) {
        throw StateError('设备应先收到 CNXN');
      }
      socket.add(AdbMessage(commandStls, stlsVersion, 0, const []).pack());
      await socket.flush();
      final reply = await readAdbMessage(reader);
      if (reply.command != commandStls || reply.arg0 != stlsVersion) {
        throw StateError('主机应回 STLS');
      }
      final tls = await tls13ServerHandshakeOnStream(
        input: reader.takeRemainingStream(),
        write: (data) async {
          socket.add(data);
          await socket.flush();
        },
        serverKey: deviceKey,
        serverCertificate: deviceCert,
      );
      tls.writeApplicationData(
        AdbMessage(
          commandCnxn,
          version,
          maxAdbData,
          encodeConnectPayload(
            type: 'device',
            serial: 'tls-serial',
            banner: 'product:model',
          ),
        ).pack(),
      );
      await tls.flush();
    }();
    serve.catchError((Object error) {
      if (!deviceError.isCompleted) deviceError.complete(error);
    });

    final conn = AdbConnection(
      await AdbTcpTransport.connect(
        InternetAddress.loopbackIPv4.address,
        server.port,
      ),
      signers: [hostKey],
      authTimeout: const Duration(seconds: 5),
    );
    final banner = await conn.connect().timeout(const Duration(seconds: 5));
    expect(banner, 'product:model');
    expect(conn.deviceSerial, 'tls-serial');
    expect(conn.state, AdbConnectionState.device);
    expect(deviceError.isCompleted, isFalse);

    await conn.close();
    await serve;
    await server.close();
  });
}
