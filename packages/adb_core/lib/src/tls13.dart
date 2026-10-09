import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'adb_auth_key.dart';
import 'tls_prf.dart';
import 'x25519.dart';
import 'x509.dart';

/// TLS 1.3 客户端，仅用于 adb pairing。
///
/// 参考：RFC 8446（TLS 1.3）、RFC 5705（exporter）、
/// BoringSSL `tls13_export_keying_material` 与 `do_seal_record`。
/// 仅支持 TLS_AES_128_GCM_SHA256 + X25519 + RSA-PSS-SHA256 验签。
///
/// handshake 之后返回 [Tls13Connection]，包含 exporter 与应用数据记录读写。
class Tls13Connection {
  final _SocketTransport _transport;
  final Uint8List _exporterKey;
  final Uint8List _readKey;
  final Uint8List _readIv;
  final Uint8List _writeKey;
  final Uint8List _writeIv;
  int _readSeq = 0;
  int _writeSeq = 0;

  Tls13Connection._({
    required this._transport,
    required this._exporterKey,
    required this._readKey,
    required this._readIv,
    required this._writeKey,
    required this._writeIv,
  });

  /// handshake 后导出的密钥材料（BoringSSL use_context=false，64 字节）。
  Uint8List get exporterKey => Uint8List.fromList(_exporterKey);

  /// 读取一个 application-data 记录（返回明文 payload）。
  ///
  /// 自动跳过握手完成后的 post-handshake 消息（如 server 的 NewSessionTicket），
  /// 直到收到真正的 application data。
  Future<Uint8List> readApplicationData() async {
    while (true) {
      final record = await _transport.readRecord();
      if (record.length < 5) {
        throw TlsException('TLS record truncated');
      }
      final outerType = record[0];
      if (outerType == 0x14) {
        // 理论握手后不会再有 CCS；安全起见跳过。
        continue;
      }
      final decrypted = openRecord(
        key: _readKey,
        iv: _readIv,
        seqNum: _readSeq,
        record: record,
      );
      _readSeq++;
      switch (decrypted.innerType) {
        case 0x15: // alert
          throw _alertException(decrypted.payload);
        case 0x16: // handshake（post-handshake，例如 NewSessionTicket）
          final buffer = _HandshakeBuffer()..add(decrypted.payload);
          while (buffer.hasCompleteMessage) {
            final msg = buffer.takeMessage();
            if (msg.header == 0x15) {
              throw TlsException('Alert sent inside handshake message');
            }
            // 忽略 NewSessionTicket/KeyUpdate 等。
          }
          continue;
        case 0x17:
          return decrypted.payload;
        default:
          throw TlsException(
            'Unexpected inner record type 0x${decrypted.innerType.toRadixString(16)}',
          );
      }
    }
  }

  /// 发送一个 application-data 记录。
  void writeApplicationData(Uint8List payload) {
    final record = sealRecord(
      key: _writeKey,
      iv: _writeIv,
      seqNum: _writeSeq,
      innerType: 0x17,
      payload: payload,
    );
    _writeSeq++;
    _transport.write(record);
  }

  /// 把已经交给传输层的记录真正写出去。
  Future<void> flush() => _transport.flush();

  /// 解密后的应用数据。一条 ADB 消息可能跨多个 TLS 记录。
  Stream<Uint8List> plaintextStream() async* {
    while (true) {
      yield await readApplicationData();
    }
  }

  void close() => _transport.close();
}

class TlsException implements Exception {
  final String message;
  TlsException(this.message);
  @override
  String toString() => 'TlsException: $message';
}

TlsException _alertException(List<int> payload) {
  final code = payload.length >= 2 ? payload[1] : -1;
  return TlsException(
    'Server sent alert (level=${payload.isNotEmpty ? payload[0] : -1}, '
    'description=$code)',
  );
}

/// 执行 TLS 1.3 handshake（客户端）。成功返回 [Tls13Connection]，失败抛 [TlsException]。
///
/// [exporterLabel] 默认 'adb-label'（不含 NUL）；adb pairing 需要
/// 'adb-label\0'（AOSP 用 sizeof 含结尾 NUL 传给 BoringSSL）。
Future<Tls13Connection> tls13ClientHandshake({
  required Socket socket,
  required AdbRsaKeyPair clientKey,
  required AdbX509Certificate clientCertificate,
  String exporterLabel = 'adb-label',
}) {
  return _tls13ClientHandshake(
    _SocketTransport(socket),
    clientKey: clientKey,
    clientCertificate: clientCertificate,
    exporterLabel: exporterLabel,
  );
}

/// 在已经取出的字节流上做 TLS 1.3 客户端握手。
///
/// 无线调试的 `STLS` 之后，ADB 帧结束，后续字节是 TLS 记录。读循环已经
/// 占着原来的 socket，不能再订阅一次，所以从剩余字节流继续。
Future<Tls13Connection> tls13ClientHandshakeOnStream({
  required Stream<List<int>> input,
  required Future<void> Function(List<int> data) write,
  required AdbRsaKeyPair clientKey,
  required AdbX509Certificate clientCertificate,
  String exporterLabel = 'adb-label',
}) {
  return _tls13ClientHandshake(
    _SocketTransport.stream(input: input, write: write),
    clientKey: clientKey,
    clientCertificate: clientCertificate,
    exporterLabel: exporterLabel,
  );
}

