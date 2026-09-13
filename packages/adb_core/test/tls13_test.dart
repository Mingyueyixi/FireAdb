import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adb_core/src/adb_auth_key.dart';
import 'package:adb_core/src/tls13.dart';
import 'package:adb_core/src/tls_prf.dart';
import 'package:adb_core/src/x25519.dart';
import 'package:adb_core/src/x509.dart';
import 'package:test/test.dart';

// ---- 工具 ----

Uint8List hx(String s) {
  final input = s.replaceAll(RegExp(r'\s'), '');
  assert(input.length.isEven);
  final out = Uint8List(input.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(input.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String b2h(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

Uint8List _u16(int v) =>
    Uint8List.fromList([(v >> 8) & 0xff, v & 0xff]);

Uint8List _wrapHandshakeMsg(int type, List<int> body) {
  final out = Uint8List(4 + body.length);
  out[0] = type;
  out[1] = (body.length >> 16) & 0xff;
  out[2] = (body.length >> 8) & 0xff;
  out[3] = body.length & 0xff;
  out.setRange(4, out.length, body);
  return out;
}

int _u16At(List<int> b, int o) => (b[o] << 8) | b[o + 1];

/// TLS 1.3 CertificateVerify 签名内容（RFC 8446 §4.4.3）。
Uint8List signedContent(String role, Uint8List transcriptHash) {
  final contextPart =
      Uint8List.fromList('TLS 1.3, $role CertificateVerify'.codeUnits);
  final out =
      Uint8List(64 + contextPart.length + 1 + transcriptHash.length);
  out.fillRange(0, 64, 0x20);
  out.setRange(64, 64 + contextPart.length, contextPart);
  out[64 + contextPart.length] = 0x00;
  out.setRange(64 + contextPart.length + 1, out.length, transcriptHash);
  return out;
}

// ---- RFC 8448 §3 已知向量 ----

const _rfc8448Ch =
    '010000c00303cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef6283024dece7'
    '000006130113031302010000910000000b0009000006736572766572ff01000100000a00140012'
    '001d0017001800190100010101020103010400230000003300260024001d002099381de560e4bd'
    '43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c002b0003020304000d0020001e04'
    '0305030603020308040805080604010501060102010402050206020202002d00020101001c00024001';

const _rfc8448Sh =
    '020000560303a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155772ed3e26928'
    '00130100002e00330024001d0020c9828876112095fe66762bdbf7c672e156d6cc253b833df1'
    'dd69b1b04e751f0f002b00020304';

const _rfc8448Flight =
    '080000240022000a00140012001d00170018001901000101010201030104001c0002400100000000'
    '0b0001b9000001b50001b0308201ac30820115a003020102020102300d06092a864886f70d01010b0500'
    '300e310c300a06035504031303727361301e170d3136303733303031323335395a170d3236303733303031'
    '323335395a300e310c300a0603550403130372736130819f300d06092a864886f70d010101050003818d'
    '0030818902818100b4bb498f8279303d980836399b36c6988c0c68de55e1bdb826d3901a2461eafd2de4'
    '9a91d015abbc9a95137ace6c1af19eaa6af98c7ced43120998e187a80ee0ccb0524b1b018c3e0b63264d'
    '449a6d38e22a5fda430846748030530ef0461c8ca9d9efbfae8ea6d1d03e2bd193eff0ab9a8002c47428'
    'a6d35a8d88d79f7f1e3f0203010001a31a301830090603551d1304023000300b0603551d0f0404030205'
    'a0300d06092a864886f70d01010b05000381810085aad2a0e5b9276b908c65f73a7267170618a54c5f8a'
    '7b337d2df7a594365417f2eae8f8a58c8f8172f9319cf36b7fd6c55b80f21a03015156726096fd335e5e'
    '67f2dbf102702e608ccae6bec1fc63a42a99be5c3eb7107c3c54e9b9eb2bd5203b1c3b84e0a8b2f7594'
    '09ba3eac9d91d402dcc0cc8f8961229ac9187b42b4de100000f000084080400805a747c5d88fa9bd2e5'
    '5ab085a61015b7211f824cd484145ab3ff52f1fda8477b0b7abc90db78e2d33a5c141a078653fa6bef78'
    '0c5ea248eeaaa785c4f394cab6d30bbe8d4859ee511f602957b15411ac027671459e46445c9ea58c181'
    'e818e95b8c3fb0bf3278409d3be152a3da5043e063dda65cdf5aea20d53dfacd42f74f3140000209b9b'
    '141d906337fbd2cbdce71df4deda4ab42c309572cb7fffee5454b78f0718';

void main() {
  group('RFC 8448 §3 密钥调度已知向量', () {
    final earlySecret =
        hx('33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a');
    final zero = Uint8List(kHashLen);

    test('Early Secret = HKDF-Extract(0, 0)', () {
      expect(hkdfExtract(salt: zero, ikm: zero), equals(earlySecret));
    });

    test('Derive-Secret(early, "derived", "") = 6f26...', () {
      final derived = hkdfExpandLabel(
          prk: earlySecret,
          label: 'derived',
          context: sha256(const []),
          length: kHashLen);
      expect(derived,
          equals(hx('6f2615a108c702c5678f54fc9dbab69716c076189c48250cebeac3576c3611ba')));
    });

    test('X25519 交换结果与 RFC 的 IKM 一致', () {
      final shared = x25519(
          hx('c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f'),
          hx('49af42ba7f7994852d713ef2784bcbcaa7911de26adc5642cb634540e7ea5005'));
      expect(shared,
          equals(hx('8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d')));
    });

    test('Handshake Secret = HKDF-Extract(derived, dhe)', () {
      final derived = hkdfExpandLabel(
          prk: earlySecret,
          label: 'derived',
          context: sha256(const []),
          length: kHashLen);
      final hs = hkdfExtract(
          salt: derived,
          ikm:
              hx('8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d'));
      expect(hs,
          equals(hx('1dc826e93606aa6fdc0aadc12f741b01046aa6b99f691ed221a9f0ca043fbeac')));
    });

    test('Transcript-Hash(CH||SH) = 860c...', () {
      final th = sha256([...hx(_rfc8448Ch), ...hx(_rfc8448Sh)]);
      expect(th,
          equals(hx('860c06edc07858ee8e78f0e7428c58edd6b43f2ca3e6e95f02ed063cf0e1cad8')));
    });

    test('c/s hs traffic 与 RFC 一致', () {
      final hs = hx('1dc826e93606aa6fdc0aadc12f741b01046aa6b99f691ed221a9f0ca043fbeac');
      final messages = Uint8List.fromList([...hx(_rfc8448Ch), ...hx(_rfc8448Sh)]);
      expect(deriveSecret(secret: hs, label: 'c hs traffic', messages: messages),
          equals(hx('b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21')));
      expect(deriveSecret(secret: hs, label: 's hs traffic', messages: messages),
          equals(hx('b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38')));
    });

    test('handshake traffic key/iv 与 RFC 一致', () {
      final cHs = hx('b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21');
      final sHs = hx('b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38');
      expect(deriveTrafficKey(cHs), equals(hx('dbfaa693d1762c5b666af5d950258d01')));
      expect(deriveTrafficIv(cHs), equals(hx('5bd3c71b836e0b76bb73265f')));
      expect(deriveTrafficKey(sHs), equals(hx('3fce516009c21727d0f2e4e86ee403bc')));
      expect(deriveTrafficIv(sHs), equals(hx('5d313eb2671276ee13000b30')));
    });

    test('finished 密钥扩展与 RFC 一致', () {
      final sHs = hx('b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38');
      final key = hkdfExpandLabel(
          prk: sHs, label: 'finished', context: const [], length: kHashLen);
      expect(key,
          equals(hx('008d3b66f816ea559f96b537e885c31fc068bf492c652f01f288a1d8cdc19fc8')));
      final cHs = hx('b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21');
      final cKey = hkdfExpandLabel(
          prk: cHs, label: 'finished', context: const [], length: kHashLen);
      expect(cKey,
          equals(hx('b80ad01015fb2f0bd65ff7d4da5d6bf83f84821d1f87fdc7d3c75b5a7b42d9c4')));
    });

    test('Master Secret 派生与 RFC 一致（含 derived 段）', () {
      final hs = hx('1dc826e93606aa6fdc0aadc12f741b01046aa6b99f691ed221a9f0ca043fbeac');
      final masterDerived = hkdfExpandLabel(
          prk: hs,
          label: 'derived',
          context: sha256(const []),
          length: kHashLen);
      expect(masterDerived,
          equals(hx('43de77e0c77713859a944db9db2590b53190a65b3ee2e4f12dd7a0bb7ce254b4')));
      final master = hkdfExtract(salt: masterDerived, ikm: zero);
      expect(master,
          equals(hx('18df06843d13a08bf2a449844c5f8a478001bc4d4c627984d5a41da8d0402919')));
    });

    test('Transcript-Hash(CH||SH||ServerFlight) = 9608...', () {
      final th = sha256(
          [...hx(_rfc8448Ch), ...hx(_rfc8448Sh), ...hx(_rfc8448Flight)]);
      expect(th,
          equals(hx('9608102a0f1ccc6db6250b7b7e417b1a000eaada3daae4777a7686c9ff83df13')));
    });

    test('application traffic 与 exp master 与 RFC 一致', () {
      final master = hx('18df06843d13a08bf2a449844c5f8a478001bc4d4c627984d5a41da8d0402919');
      final messages = Uint8List.fromList(
          [...hx(_rfc8448Ch), ...hx(_rfc8448Sh), ...hx(_rfc8448Flight)]);
      expect(deriveSecret(secret: master, label: 'c ap traffic', messages: messages),
          equals(hx('9e40646ce79a7f9dc05af8889bce6552875afa0b06df0087f792ebb7c17504a5')));
      expect(deriveSecret(secret: master, label: 's ap traffic', messages: messages),
          equals(hx('a11af9f05531f856ad47116b45a950328204b4f44bfb6b3a4b4f1f3fcb631643')));
      expect(deriveSecret(secret: master, label: 'exp master', messages: messages),
          equals(hx('fe22f881176eda18eb8f44529e6792c50c9a3f89452f68d8ae311b4309d3cf50')));
    });

    test('application traffic key/iv 与 RFC 一致', () {
      final cAp = hx('9e40646ce79a7f9dc05af8889bce6552875afa0b06df0087f792ebb7c17504a5');
      final sAp = hx('a11af9f05531f856ad47116b45a950328204b4f44bfb6b3a4b4f1f3fcb631643');
      expect(deriveTrafficKey(cAp), equals(hx('17422dda596ed5d9acd890e3c63f5051')));
      expect(deriveTrafficIv(cAp), equals(hx('5b78923dee08579033e523d9')));
      expect(deriveTrafficKey(sAp), equals(hx('9f02283b6c9c07efc26bb9f2ac92e356')));
      expect(deriveTrafficIv(sAp), equals(hx('cf782b88dd83549aadf1e984')));
    });

    test('客户端 Finished verify_data 与 RFC 一致（无客户端认证）', () {
      final cHs = hx('b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21');
      final transcriptHash =
          hx('9608102a0f1ccc6db6250b7b7e417b1a000eaada3daae4777a7686c9ff83df13');
      final fin = finishedMac(
          trafficSecret: cHs, transcriptHash: transcriptHash);
      expect(fin,
          equals(hx('a8ec436d677634ae525ac1fcebe11a039ec17694fac6e98527b642f2edd5ce61')));
    });

    test('exporter（label=adb-label）与密钥调度自洽', () {
      // exp master 已用 RFC 向量验证；这里验证对外 exporter 的 64 字节形状与确定性。
      final expMaster = hx('fe22f881176eda18eb8f44529e6792c50c9a3f89452f68d8ae311b4309d3cf50');
      final e1 = computeTls13Exporter(
          exporterSecret: expMaster, label: 'adb-label', length: 64);
      final e2 = computeTls13Exporter(
          exporterSecret: expMaster, label: 'adb-label', length: 64);
      expect(e1.length, 64);
      expect(e1, equals(e2));
      expect(b2h(e1), isNot(RegExp(r'^00+$')));
    });
  });

  group('RFC 8448 §3 记录层 AEAD 已知向量', () {
    final cApKey = hx('17422dda596ed5d9acd890e3c63f5051');
    final cApIv = hx('5b78923dee08579033e523d9');
    final sApKey = hx('9f02283b6c9c07efc26bb9f2ac92e356');
    final sApIv = hx('cf782b88dd83549aadf1e984');
    final payload = hx('000102030405060708090a0b0c0d0e0f'
        '101112131415161718191a1b1c1d1e1f'
        '202122232425262728292a2b2c2d2e2f3031');

    test('sealRecord 生成客户端第一条 application_data 记录', () {
      final record = sealRecord(
          key: cApKey,
          iv: cApIv,
          seqNum: 0,
          innerType: 0x17,
          payload: payload);
      expect(
          record,
          equals(hx('1703030043a23f7054b62c94d0affafe8228ba55cbefacea42f914aa66bcab'
              '3f2b9819a8a5b46b395bd54a9a20441e2b62974e1f5a6292a2977014bd1e3dea'
              'e63aeebb21694915e4')));
    });

    test('openRecord 解析服务端第一条 application_data 记录', () {
      final record =
          hx('17030300432e937e11ef4ac740e538ad36005fc4a46932fc3225d05f82aa1b36e30e'
              'faf97d90e6dffc602dcb501a59a8fcc49c4bf2e5f0a21c0047c2abf332540dd032e1'
              '67c2955d');
      final out = openRecord(key: sApKey, iv: sApIv, seqNum: 1, record: record);
      expect(out.innerType, 0x17);
      expect(out.payload, equals(payload));
    });

    test('seal→open 往返，且序列号参与 nonce', () {
      final record = sealRecord(
          key: cApKey,
          iv: cApIv,
          seqNum: 0,
          innerType: 0x15,
          payload: hx('0100'));
      final out = openRecord(key: cApKey, iv: cApIv, seqNum: 0, record: record);
      expect(out.innerType, 0x15);
      expect(out.payload, equals(hx('0100')));

      final record1 = sealRecord(
          key: cApKey,
          iv: cApIv,
          seqNum: 1,
          innerType: 0x17,
          payload: hx('00'));
      expect(record1, isNot(equals(record)));
    });

    test('篡改密文或使用错误序列号会导致 GCM 校验失败', () {
      final good = hx('1703030043a23f7054b62c94d0affafe8228ba55cbefacea42f914aa66bcab'
          '3f2b9819a8a5b46b395bd54a9a20441e2b62974e1f5a6292a2977014bd1e3dea'
          'e63aeebb21694915e4');
      final tampered = Uint8List.fromList(good);
      tampered[tampered.length - 1] ^= 0x01;
      expect(() => openRecord(
            key: cApKey,
            iv: cApIv,
            seqNum: 0,
            record: tampered,
          ),
          throwsException);
      expect(
          () => openRecord(key: cApKey, iv: cApIv, seqNum: 1, record: good),
          throwsException);
    });
  });

  group('loopback TLS 1.3 握手（纯 Dart 迷你服务端）', () {
    test('完整握手 + exporter + 应用数据传输', () async {
      final serverKey = AdbRsaKeyPair.generate();
      final serverCert = buildSelfSignedRsaCertificate(serverKey);
      final clientKey = AdbRsaKeyPair.generate();
      final clientCert = buildSelfSignedRsaCertificate(clientKey);

      final listener = await ServerSocket.bind('127.0.0.1', 0);
      final port = listener.port;

      final serverExporter = Completer<Uint8List>();
      final serverGotApp = Completer<String>();

      final serverDone = listener.first.then((socket) async {
        try {
          await _runTlsServer(socket,
              serverKey: serverKey,
              serverCert: serverCert,
              outExporter: serverExporter,
              outAppData: serverGotApp);
        } finally {
          // 优雅关闭并冲刷缓冲：destroy() 会丢弃尚未发往客户端的已写数据
          // （例如 pong 仍在发送队列里时服务端先跑完整个交互），导致客户端
          // 读到时连接已 "提早关闭"（全量并行跑时客户端被调度延后就命中）。
          try {
            await socket.close();
          } catch (_) {
            socket.destroy();
          }
          await listener.close();
        }
      });

      final clientSocket = await Socket.connect('127.0.0.1', port);
      try {
        final conn = await tls13ClientHandshake(
            socket: clientSocket,
            clientKey: clientKey,
            clientCertificate: clientCert);
        expect(conn.exporterKey.length, 64);

        conn.writeApplicationData(Uint8List.fromList(utf8.encode('ping from client')));
        final reply =
            await conn.readApplicationData().timeout(const Duration(seconds: 10));
        expect(utf8.decode(reply), 'pong from server');

        final serverExp = await serverExporter.future
            .timeout(const Duration(seconds: 10));
        expect(conn.exporterKey, equals(serverExp));

        final serverApp = await serverGotApp.future
            .timeout(const Duration(seconds: 10));
        expect(serverApp, 'ping from client');

        conn.close();
      } on TimeoutException {
        fail('loopback 握手超时（服务端可能报错，见 message）');
      } finally {
        clientSocket.destroy();
      }

      await serverDone.timeout(const Duration(seconds: 10));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}

/// 极简 TLS 1.3 服务端（仅用于测试客户端实现）。
/// 校验客户端 ClientHello/Certificate/CertificateVerify/Finished，
/// 并回传与服务端独立计算的 exporter 与读到的应用数据。
Future<void> _runTlsServer(
  Socket socket, {
  required AdbRsaKeyPair serverKey,
  required AdbX509Certificate serverCert,
  required Completer<Uint8List> outExporter,
  required Completer<String> outAppData,
}) async {
  final transport = _TestSocketTransport(socket);

  // ---- 读取明文 ClientHello ----
  final chRecord = await transport.readRecord();
  expect(chRecord[0], 0x16, reason: 'CH 应为明文 handshake record');
  final chMsg = chRecord.sublist(5);
  expect(chMsg[0], 1, reason: '消息类型应为 ClientHello');

  final parsed = _parseClientHello(chMsg);
  expect(parsed.cipherSuites, contains(0x1301));
  expect(parsed.supportedVersions, contains(0x0304));
  expect(parsed.sigAlgorithms, contains(0x0804));
  expect(parsed.supportedGroups, contains(0x001d));
  expect(parsed.keyShareGroup, 0x001d);
  expect(parsed.keyShare.length, 32);

  // ---- ServerHello + 密钥调度 ----
  final serverEph = X25519KeyPair.generate();
  final dhe = x25519(parsed.keyShare, serverEph.privateKey);

  final shBody = BytesBuilder()
    ..add(_u16(0x0303))
    ..add(randomBytes(32))
    ..addByte(0) // legacy_session_id_echo
    ..add(_u16(0x1301))
    ..addByte(0); // legacy_compression_method
  final keyShareExt = <int>[
    ..._u16(0x001d),
    ..._u16(32),
    ...serverEph.publicKey,
  ];
  final extensions = BytesBuilder()
    ..add(_u16(0x0033))
    ..add(_u16(keyShareExt.length))
    ..add(keyShareExt)
    ..add(_u16(0x002b))
    ..add(_u16(2))
    ..add([0x03, 0x04]);
  final extBytes = extensions.toBytes();
  shBody.add(_u16(extBytes.length));
  shBody.add(extBytes);
  final shMsg = _wrapHandshakeMsg(2, shBody.toBytes());

  transport.write(_plainHandshakeRecord(shMsg));

  final transcript = BytesBuilder()..add(chMsg)..add(shMsg);

  final zero = Uint8List(kHashLen);
  final early = hkdfExtract(salt: zero, ikm: zero);
  final derived = hkdfExpandLabel(
      prk: early, label: 'derived', context: sha256(const []), length: kHashLen);
  final hs = hkdfExtract(salt: derived, ikm: dhe);
  final cHs = deriveSecret(
      secret: hs, label: 'c hs traffic', messages: transcript.toBytes());
  final sHs = deriveSecret(
      secret: hs, label: 's hs traffic', messages: transcript.toBytes());
  final sHsKey = deriveTrafficKey(sHs);
  final sHsIv = deriveTrafficIv(sHs);
  final cHsKey = deriveTrafficKey(cHs);
  final cHsIv = deriveTrafficIv(cHs);

  // ---- 服务端 flight：EE + CertificateRequest + Certificate + CertificateVerify + Finished ----
  final eeMsg = _wrapHandshakeMsg(8, [0x00, 0x00]); // 空 extensions
  final certReqBody = <int>[
    0x00, // certificate_request_context: 空
    ..._u16(0x000d), // signature_algorithms
    ..._u16(2 + sigAlgList.length),
    ..._u16(sigAlgList.length),
    ...sigAlgList,
  ];
  final certReqMsg = _wrapHandshakeMsg(13, certReqBody);
  final cert = serverCert.der;
  final certBody = <int>[
    0x00, // cert_request_context
    ..._u24(cert.length), // certificate_list 长度
    ..._u24(cert.length), // entry cert_data 长度
    ...cert,
    ..._u16(0), // entry extensions
  ];
  final certMsg = _wrapHandshakeMsg(11, certBody);

  transcript.add(eeMsg);
  transcript.add(certReqMsg);
  transcript.add(certMsg);

  final cvSig = rsaPssSha256Sign(
      serverKey, signedContent('server', sha256(transcript.toBytes())));
  final cvMsg = _wrapHandshakeMsg(15, [
    ..._u16(0x0804),
    ..._u16(cvSig.length),
    ...cvSig,
  ]);
  transcript.add(cvMsg);

  final sFinished = finishedMac(
      trafficSecret: sHs,
      transcriptHash: sha256(transcript.toBytes()));
  final finMsg = _wrapHandshakeMsg(20, sFinished);
  transcript.add(finMsg);

  final flight = Utf8BytesUtility().concat([
    eeMsg,
    certReqMsg,
    certMsg,
    cvMsg,
    finMsg,
  ]);
  transport.write(sealRecord(
      key: sHsKey,
      iv: sHsIv,
      seqNum: 0,
      innerType: 0x16,
      payload: flight));

  // ---- master + application traffic + exporter ----
  final masterDerived = hkdfExpandLabel(
      prk: hs, label: 'derived', context: sha256(const []), length: kHashLen);
  final master = hkdfExtract(salt: masterDerived, ikm: zero);
  final transcriptAp = transcript.toBytes();
  final cAp = deriveSecret(
      secret: master, label: 'c ap traffic', messages: transcriptAp);
  final sAp = deriveSecret(
      secret: master, label: 's ap traffic', messages: transcriptAp);
  final expMaster = deriveSecret(
      secret: master, label: 'exp master', messages: transcriptAp);
  final exporter = computeTls13Exporter(
      exporterSecret: expMaster, label: 'adb-label', length: 64);
  final cApKey = deriveTrafficKey(cAp);
  final cApIv = deriveTrafficIv(cAp);
  final sApKey = deriveTrafficKey(sAp);
  final sApIv = deriveTrafficIv(sAp);

  // ---- 读取客户端 flight（Certificate + CertificateVerify + Finished） ----
  final clientFlightRec = await transport.readRecord();
  expect(clientFlightRec[0], 0x17);
  final dec = openRecord(
      key: cHsKey, iv: cHsIv, seqNum: 0, record: clientFlightRec);
  expect(dec.innerType, 0x16);

  final buffer = _HandshakeMessageBuffer()..add(dec.payload);
  final certRecv = buffer.takeMessage();
  expect(certRecv.header, 11);
  final clientCertDer = _parseSingleCertList(certRecv.body);
  final clientPub =
      ParsedX509Certificate.parse(clientCertDer).publicKey;

  transcript.add(certRecv.raw);
  final cvRecv = buffer.takeMessage();
  expect(cvRecv.header, 15);
  expect(_u16At(cvRecv.body, 0), 0x0804);
  final sigLen = _u16At(cvRecv.body, 2);
  final sig = cvRecv.body.sublist(4, 4 + sigLen);
  expect(
      rsaPssSha256Verify(
          clientPub,
          signedContent('client', sha256(transcript.toBytes())),
          Uint8List.fromList(sig)),
      isTrue,
      reason: '客户端 CertificateVerify 签名无效');

  transcript.add(cvRecv.raw);
  final finRecv = buffer.takeMessage();
  expect(finRecv.header, 20);
  final expectedClientFin = finishedMac(
      trafficSecret: cHs,
      transcriptHash: sha256(transcript.toBytes()));
  expect(finRecv.body, equals(expectedClientFin));
  transcript.add(finRecv.raw);

  // ---- 应用层：先回 NST（验证客户端跳过 post-handshake），再回数据 ----
  final nstBody = <int>[
    ..._u32(0), // ticket_lifetime
    ..._u32(0), // ticket_age_add
    0, // nonce 长度
    0, 1, 0xaa, // ticket<0..2^16-1>
    ..._u16(0), // extensions
  ];
  final nstMsg = _wrapHandshakeMsg(4, nstBody);
  transport.write(sealRecord(
      key: sApKey, iv: sApIv, seqNum: 0, innerType: 0x16, payload: nstMsg));
  transport.write(sealRecord(
      key: sApKey,
      iv: sApIv,
      seqNum: 1,
      innerType: 0x17,
      payload: Uint8List.fromList(utf8.encode('pong from server'))));

  // ---- 读取客户端应用数据 ----
  final appRec = await transport.readRecord();
  final appDec = openRecord(key: cApKey, iv: cApIv, seqNum: 0, record: appRec);
  expect(appDec.innerType, 0x17);
  outAppData.complete(utf8.decode(appDec.payload));
  outExporter.complete(exporter);
}

// ---- 测试侧工具 ----

final List<int> sigAlgList = [
  0x0403, 0x0503, 0x0603, 0x0203, 0x0804, 0x0805, 0x0806, 0x0401, 0x0501,
  0x0601, 0x0201, 0x0402, 0x0502, 0x0602, 0x0202,
];

Uint8List _u24(int v) =>
    Uint8List.fromList([(v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);

Uint8List _u32(int v) => Uint8List.fromList(
    [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);

Uint8List _plainHandshakeRecord(Uint8List msg) {
  final out = Uint8List(5 + msg.length);
  out[0] = 0x16;
  out[1] = 0x03;
  out[2] = 0x01;
  out[3] = (msg.length >> 8) & 0xff;
  out[4] = msg.length & 0xff;
  out.setAll(5, msg);
  return out;
}

class Utf8BytesUtility {
  Uint8List concat(List<Uint8List> parts) {
    final total = parts.fold<int>(0, (s, p) => s + p.length);
    final out = Uint8List(total);
    var o = 0;
    for (final p in parts) {
      out.setRange(o, o + p.length, p);
      o += p.length;
    }
    return out;
  }
}

Uint8List _parseSingleCertList(Uint8List body) {
  var o = 0;
  final ctxLen = body[o++];
  o += ctxLen;
  final listLen = body[o] << 16 | (body[o + 1] << 8) | body[o + 2];
  o += 3;
  final end = o + listLen;
  final certLen = body[o] << 16 | (body[o + 1] << 8) | body[o + 2];
  o += 3;
  final cert = Uint8List.sublistView(body, o, o + certLen);
  o += certLen;
  expect(o + 2, end, reason: 'Certificate 消息应只含一个 entry');
  return cert;
}

class _HandshakeMessageBuffer {
  final List<int> _buf = [];

  void add(List<int> data) => _buf.addAll(data);

  ({int header, Uint8List body, Uint8List raw}) takeMessage() {
    final len = _buf[1] << 16 | (_buf[2] << 8) | _buf[3];
    final raw = Uint8List.fromList(_buf.sublist(0, 4 + len));
    final body = Uint8List.fromList(_buf.sublist(4, 4 + len));
    _buf.removeRange(0, 4 + len);
    return (header: raw[0], body: body, raw: raw);
  }
}

class _TestSocketTransport {
  final Socket socket;
  final StreamIterator<List<int>> _iterator;
  final List<int> _readBuffer = [];

  _TestSocketTransport(this.socket) : _iterator = StreamIterator(socket);

  Future<Uint8List> readExact(int n) async {
    while (_readBuffer.length < n) {
      if (!await _iterator.moveNext()) {
        throw StateError('socket closed');
      }
      _readBuffer.addAll(_iterator.current);
    }
    final result = Uint8List.fromList(_readBuffer.sublist(0, n));
    _readBuffer.removeRange(0, n);
    return result;
  }

  Future<Uint8List> readRecord() async {
    final header = await readExact(5);
    final len = (header[3] << 8) | header[4];
    final body = await readExact(len);
    return Uint8List.fromList([...header, ...body]);
  }

  void write(Uint8List data) => socket.add(data);
}

({int keyShareGroup, Uint8List keyShare, List<int> cipherSuites,
  List<int> supportedVersions, List<int> sigAlgorithms,
  List<int> supportedGroups}) _parseClientHello(Uint8List msg) {
  final body = Uint8List.sublistView(msg, 4);
  var o = 0;
  o += 2; // legacy_version
  o += 32; // random
  final sidLen = body[o++];
  o += sidLen;
  final cipherSuites = <int>[];
  final cipherLen = _u16At(body, o);
  o += 2;
  for (var i = 0; i < cipherLen; i += 2) {
    cipherSuites.add(_u16At(body, o + i));
  }
  o += cipherLen;
  final compLen = body[o++];
  o += compLen;
  final extTotal = _u16At(body, o);
  o += 2;
  final extEnd = o + extTotal;
  int? keyShareGroup;
  Uint8List? keyShare;
  final supportedVersions = <int>[];
  final sigAlgorithms = <int>[];
  final supportedGroups = <int>[];
  while (o < extEnd) {
    final t = _u16At(body, o);
    final l = _u16At(body, o + 2);
    final data = body.sublist(o + 4, o + 4 + l);
    switch (t) {
      case 0x0033: // key_share
        var p = 0;
        final sharesLen = _u16At(data, p);
        p += 2;
        final e = p + sharesLen;
        if (p < e) {
          keyShareGroup = _u16At(data, p);
          final kLen = _u16At(data, p + 2);
          keyShare = Uint8List.fromList(data.sublist(p + 4, p + 4 + kLen));
        }
        break;
      case 0x002b: // supported_versions（<2..254>：u8 length + 2 字节列表）
        final vlen = data[0];
        for (var i = 0; i + 2 <= vlen; i += 2) {
          supportedVersions.add(_u16At(data, 1 + i));
        }
        break;
      case 0x000d: // signature_algorithms
        final total = _u16At(data, 0);
        for (var i = 0; i < total; i += 2) {
          sigAlgorithms.add(_u16At(data, 2 + i));
        }
        break;
      case 0x000a: // supported_groups
        final total = _u16At(data, 0);
        for (var i = 0; i < total; i += 2) {
          supportedGroups.add(_u16At(data, 2 + i));
        }
        break;
    }
    o = o + 4 + l;
  }
  return (
    keyShareGroup: keyShareGroup ?? -1,
    keyShare: keyShare ?? Uint8List(0),
    cipherSuites: cipherSuites,
    supportedVersions: supportedVersions,
    sigAlgorithms: sigAlgorithms,
    supportedGroups: supportedGroups,
  );
}