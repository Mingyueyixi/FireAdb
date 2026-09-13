import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adb_core/src/adb_auth_key.dart';
import 'package:adb_core/src/pairing_aes_gcm.dart';
import 'package:adb_core/src/pairing_connection.dart';
import 'package:adb_core/src/spake25519.dart';
import 'package:adb_core/src/tls13.dart';
import 'package:adb_core/src/x509.dart';
import 'package:test/test.dart';

/// 组装一对本端/远端 PeerInfo：client 发 RSA 公钥、server 发设备 GUID，与
/// AOSP `client/adb_wifi.cpp` 和 `pairing_server.cpp` 的行为一致。
AdbPeerInfo _rsaPubKeyPeerInfo(AdbRsaKeyPair key) {
  return AdbPeerInfo(
    type: AdbPeerInfo.typeRsaPubKey,
    data: Uint8List.fromList(
        utf8.encode('${key.base64PublicKey()} user@desktop')),
  );
}

AdbPeerInfo _guidPeerInfo(String guid) {
  return AdbPeerInfo(
    type: AdbPeerInfo.typeDeviceGuid,
    data: Uint8List.fromList(utf8.encode(guid)),
  );
}

void main() {
  group('Aes128Gcm（AOSP aes_128_gcm 布局）', () {
    test('加密 8192 字节输出 8192+16，解密还原；序号随调用递增', () {
      final material =
          Uint8List.fromList(List<int>.generate(64, (i) => i & 0xff));
      final aes = PairingAes128Gcm.fromSpakeKey(material);

      final plaintext = Uint8List(kPeerInfoSize);
      plaintext[0] = AdbPeerInfo.typeDeviceGuid;
      plaintext.setRange(1, 7, utf8.encode('guid-1'));
      for (var i = 7; i < plaintext.length; i++) {
        plaintext[i] = 0x42;
      }

      final enc1 = aes.encrypt(plaintext);
      expect(enc1.length, kPeerInfoSize + PairingAes128Gcm.tagLength);
      expect(aes.decrypt(enc1), plaintext);

      final enc2 = aes.encrypt(plaintext);
      expect(enc2, isNot(enc1), reason: '加密序号递增，两次密文不得相同');
      expect(aes.decrypt(enc2), plaintext);
    });

    test('篡改 tag 导致解密失败', () {
      final magic =
          Uint8List.fromList(List<int>.generate(64, (i) => (i * 3) & 0xff));
      final aes = PairingAes128Gcm.fromSpakeKey(magic);
      final enc = aes.encrypt(Uint8List(kPeerInfoSize));
      final tampered = Uint8List.fromList(enc);
      tampered[tampered.length - 1] ^= 0xff;
      expect(() => aes.decrypt(tampered), throwsA(anything));
    });
  });

  group('runPairing loopback（6f：TLS 1.3 + SPAKE2 + AES-GCM）', () {
    test('相同密码：双方交换 PeerInfo 成功', () async {
      final listener = await ServerSocket.bind('127.0.0.1', 0);
      final serverKey = AdbRsaKeyPair.generate();
      final serverCert = buildSelfSignedRsaCertificate(serverKey);
      final clientKey = AdbRsaKeyPair.generate();
      final clientCert = buildSelfSignedRsaCertificate(clientKey);

      final serverF = _runServer(listener, password: kPassword,
        key: serverKey, cert: serverCert);
      final clientF = _runClient(listener.port, password: kPassword,
        key: clientKey, cert: clientCert);

      // 先给双方都挂上处理器，避免任何一方先失败时报未处理异步错误。
      final waiterClient = _ok(clientF);
      final waiterServer = _ok(serverF);
      final clientResult = await waiterClient;
      final serverResult = await waiterServer;

      expect(clientResult.type, AdbPeerInfo.typeDeviceGuid);
      expect(String.fromCharCodes(clientResult.data), 'guid-0123456789abcdef');
      expect(serverResult.type, AdbPeerInfo.typeRsaPubKey);
      expect(String.fromCharCodes(serverResult.data), endsWith('user@desktop'));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('不同密码：双方均失败', () async {
      final listener = await ServerSocket.bind('127.0.0.1', 0);
      final serverKey = AdbRsaKeyPair.generate();
      final serverCert = buildSelfSignedRsaCertificate(serverKey);
      final clientKey = AdbRsaKeyPair.generate();
      final clientCert = buildSelfSignedRsaCertificate(clientKey);

      final serverF = _runServer(listener, password: '654321',
        key: serverKey, cert: serverCert);
      final clientF = _runClient(listener.port, password: kPassword,
        key: clientKey, cert: clientCert);

      final clientErrF = _error(clientF);
      final serverErrF = _error(serverF);
      final clientErr = await clientErrF;
      final serverErr = await serverErrF;
      // 密码不一致时，SPAKE2 双方派生密钥不同，PeerInfo 解密必失败（或连接中断）。
      expect(clientErr is PairingException ||
          clientErr is TlsException, isTrue, reason: 'client error = $clientErr');
      expect(serverErr is PairingException ||
          serverErr is TlsException, isTrue, reason: 'server error = $serverErr');
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}

const String kPassword = '123456';

Future<AdbPeerInfo> _runClient(
    int port, {required String password, required AdbRsaKeyPair key,
    required AdbX509Certificate cert}) async {
  final socket = await Socket.connect('127.0.0.1', port);
  try {
    return await runPairing(
      socket: socket,
      isClient: true,
      password: utf8.encode(password),
      tlsKey: key,
      tlsCertificate: cert,
      localPeerInfo: _rsaPubKeyPeerInfo(key),
    );
  } finally {
    socket.destroy();
  }
}

Future<AdbPeerInfo> _runServer(
    ServerSocket listener, {required String password,
    required AdbRsaKeyPair key, required AdbX509Certificate cert}) async {
  try {
    final socket = await listener.first.timeout(const Duration(seconds: 20));
    try {
      return await runPairing(
        socket: socket,
        isClient: false,
        password: utf8.encode(password),
        tlsKey: key,
        tlsCertificate: cert,
        localPeerInfo: _guidPeerInfo('guid-0123456789abcdef'),
      );
    } finally {
      socket.destroy();
    }
  } finally {
    listener.close();
  }
}

Future<AdbPeerInfo> _ok(Future<AdbPeerInfo> f) => f;

Future<Object?> _error(Future<AdbPeerInfo> f) async {
  try {
    final v = await f;
    return v; // 不期望成功
  } catch (e) {
    return e;
  }
}