Future<Tls13Connection> _tls13ClientHandshake(
  _SocketTransport transport, {
  required AdbRsaKeyPair clientKey,
  required AdbX509Certificate clientCertificate,
  String exporterLabel = 'adb-label',
}) async {
  // ---- 1. ClientHello ----
  final clientRandom = randomBytes(32);
  final ecdhe = X25519KeyPair.generate();

  final ch = _buildClientHello(clientRandom, ecdhe.publicKey);
  // ClientHello 以明文 handshake record 发送（outer type 0x16）。
  final chRecord = Uint8List(5 + ch.length);
  chRecord[0] = 0x16;
  chRecord[1] = 0x03;
  chRecord[2] = 0x01;
  chRecord[3] = (ch.length >> 8) & 0xff;
  chRecord[4] = ch.length & 0xff;
  chRecord.setAll(5, ch);
  transport.write(chRecord);
  await transport.flush();

  final transcript = BytesBuilder()..add(ch);

  // ---- 2. ServerHello（明文记录） ----
  final sh = await transport.readPlainHandshakeRecord();
  if (sh.isEmpty || sh[0] != kHandshakeServerHello) {
    throw TlsException('Expected ServerHello');
  }
  transcript.add(sh);
  final shBody = _handshakeBody(sh);
  final serverEcdhePublic = _parseServerHelloKeyShare(shBody);

  final dhe = x25519(serverEcdhePublic, ecdhe.privateKey);

  // ---- 3. 密钥调度（RFC 8446 §7.1），生成 handshake traffic ----
  final zero = Uint8List(kHashLen);
  final earlySecret = hkdfExtract(salt: zero, ikm: zero);
  final derived = hkdfExpandLabel(
    prk: earlySecret,
    label: 'derived',
    context: sha256(const []),
    length: kHashLen,
  );
  final handshakeSecret = hkdfExtract(salt: derived, ikm: dhe);

  final transcriptUpToSh = transcript.toBytes();
  final clientHsTraffic = deriveSecret(
    secret: handshakeSecret,
    label: 'c hs traffic',
    messages: transcriptUpToSh,
  );
  final serverHsTraffic = deriveSecret(
    secret: handshakeSecret,
    label: 's hs traffic',
    messages: transcriptUpToSh,
  );

  var readKey = deriveTrafficKey(serverHsTraffic);
  var readIv = deriveTrafficIv(serverHsTraffic);
  var readSeq = 0;
  var writeKey = deriveTrafficKey(clientHsTraffic);
  var writeIv = deriveTrafficIv(clientHsTraffic);
  var writeSeq = 0;

  // ---- 4. 读取服务端密文 flight，直到 Server Finished ----
  RsaPublicKey? serverPublicKey;
  final handshake = _HandshakeBuffer();
  var serverFinished = false;
  var serverRequestedCertificate = false;

  while (!serverFinished) {
    final record = await transport.readRecord();
    if (record.isEmpty) {
      throw TlsException('Connection closed during TLS handshake');
    }
    final outerType = record[0];
    if (outerType == 0x14) {
      // middlebox 兼容的 dummy ChangeCipherSpec
      continue;
    }
    if (outerType != 0x17) {
      throw TlsException(
        'Unexpected record type 0x${outerType.toRadixString(16)} during handshake',
      );
    }
    final decrypted = openRecord(
      key: readKey,
      iv: readIv,
      seqNum: readSeq,
      record: record,
    );
    readSeq++;
    if (decrypted.innerType != 0x16) {
      throw TlsException(
        'Server handshake data expected, got inner type '
        '0x${decrypted.innerType.toRadixString(16)}',
      );
    }
    handshake.add(decrypted.payload);

    while (handshake.hasCompleteMessage) {
      final msg = handshake.takeMessage();
      switch (msg.header) {
        case kHandshakeEncryptedExtensions:
          transcript.add(msg.raw);
          break;
        case kHandshakeCertificateRequest:
          transcript.add(msg.raw);
          serverRequestedCertificate = true;
          break;
        case kHandshakeCertificate:
          transcript.add(msg.raw);
          final certs = _parseServerCertificateMessage(msg.body);
          serverPublicKey = ParsedX509Certificate.parse(certs.first).publicKey;
          break;
        case kHandshakeCertificateVerify:
          _verifyServerCertificateVerify(
            msg.body,
            serverPublicKey,
            transcript.toBytes(),
          );
          transcript.add(msg.raw);
          break;
        case kHandshakeFinished:
          final transcriptHash = sha256(transcript.toBytes());
          final expected = finishedMac(
            trafficSecret: serverHsTraffic,
            transcriptHash: transcriptHash,
          );
          if (!_equalBytes(expected, msg.body)) {
            throw TlsException('Server Finished verify_data mismatch');
          }
          transcript.add(msg.raw);
          serverFinished = true;
          break;
        default:
          throw TlsException('Unexpected handshake message type ${msg.header}');
      }
    }
  }

  // ---- 5. master + application traffic + exporter secret（transcript 截至 server Finished） ----
  final transcriptUpToServerFinished = transcript.toBytes();
  final masterDerived = hkdfExpandLabel(
    prk: handshakeSecret,
    label: 'derived',
    context: sha256(const []),
    length: kHashLen,
  );
  final masterSecret = hkdfExtract(salt: masterDerived, ikm: zero);
  final clientApTraffic = deriveSecret(
    secret: masterSecret,
    label: 'c ap traffic',
    messages: transcriptUpToServerFinished,
  );
  final serverApTraffic = deriveSecret(
    secret: masterSecret,
    label: 's ap traffic',
    messages: transcriptUpToServerFinished,
  );
  final exporterSecret = deriveSecret(
    secret: masterSecret,
    label: 'exp master',
    messages: transcriptUpToServerFinished,
  );

  // 读密钥切换到 application traffic（序号归零）。
  readKey = deriveTrafficKey(serverApTraffic);
  readIv = deriveTrafficIv(serverApTraffic);
  readSeq = 0;

  // ---- 6. 发送客户端 flight。服务端发了 CertificateRequest 才发
  //        Certificate + CertificateVerify，否则只发 Finished（RFC 8446 §4.4.2）。
  //        仍使用 client handshake traffic 加密。 ----
  final clientFlightParts = <Uint8List>[];
  if (serverRequestedCertificate) {
    final certMsg = _buildClientCertificateMessage(clientCertificate);
    transcript.add(certMsg);
    clientFlightParts.add(certMsg);

    final verifyMsg = _buildClientCertificateVerify(
      clientKey,
      transcript.toBytes(),
    );
    transcript.add(verifyMsg);
    clientFlightParts.add(verifyMsg);
  }

  final finishedHash = sha256(transcript.toBytes());
  final clientFinished = finishedMac(
    trafficSecret: clientHsTraffic,
    transcriptHash: finishedHash,
  );
  final finishedMsg = _wrapHandshake(kHandshakeFinished, clientFinished);
  transcript.add(finishedMsg);
  clientFlightParts.add(finishedMsg);

  final clientFlight = Uint8List.fromList(
    clientFlightParts.expand((p) => p).toList(),
  );
  final flightRecord = sealRecord(
    key: writeKey,
    iv: writeIv,
    seqNum: writeSeq,
    innerType: kHandshakeInnerType,
    payload: clientFlight,
  );
  writeSeq++;
  transport.write(flightRecord);
  await transport.flush();

  // 写密钥切换到 application traffic（序号归零）。
  writeKey = deriveTrafficKey(clientApTraffic);
  writeIv = deriveTrafficIv(clientApTraffic);
  writeSeq = 0;

  // ---- 7. exporter（BoringSSL SSL_export_keying_material, use_context=false） ----
  final exporter = computeTls13Exporter(
    exporterSecret: exporterSecret,
    label: exporterLabel,
    length: 64,
  );

  return Tls13Connection._(
    transport: transport,
    exporterKey: exporter,
    readKey: readKey,
    readIv: readIv,
    writeKey: writeKey,
    writeIv: writeIv,
  );
}

