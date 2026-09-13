import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';

import 'adb_auth_key.dart';
import 'pairing_aes_gcm.dart';
import 'spake25519.dart';
import 'tls13.dart';
import 'x509.dart';

/// AOSP 传给 `SSL_export_keying_material` 的标签（`sizeof("adb-label")` 含
/// 结尾 NUL，共 10 字节）。详见 `tls/tls_connection.cpp` `kExportedKeyLabel`。
const String kAdbExporterLabel = 'adb-label\u0000';

/// AOSP SPAKE2 名称（`sizeof(...)` 含结尾 NUL，见 pairing_auth.cpp）。
final List<int> kPairClientName = <int>[...'adb pair client'.codeUnits, 0];
final List<int> kPairServerName = <int>[...'adb pair server'.codeUnits, 0];

/// adb pairing 失败。
class PairingException implements Exception {
  final String message;
  PairingException(this.message);
  @override
  String toString() => 'PairingException: $message';
}

/// 执行一次 adb pairing 协议（6f：TLS 1.3 + SPAKE2+ + AES-128-GCM）。
///
/// 对应 AOSP `PairingConnectionCtx::StartWorker`：
/// 1. TLS 1.3 handshake（mutual，接受任意自签证书）。
/// 2. 导出 64 字节 keying material（标签 'adb-label\0'），拼接到密码后。
/// 3. 交换 SPAKE2 消息并初始化 AES-128-GCM 密码器。
/// 4. 交换加密的 PeerInfo（8192 字节），成功返回对端 `AdbPeerInfo`。
///
/// [socket] 应为已连接的 TCP socket（[isClient] 主动 connect，
/// 否则为 accept 的 socket）。失败抛 [PairingException] 或 [TlsException]。
Future<AdbPeerInfo> runPairing({
  required Socket socket,
  required bool isClient,
  required List<int> password,
  required AdbRsaKeyPair tlsKey,
  required AdbX509Certificate tlsCertificate,
  required AdbPeerInfo localPeerInfo,
}) async {
  final conn = isClient
      ? await tls13ClientHandshake(
          socket: socket,
          clientKey: tlsKey,
          clientCertificate: tlsCertificate,
          exporterLabel: kAdbExporterLabel)
      : await tls13ServerHandshake(
          socket: socket,
          serverKey: tlsKey,
          serverCertificate: tlsCertificate,
          exporterLabel: kAdbExporterLabel);

  if (conn.exporterKey.length != kExportedKeySize) {
    throw PairingException(
        'Expected $kExportedKeySize bytes of exported key material, '
        'got ${conn.exporterKey.length}');
  }

  // pswd = 用户密码 ‖ 64 字节 TLS exporter（AOSP SetupTlsConnection）。
  final pswd = <int>[...password, ...conn.exporterKey];
  if (pswd.isEmpty) throw PairingException('Empty pairing password');

  final spake = Spake25519(
    client: isClient,
    password: pswd,
    myName: isClient ? kPairClientName : kPairServerName,
    theirName: isClient ? kPairServerName : kPairClientName,
  );

  final stream = _PairingStream(conn);

  // ---- 交换 SPAKE2 消息（双方先发后收）----
  _writePacket(conn, pairingPacketSpake2Msg, spake.message);
  final theirMsg = await stream.readPacket(expectType: pairingPacketSpake2Msg);
  if (theirMsg.length != spake.message.length) {
    throw PairingException(
        'SPAKE2 message length mismatch: ${theirMsg.length} bytes');
  }

  // ---- 初始化密码器（密码不一致时 AES 解密会失败）----
  final aes = PairingAes128Gcm.fromSpakeKey(spake.processMessage(theirMsg));

  // ---- 交换 PeerInfo（加密）----
  final plaintext = localPeerInfo.toBytes();
  if (plaintext.length != kPeerInfoSize) {
    throw PairingException('PeerInfo must be $kPeerInfoSize bytes');
  }
  final encrypted = aes.encrypt(plaintext);
  _writePacket(conn, pairingPacketPeerInfo, encrypted);

  final theirEncrypted = await stream.readPacket(expectType: pairingPacketPeerInfo);
  Uint8List theirPlaintext;
  try {
    theirPlaintext = aes.decrypt(theirEncrypted);
  } on InvalidCipherTextException catch (e) {
    throw PairingException('PeerInfo decrypt failed (wrong password?): $e');
  }
  if (theirPlaintext.length != kPeerInfoSize) {
    throw PairingException(
        'Decrypted PeerInfo size ${theirPlaintext.length} != $kPeerInfoSize');
  }
  return AdbPeerInfo.fromBytes(theirPlaintext);
}

const int kExportedKeySize = 64;

/// 拼接 PairingPacketHeader + payload 为一个 application-data 记录。
void _writePacket(Tls13Connection conn, int type, List<int> payload) {
  final header = PairingPacketHeader(
          version: PairingPacketHeader.currentVersion,
          type: type,
          payloadSize: payload.length)
      .toBytes();
  conn.writeApplicationData(
      Uint8List.fromList([...header, ...payload]));
}

/// 从 TLS 应用数据流中按帧读取对手消息（处理跨记录分段）。
class _PairingStream {
  final Tls13Connection _conn;
  final List<int> _buf = [];

  _PairingStream(this._conn);

  Future<Uint8List> _readExact(int n) async {
    while (_buf.length < n) {
      final chunk = await _conn.readApplicationData();
      if (chunk.isEmpty) {
        throw PairingException('Pairing connection closed mid-frame');
      }
      _buf.addAll(chunk);
    }
    final out = Uint8List.fromList(_buf.sublist(0, n));
    _buf.removeRange(0, n);
    return out;
  }

  Future<Uint8List> readPacket({required int expectType}) async {
    final header = await _readExact(PairingPacketHeader.headerSize);
    final parsed = PairingPacketHeader.parse(header);
    if (parsed.type != expectType) {
      throw PairingException(
          'Unexpected packet type ${parsed.type}, expected $expectType');
    }
    return _readExact(parsed.payloadSize);
  }
}