/// 执行 TLS 1.3 handshake（服务端，镜像 [tls13ClientHandshake]）。
///
/// 与 adb pairing 的设备端一致：强制 TLS 1.3 + X25519 +
/// TLS_AES_128_GCM_SHA256；发送 CertificateRequest 请求客户端证书
/// （mutual TLS）；接受任意自签证书（AOSP SetCertVerifyCallback 恒为 1）。
Future<Tls13Connection> tls13ServerHandshake({
  required Socket socket,
  required AdbRsaKeyPair serverKey,
  required AdbX509Certificate serverCertificate,
  String exporterLabel = 'adb-label',
}) {
  return _tls13ServerHandshake(
    _SocketTransport(socket),
    serverKey: serverKey,
    serverCertificate: serverCertificate,
    exporterLabel: exporterLabel,
  );
}

/// 在已经取出的字节流上做 TLS 1.3 服务端握手。
///
/// 无线调试测试里，设备先用 ADB 帧读完 `STLS`，后续字节才是 TLS 记录。
Future<Tls13Connection> tls13ServerHandshakeOnStream({
  required Stream<List<int>> input,
  required Future<void> Function(List<int> data) write,
  required AdbRsaKeyPair serverKey,
  required AdbX509Certificate serverCertificate,
  String exporterLabel = 'adb-label',
}) {
  return _tls13ServerHandshake(
    _SocketTransport.stream(input: input, write: write),
    serverKey: serverKey,
    serverCertificate: serverCertificate,
    exporterLabel: exporterLabel,
  );
}

Future<Tls13Connection> _tls13ServerHandshake(
  _SocketTransport transport, {
  required AdbRsaKeyPair serverKey,
  required AdbX509Certificate serverCertificate,
  String exporterLabel = 'adb-label',
}) async {
  // ---- 1. 读取 ClientHello（明文记录） ----
  final chRaw = await transport.readPlainHandshakeRecord();
  if (chRaw.isEmpty || chRaw[0] != kHandshakeClientHello) {
    throw TlsException('Expected ClientHello');
  }
  final clientEcdhePublic = _parseClientHelloKeyShare(_handshakeBody(chRaw));
  final transcript = BytesBuilder()..add(chRaw);

  // ---- 2. 生成 ServerHello（明文记录） ----
  final serverEcdhe = X25519KeyPair.generate();
  final dhe = x25519(clientEcdhePublic, serverEcdhe.privateKey);

  final sh = _buildServerHello(serverEcdhe.publicKey);
  final shRecord = Uint8List(5 + sh.length);
  shRecord[0] = 0x16;
  shRecord[1] = 0x03;
  shRecord[2] = 0x01;
  shRecord[3] = (sh.length >> 8) & 0xff;
  shRecord[4] = sh.length & 0xff;
  shRecord.setAll(5, sh);
  transport.write(shRecord);
  await transport.flush();
  transcript.add(sh);

  // ---- 3. 密钥调度（RFC 8446 §7.1） ----
  final zero = Uint8List(kHashLen);
  final earlySecret = hkdfExtract(salt: zero, ikm: zero);
  final derived = hkdfExpandLabel(
    prk: earlySecret,
    label: 'derived',
    context: sha256(const []),
    length: kHashLen,
  );
  final handshakeSecret = hkdfExtract(salt: derived, ikm: dhe);

  final transcriptUpToSh = transcript.toBytes();
  final clientHsTraffic = deriveSecret(
    secret: handshakeSecret,
    label: 'c hs traffic',
    messages: transcriptUpToSh,
  );
  final serverHsTraffic = deriveSecret(
    secret: handshakeSecret,
    label: 's hs traffic',
    messages: transcriptUpToSh,
  );

  var readKey = deriveTrafficKey(clientHsTraffic);
  var readIv = deriveTrafficIv(clientHsTraffic);
  var readSeq = 0;
  var writeKey = deriveTrafficKey(serverHsTraffic);
  var writeIv = deriveTrafficIv(serverHsTraffic);
  var writeSeq = 0;

  // ---- 4. 服务端 flight（EncryptedExtensions + CertificateRequest +
  //        Certificate + CertificateVerify + Finished），用 s hs traffic 加密 ----
  final parts = <Uint8List>[];
  final ee = _wrapHandshake(kHandshakeEncryptedExtensions, Uint8List(0));
  transcript.add(ee);
  parts.add(ee);

  final cr = _buildServerCertificateRequest();
  transcript.add(cr);
  parts.add(cr);

  final certMsg = _buildServerCertificateMessage(serverCertificate);
  transcript.add(certMsg);
  parts.add(certMsg);

  final verifyMsg = _buildServerCertificateVerify(
    serverKey,
    transcript.toBytes(),
  );
  transcript.add(verifyMsg);
  parts.add(verifyMsg);

  final serverFinished = finishedMac(
    trafficSecret: serverHsTraffic,
    transcriptHash: sha256(transcript.toBytes()),
  );
  final finishedMsg = _wrapHandshake(kHandshakeFinished, serverFinished);
  transcript.add(finishedMsg);
  parts.add(finishedMsg);

  final flight = Uint8List.fromList(parts.expand((p) => p).toList());
  final flightRecord = sealRecord(
    key: writeKey,
    iv: writeIv,
    seqNum: writeSeq,
    innerType: kHandshakeInnerType,
    payload: flight,
  );
  writeSeq++;
  transport.write(flightRecord);
  await transport.flush();

  // ---- 5. master + application traffic + exporter secret ----
  final transcriptUpToServerFinished = transcript.toBytes();
  final masterDerived = hkdfExpandLabel(
    prk: handshakeSecret,
    label: 'derived',
    context: sha256(const []),
    length: kHashLen,
  );
  final masterSecret = hkdfExtract(salt: masterDerived, ikm: zero);
  final clientApTraffic = deriveSecret(
    secret: masterSecret,
    label: 'c ap traffic',
    messages: transcriptUpToServerFinished,
  );
  final serverApTraffic = deriveSecret(
    secret: masterSecret,
    label: 's ap traffic',
    messages: transcriptUpToServerFinished,
  );
  final exporterSecret = deriveSecret(
    secret: masterSecret,
    label: 'exp master',
    messages: transcriptUpToServerFinished,
  );

  // 写密钥切换到 application traffic（序号归零）。
  writeKey = deriveTrafficKey(serverApTraffic);
  writeIv = deriveTrafficIv(serverApTraffic);
  writeSeq = 0;

  // ---- 6. 读取客户端 flight（Certificate + CertificateVerify + Finished）----
  var clientFinished = false;
  RsaPublicKey? clientPublicKey;
  final handshake = _HandshakeBuffer();
  while (!clientFinished) {
    final record = await transport.readRecord();
    if (record.isEmpty) {
      throw TlsException('Connection closed during TLS handshake');
    }
    final outerType = record[0];
    if (outerType == 0x14) {
      continue; // 兼容中间件插入的 ChangeCipherSpec（TLS 1.3 中无意义）
    }
    if (outerType != 0x17) {
      throw TlsException(
        'Unexpected record type 0x${outerType.toRadixString(16)} during handshake',
      );
    }
    final decrypted = openRecord(
      key: readKey,
      iv: readIv,
      seqNum: readSeq,
      record: record,
    );
    readSeq++;
    if (decrypted.innerType != 0x16) {
      throw TlsException(
        'Client handshake data expected, got inner type '
        '0x${decrypted.innerType.toRadixString(16)}',
      );
    }
    handshake.add(decrypted.payload);

    while (handshake.hasCompleteMessage) {
      final msg = handshake.takeMessage();
      switch (msg.header) {
        case kHandshakeCertificate:
          transcript.add(msg.raw);
          final certs = _parseServerCertificateMessage(msg.body);
          clientPublicKey = ParsedX509Certificate.parse(certs.first).publicKey;
          break;
        case kHandshakeCertificateVerify:
          _verifyClientCertificateVerify(
            msg.body,
            clientPublicKey,
            transcript.toBytes(),
          );
          transcript.add(msg.raw);
          break;
        case kHandshakeFinished:
          final expected = finishedMac(
            trafficSecret: clientHsTraffic,
            transcriptHash: sha256(transcript.toBytes()),
          );
          if (!_equalBytes(expected, msg.body)) {
            throw TlsException('Client Finished verify_data mismatch');
          }
          transcript.add(msg.raw);
          clientFinished = true;
          break;
        default:
          throw TlsException(
            'Unexpected client handshake message type ${msg.header}',
          );
      }
    }
  }

  // 读密钥切换到 application traffic（序号归零）。
  readKey = deriveTrafficKey(clientApTraffic);
  readIv = deriveTrafficIv(clientApTraffic);
  readSeq = 0;

  final exporter = computeTls13Exporter(
    exporterSecret: exporterSecret,
    label: exporterLabel,
    length: 64,
  );

  return Tls13Connection._(
    transport: transport,
    exporterKey: exporter,
    readKey: readKey,
    readIv: readIv,
    writeKey: writeKey,
    writeIv: writeIv,
  );
}

// ---- Handshake 常数 ----

const int kHandshakeClientHello = 1;
const int kHandshakeServerHello = 2;
const int kHandshakeNewSessionTicket = 4;
const int kHandshakeEncryptedExtensions = 8;
const int kHandshakeCertificate = 11;
const int kHandshakeCertificateRequest = 13;
const int kHandshakeCertificateVerify = 15;
const int kHandshakeFinished = 20;

const int kHandshakeInnerType = 0x16; // handshake record (内部类型)
const int kApplicationDataInnerType = 0x17;

const int kTls13Version = 0x0304;
const int kExtensionSupportedVersions = 0x002b;
const int kExtensionSignatureAlgorithms = 0x000d;
const int kExtensionSupportedGroups = 0x000a;
const int kExtensionKeyShare = 0x0033;
const int kGroupX25519 = 0x001d;
const int kSignatureRsaPssRsaeSha256 = 0x0804;
const int kCipherSuiteAes128GcmSha256 = 0x1301;

Uint8List randomBytes(int length) {
  final rng = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => rng.nextInt(256)),
  );
}

// ---- ClientHello 构造 ----

Uint8List _buildClientHello(Uint8List randomValue, Uint8List ecdhePublicKey) {
  final extBuilder = BytesBuilder();

  void addExtension(int type, List<int> data) {
    extBuilder.add(_u16(type));
    extBuilder.add(_u16(data.length));
    extBuilder.add(data);
  }

  // supported_versions（<2..254>：u8 count + 0x0304）
  addExtension(kExtensionSupportedVersions, [0x02, 0x03, 0x04]);

  // signature_algorithms（SignatureScheme<2..2^16-2>）
  addExtension(kExtensionSignatureAlgorithms, [..._u16(2), 0x08, 0x04]);

  // supported_groups（NamedGroup）
  addExtension(kExtensionSupportedGroups, [..._u16(2), 0x00, 0x1d]);

  // key_share（KeyShareClientHello：u16 client_shares 长度 + 条目）
  final share = <int>[..._u16(kGroupX25519), ..._u16(32), ...ecdhePublicKey];
  addExtension(kExtensionKeyShare, [..._u16(share.length), ...share]);

  final body = BytesBuilder()
    ..add(_u16(0x0303)) // legacy_version
    ..add(randomValue)
    ..addByte(0) // legacy_session_id = 空
    ..add(_u16(2))
    ..add(_u16(kCipherSuiteAes128GcmSha256))
    ..addByte(1)
    ..addByte(0); // compression: 仅 null

  final extBytes = extBuilder.toBytes();
  body.add(_u16(extBytes.length));
  body.add(extBytes);

  return _wrapHandshake(kHandshakeClientHello, body.toBytes());
}

// ---- 服务端消息解析 ----

/// 从 ServerHello body 的 key_share 扩展提取 X25519 公钥。
Uint8List _parseServerHelloKeyShare(Uint8List body) {
  var offset = 0;
  offset += 2 + 32; // legacy_version + random
  final sidLen = _require(body, offset++);
  offset += sidLen;
  offset += 2; // cipher_suite
  offset += 1; // legacy_compression_method
  final extTotal = _u16At(body, offset);
  offset += 2;
  final extEnd = offset + extTotal;
  while (offset < extEnd) {
    final extType = _u16At(body, offset);
    final extLen = _u16At(body, offset + 2);
    final dataStart = offset + 4;
    if (extType == kExtensionKeyShare) {
      if (extLen < 4) throw TlsException('key_share too short');
      final group = _u16At(body, dataStart);
      if (group != kGroupX25519) {
        throw TlsException('Unsupported key share group $group');
      }
      final keyLen = _u16At(body, dataStart + 2);
      if (keyLen != 32)
        throw TlsException('Unexpected X25519 key length $keyLen');
      return Uint8List.sublistView(body, dataStart + 4, dataStart + 4 + keyLen);
    }
    offset = dataStart + extLen;
  }
  throw TlsException('ServerHello lacked key_share extension');
}

/// 解析服务端 Certificate 消息，返回证书 DER 列表（首个为 leaf）。
List<Uint8List> _parseServerCertificateMessage(Uint8List body) {
  var offset = 0;
  final ctxLen = _require(body, offset);
  offset += 1 + ctxLen;
  final listLen =
      body[offset] << 16 | (body[offset + 1] << 8) | body[offset + 2];
  offset += 3;
  final listEnd = offset + listLen;
  if (listEnd > body.length)
    throw TlsException('Certificate list exceeds message');

  final certs = <Uint8List>[];
  while (offset < listEnd) {
    final certLen =
        body[offset] << 16 | (body[offset + 1] << 8) | body[offset + 2];
    offset += 3;
    if (offset + certLen + 2 > body.length) {
      throw TlsException('Certificate entry exceeds message');
    }
    certs.add(Uint8List.sublistView(body, offset, offset + certLen));
    offset += certLen;
    final extLen = _u16At(body, offset);
    offset += 2 + extLen;
  }
  if (certs.isEmpty) throw TlsException('Server certificate list empty');
  return certs;
}

/// 验签服务端 CertificateVerify（rsa_pss_rsae_sha256）。
void _verifyServerCertificateVerify(
  Uint8List body,
  RsaPublicKey? pub,
  Uint8List transcript,
) {
  if (pub == null)
    throw TlsException('CertificateVerify before any certificate');
  if (body.length < 4) throw TlsException('CertificateVerify too short');
  final scheme = _u16At(body, 0);
  if (scheme != kSignatureRsaPssRsaeSha256) {
    throw TlsException(
      'Unsupported signature scheme 0x${scheme.toRadixString(16)}',
    );
  }
  final sigLen = _u16At(body, 2);
  if (body.length != 4 + sigLen) {
    throw TlsException('CertificateVerify signature length mismatch');
  }
  final signature = Uint8List.sublistView(body, 4, 4 + sigLen);
  final signedContent = _signedContent('server', sha256(transcript));
  if (!rsaPssSha256Verify(pub, signedContent, signature)) {
    throw TlsException('Server CertificateVerify signature invalid');
  }
}

// ---- 客户端消息构造 ----

/// 客户端 Certificate 消息（整个 handshake 消息，含 header）。
Uint8List _buildClientCertificateMessage(AdbX509Certificate clientCertificate) {
  final cert = clientCertificate.der;
  // CertificateEntry := cert_data<1..2^24-1> + extensions<0..2^16-1>
  // certificate_list 为该 entry 的序列（此处仅一个），长度须含长度字段。
  final listLen = cert.length + 3 + 2;
  final body = BytesBuilder()
    ..addByte(0) // cert_request_context: 空
    ..addByte((listLen >> 16) & 0xff)
    ..addByte((listLen >> 8) & 0xff)
    ..addByte(listLen & 0xff) // certificate_list 长度
    ..addByte((cert.length >> 16) & 0xff)
    ..addByte((cert.length >> 8) & 0xff)
    ..addByte(cert.length & 0xff) // entry: cert_data 长度
    ..add(cert)
    ..add(_u16(0)); // CertificateEntry.extensions：空
  return _wrapHandshake(kHandshakeCertificate, body.toBytes());
}

/// 客户端 CertificateVerify 消息。[transcript] 为截至（含）Certificate 的级联。
Uint8List _buildClientCertificateVerify(
  AdbRsaKeyPair clientKey,
  Uint8List transcript,
) {
  final signature = rsaPssSha256Sign(
    clientKey,
    _signedContent('client', sha256(transcript)),
  );
  final body = <int>[
    ..._u16(kSignatureRsaPssRsaeSha256),
    ..._u16(signature.length),
    ...signature,
  ];
  return _wrapHandshake(kHandshakeCertificateVerify, Uint8List.fromList(body));
}

/// CertificateVerify 的签名内容（RFC 8446 §4.4.3）。
Uint8List _signedContent(String role, Uint8List transcriptHash) {
  final contextPart = Uint8List.fromList(
    'TLS 1.3, $role CertificateVerify'.codeUnits,
  );
  final out = Uint8List(64 + contextPart.length + 1 + transcriptHash.length);
  out.fillRange(0, 64, 0x20);
  out.setRange(64, 64 + contextPart.length, contextPart);
  out[64 + contextPart.length] = 0x00;
  out.setRange(64 + contextPart.length + 1, out.length, transcriptHash);
  return out;
}

// ---- 服务端握手辅助 ----

/// 从 ClientHello 的 key_share 扩展提取客户端 X25519 公钥。
Uint8List _parseClientHelloKeyShare(Uint8List body) {
  var offset = 0;
  offset += 2 + 32; // legacy_version + random
  final sidLen = _require(body, offset++);
  offset += sidLen;
  final csLen = _u16At(body, offset);
  offset += 2 + csLen;
  final compLen = _require(body, offset++);
  offset += compLen;
  var extTotal = _u16At(body, offset);
  offset += 2;
  final extEnd = offset + extTotal;
  if (extEnd > body.length)
    throw TlsException('ClientHello extensions overflow');

  while (offset < extEnd) {
    final extType = _u16At(body, offset);
    final extLen = _u16At(body, offset + 2);
    final dataStart = offset + 4;
    if (extType == kExtensionKeyShare) {
      // client_shares<0..2^16-1>：先跳过向量长度
      final sharesLen = _u16At(body, dataStart);
      var p = dataStart + 2;
      final sharesEnd = p + sharesLen;
      if (sharesEnd > extEnd) throw TlsException('key_share too short');
      while (p < sharesEnd) {
        final group = _u16At(body, p);
        final keyLen = _u16At(body, p + 2);
        if (group == kGroupX25519 && keyLen == 32) {
          return Uint8List.sublistView(body, p + 4, p + 4 + keyLen);
        }
        p += 4 + keyLen;
      }
      throw TlsException('ClientHello key_share lacked X25519');
    }
    offset = dataStart + extLen;
  }
  throw TlsException('ClientHello lacked key_share extension');
}

/// 构造 ServerHello（含 supported_versions + key_share）。
Uint8List _buildServerHello(Uint8List serverEcdhePublic) {
  final body = BytesBuilder()
    ..add(_u16(0x0303)) // legacy_version
    ..add(randomBytes(32))
    ..addByte(0) // legacy_session_id = 空
    ..add(_u16(kCipherSuiteAes128GcmSha256))
    ..addByte(0); // compression: null

  final extBuilder = BytesBuilder();
  void addExtension(int type, List<int> data) {
    extBuilder.add(_u16(type));
    extBuilder.add(_u16(data.length));
    extBuilder.add(data);
  }

  addExtension(kExtensionSupportedVersions, [0x03, 0x04]);

  // KeyShareServerHello：server_share {group, keylen, key}
  final share = <int>[..._u16(kGroupX25519), ..._u16(32), ...serverEcdhePublic];
  addExtension(kExtensionKeyShare, share);

  final extBytes = extBuilder.toBytes();
  body.add(_u16(extBytes.length));
  body.add(extBytes);
  return _wrapHandshake(kHandshakeServerHello, body.toBytes());
}

/// 构造 CertificateRequest（cert_request_context 空 + sig_algs rsa_pss_rsae_sha256）。
Uint8List _buildServerCertificateRequest() {
  final extBuilder = BytesBuilder();
  // signature_algorithms（SignatureScheme<2..2^16-2>）
  final sigAlgsData = <int>[
    ..._u16(2),
    (kSignatureRsaPssRsaeSha256 >> 8) & 0xff,
    kSignatureRsaPssRsaeSha256 & 0xff,
  ];
  extBuilder.add(_u16(kExtensionSignatureAlgorithms));
  extBuilder.add(_u16(sigAlgsData.length));
  extBuilder.add(sigAlgsData);

  final body = BytesBuilder()
    ..addByte(0) // certificate_request_context：空
    ..add(_u16(extBuilder.length));
  body.add(extBuilder.toBytes());
  return _wrapHandshake(kHandshakeCertificateRequest, body.toBytes());
}

/// 服务端 Certificate 消息（结构同客户端）。
Uint8List _buildServerCertificateMessage(AdbX509Certificate certificate) {
  final cert = certificate.der;
  final listLen = cert.length + 3 + 2;
  final body = BytesBuilder()
    ..addByte(0) // cert_request_context
    ..addByte((listLen >> 16) & 0xff)
    ..addByte((listLen >> 8) & 0xff)
    ..addByte(listLen & 0xff)
    ..addByte((cert.length >> 16) & 0xff)
    ..addByte((cert.length >> 8) & 0xff)
    ..addByte(cert.length & 0xff)
    ..add(cert)
    ..add(_u16(0));
  return _wrapHandshake(kHandshakeCertificate, body.toBytes());
}

/// 服务端 CertificateVerify（rsa_pss_rsae_sha256，签名内容 hash('server', ...)）。
Uint8List _buildServerCertificateVerify(
  AdbRsaKeyPair serverKey,
  Uint8List transcript,
) {
  final signature = rsaPssSha256Sign(
    serverKey,
    _signedContent('server', sha256(transcript)),
  );
  final body = <int>[
    ..._u16(kSignatureRsaPssRsaeSha256),
    ..._u16(signature.length),
    ...signature,
  ];
  return _wrapHandshake(kHandshakeCertificateVerify, Uint8List.fromList(body));
}

/// 验签客户端 CertificateVerify（rsa_pss_rsae_sha256）。
void _verifyClientCertificateVerify(
  Uint8List body,
  RsaPublicKey? pub,
  Uint8List transcript,
) {
  if (pub == null)
    throw TlsException('CertificateVerify before any certificate');
  if (body.length < 4) throw TlsException('CertificateVerify too short');
  final scheme = _u16At(body, 0);
  if (scheme != kSignatureRsaPssRsaeSha256) {
    throw TlsException(
      'Unsupported signature scheme 0x${scheme.toRadixString(16)}',
    );
  }
  final sigLen = _u16At(body, 2);
  if (body.length != 4 + sigLen) {
    throw TlsException('CertificateVerify signature length mismatch');
  }
  final signature = Uint8List.sublistView(body, 4, 4 + sigLen);
  final signedContent = _signedContent('client', sha256(transcript));
  if (!rsaPssSha256Verify(pub, signedContent, signature)) {
    throw TlsException('Client CertificateVerify signature invalid');
  }
}

/// 计算 TLS 1.3 exporter（与 BoringSSL use_context=false 一致）。
///
/// ```
/// hash            = SHA-256(context)
/// export_context  = SHA-256("")
/// derived         = HKDF-Expand-Label(exporter_secret, label, export_context, 32)
/// out             = HKDF-Expand-Label(derived, "exporter", hash, length)
/// ```
Uint8List computeTls13Exporter({
  required Uint8List exporterSecret,
  required String label,
  required int length,
  List<int> context = const [],
}) {
  final digest = sha256(context);
  final emptyDigest = sha256(const []);
  final derived = hkdfExpandLabel(
    prk: exporterSecret,
    label: label,
    context: emptyDigest,
    length: kHashLen,
  );
  return hkdfExpandLabel(
    prk: derived,
    label: 'exporter',
    context: digest,
    length: length,
  );
}

// ---- 传输层 ----

/// 简单的按字节读取 socket（带缓冲）。
class _SocketTransport {
  final StreamIterator<List<int>> _iterator;
  final List<int> _readBuffer = [];
  final void Function(Uint8List data)? _writeSync;
  final Future<void> Function(List<int> data)? _writeAsync;
  final Future<void> Function() _flush;
  final void Function() _close;
  Future<void> _pending = Future<void>.value();

  static Future<void> _noopFlush() async {}

  static void _noopClose() {}

  _SocketTransport(Socket socket)
    : _iterator = StreamIterator(socket),
      _writeSync = socket.add,
      _writeAsync = null,
      _flush = socket.flush,
      _close = socket.close;

  _SocketTransport.stream({
    required Stream<List<int>> input,
    required Future<void> Function(List<int> data) write,
  }) : _iterator = StreamIterator(input),
       _writeSync = null,
       _writeAsync = write,
       _flush = _noopFlush,
       _close = _noopClose;

  Future<List<int>> _readChunk() async {
    if (await _iterator.moveNext()) {
      return _iterator.current;
    }
    throw TlsException('TLS connection closed prematurely');
  }

  Future<Uint8List> readExact(int n) async {
    while (_readBuffer.length < n) {
      final chunk = await _readChunk();
      if (chunk.isEmpty) {
        throw TlsException('TLS connection closed prematurely');
      }
      _readBuffer.addAll(chunk);
    }
    final result = Uint8List.fromList(_readBuffer.sublist(0, n));
    _readBuffer.removeRange(0, n);
    return result;
  }

  /// 读一个完整 TLS 记录（5 字节 header + body）。
  Future<Uint8List> readRecord() async {
    final header = await readExact(5);
    final len = (header[3] << 8) | header[4];
    final body = await readExact(len);
    return Uint8List.fromList([...header, ...body]);
  }

  /// 读一个明文 handshake 记录，返回 handshake 消息（含 4 字节 header）。
  Future<Uint8List> readPlainHandshakeRecord() async {
    final header = await readExact(5);
    if (header[0] != 0x16) {
      throw TlsException('Expected plaintext handshake record');
    }
    final len = (header[3] << 8) | header[4];
    return await readExact(len);
  }

  void write(Uint8List data) {
    final sync = _writeSync;
    if (sync != null) {
      sync(data);
      return;
    }
    final asyncWrite = _writeAsync!;
    final pending = _pending.then((_) => asyncWrite(data));
    // 链上的错误留给 flush 抛出；这里吞掉是为了后续 write 还能排队。
    _pending = pending.catchError((Object _) {});
    _lastWrite = pending;
  }

  Future<void>? _lastWrite;

  Future<void> flush() async {
    final lastWrite = _lastWrite;
    if (lastWrite != null) await lastWrite;
    await _flush();
  }

  void close() => _close();
}

// ---- 工具 ----

/// 累积并切分 handshake 消息。
class _HandshakeBuffer {
  final List<int> _buf = [];

  bool get hasCompleteMessage {
    if (_buf.length < 4) return false;
    final len = _buf[1] << 16 | (_buf[2] << 8) | _buf[3];
    return _buf.length >= 4 + len;
  }

  ({int header, Uint8List body, Uint8List raw}) takeMessage() {
    final header = _buf[0];
    final len = _buf[1] << 16 | (_buf[2] << 8) | _buf[3];
    final raw = Uint8List.fromList(_buf.sublist(0, 4 + len));
    final body = Uint8List.fromList(_buf.sublist(4, 4 + len));
    _buf.removeRange(0, 4 + len);
    return (header: header, body: body, raw: raw);
  }

  void add(List<int> data) => _buf.addAll(data);
}

Uint8List _wrapHandshake(int type, List<int> body) {
  final out = Uint8List(4 + body.length);
  out[0] = type;
  out[1] = (body.length >> 16) & 0xff;
  out[2] = (body.length >> 8) & 0xff;
  out[3] = body.length & 0xff;
  out.setRange(4, out.length, body);
  return out;
}

Uint8List _handshakeBody(Uint8List raw) {
  final len = raw[1] << 16 | (raw[2] << 8) | raw[3];
  if (raw.length != 4 + len) {
    throw TlsException('Handshake message length mismatch');
  }
  return Uint8List.sublistView(raw, 4);
}

Uint8List _u16(int value) =>
    Uint8List.fromList([(value >> 8) & 0xff, value & 0xff]);

int _u16At(List<int> b, int offset) {
  if (offset + 1 >= b.length) {
    throw TlsException('Truncated field');
  }
  return (b[offset] << 8) | b[offset + 1];
}

int _require(List<int> b, int offset) {
  if (offset >= b.length) throw TlsException('Truncated field');
  return b[offset];
}

bool _equalBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ---- X25519 临时密钥对 ----

class X25519KeyPair {
  final Uint8List privateKey;
  final Uint8List publicKey;

  X25519KeyPair._(this.privateKey, this.publicKey);

  static X25519KeyPair generate() {
    final scalar = clampX25519Scalar(randomBytes(32));
    return X25519KeyPair._(scalar, x25519Base(scalar));
  }
}
