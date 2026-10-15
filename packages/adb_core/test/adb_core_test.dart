import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:adb_core/adb_core.dart';
import 'package:test/test.dart';

Stream<Uint8List> chunkStream(List<List<int>> chunks) async* {
  for (final c in chunks) {
    yield Uint8List.fromList(c);
  }
}

void main() {
  group('协议常量', () {
    test('命令线上值与 AOSP 定义一致', () {
      expect(commandSync, 0x434e5953);
      expect(commandCnxn, 0x4e584e43);
      expect(commandAuth, 0x48545541);
      expect(commandOpen, 0x4e45504f);
      expect(commandOkay, 0x59414b4f);
      expect(commandClose, 0x45534c43);
      expect(commandWrite, 0x45545257);
      expect(commandStls, 0x534c5453);
    });

    test('协议版本常量', () {
      expect(versionMin, 0x01000000);
      expect(versionSkipChecksum, 0x01000001);
      expect(maxAdbData, 256 * 1024);
    });
  });

  group('校验和', () {
    test('空 payload 求和为 0', () {
      expect(calculateChecksum(const []), 0);
    });

    test('字节求和（与 AOSP calculate_apacket_checksum 一致）', () {
      expect(calculateChecksum([1, 2, 3, 255]), 261);
    });

    test('超过 32 位时取低位', () {
      final data = List.filled(100, 255);
      expect(calculateChecksum(data), (255 * 100) & 0xffffffff);
    });
  });

  group('消息头编解码', () {
    test('24 字节小端组装', () {
      final m = AdbMessage(commandCnxn, version, maxAdbData, [1, 2, 3]);
      final head = m.packHeader();
      expect(head.length, 24);
      final h = AdbMessageHeader.parse(head);
      expect(h.command, commandCnxn);
      expect(h.arg0, version);
      expect(h.arg1, maxAdbData);
      expect(h.dataLength, 3);
      expect(h.dataCheck, 6);
      expect(h.magic, commandCnxn ^ 0xffffffff);
      expect(h.isValidMagic, isTrue);
      expect(h.commandName, 'CNXN');
    });

    test('pack 输出 = 头 + payload', () {
      final m = AdbMessage(commandWrite, 1, 2, [0x41, 0x42]);
      final bytes = m.pack();
      expect(bytes.length, 26);
      expect(bytes.sublist(24), [0x41, 0x42]);
    });

    test('skipChecksum 时 data_check 置 0', () {
      final m = AdbMessage(commandAuth, authSignature, 0, [9, 9, 9]);
      final h = AdbMessageHeader.parse(m.packHeader(skipChecksum: true));
      expect(h.dataCheck, 0);
    });

    test('payload 为空时 pack 只有头', () {
      final m = AdbMessage(commandOkay, 1, 2);
      expect(m.pack().length, 24);
    });

    test('无效 magic 校验失败', () {
      final m = AdbMessage(commandCnxn, 0, 0);
      final bytes = m.packHeader();
      final bad = ByteData.sublistView(bytes);
      bad.setUint32(20, 0xdeadbeef, Endian.little);
      expect(AdbMessageHeader.parse(bytes).isValidMagic, isFalse);
    });
  });

  group('CNXN payload', () {
    test('host 标识串以 NUL 结尾', () {
      final payload =
          encodeConnectPayload(type: 'host', serial: '', banner: 'dart-adb');
      expect(utf8.decode(payload.sublist(0, payload.length - 1)),
          'host::dart-adb');
      expect(payload.last, 0);
    });
  });

  group('智能 socket 帧', () {
    test('4 位大写十六进制长度', () {
      expect(encodeHex4(0), '0000');
      expect(encodeHex4(7), '0007');
      expect(encodeHex4(0x1f), '001F');
    });

    test('服务请求编码解码往返', () {
      final req = encodeServiceRequest('host:version');
      expect(decodeServiceRequest(req), 'host:version');
    });

    test('请求头是 4 位十六进制长度', () {
      final req = encodeServiceRequest('host:devices');
      expect(ascii.decode(req.sublist(0, 4)), '000C'); // len("host:devices")=12
    });

    test('OKAY 响应', () {
      final r = AdbServiceResponse.parse(ascii.encode('OKAY'));
      expect(r.ok, isTrue);
    });

    test('FAIL 响应解析出原因', () {
      final r = AdbServiceResponse.parse(
          ascii.encode('FAIL0005oops!'));
      expect(r.ok, isFalse);
      expect(r.message, 'oops!');
    });
  });

  group('定长读取器', () {
    test('一次读满', () async {
      final reader = AdbSizedReader(chunkStream([
        [1, 2, 3, 4, 5]
      ]));
      expect(await reader.readExactly(5), [1, 2, 3, 4, 5]);
      await reader.close();
    });

    test('跨 chunk 重组', () async {
      final reader = AdbSizedReader(chunkStream([
        [1, 2],
        [3],
        [4, 5, 6]
      ]));
      expect(await reader.readExactly(3), [1, 2, 3]);
      expect(await reader.readExactly(3), [4, 5, 6]);
      await reader.close();
    });

    test('并发多个 readExactly 排队服务', () async {
      final reader = AdbSizedReader(chunkStream([
        [1, 2, 3, 4, 5, 6]
      ]));
      final futures = [
        reader.readExactly(2),
        reader.readExactly(2),
        reader.readExactly(2),
      ];
      final results = await Future.wait(futures);
      expect(results[0], [1, 2]);
      expect(results[1], [3, 4]);
      expect(results[2], [5, 6]);
      await reader.close();
    });

    test('流结束后剩余字节仍可取出', () async {
      final controller = StreamController<List<int>>();
      final reader = AdbSizedReader(controller.stream);
      controller.add(const <int>[9, 8, 7]);
      await controller.close();
      expect(
        await reader.takeRemainingStream().expand((chunk) => chunk).toList(),
        <int>[9, 8, 7],
      );
    });

    test('流结束后未消费数据抛错', () async {
      final reader = AdbSizedReader(chunkStream([
        [1, 2]
      ]));
      await reader.readExactly(2);
      await expectLater(reader.readExactly(1), throwsStateError);
    });
  });

  group('readAdbMessage（综合）', () {
    test('读取带 payload 的消息并校验和', () async {
      final msg = AdbMessage(commandClose, 1, 2, [0xde]);
      final stream = Stream<Uint8List>.fromIterable([msg.pack()]);
      final reader = AdbSizedReader(stream);
      final got = await readAdbMessage(reader);
      expect(got.command, commandClose);
      expect(got.arg0, 1);
      expect(got.arg1, 2);
      expect(got.data, [0xde]);
    });

    test('半包重组后读取', () async {
      final msg = AdbMessage(commandOkay, 3, 4, [1, 1, 1, 1]);
      final bytes = msg.pack();
      final half = bytes.length ~/ 2;
      final reader = AdbSizedReader(chunkStream([
        bytes.sublist(0, half),
        bytes.sublist(half),
      ]));
      final got = await readAdbMessage(reader);
      expect(got.command, commandOkay);
      expect(got.data, [1, 1, 1, 1]);
    });

    test('校验和不匹配抛错', () async {
      final ok = AdbMessage(commandWrite, 1, 1, [7, 7, 7]);
      final bytes = ok.pack();
      final corrupted = ByteData.sublistView(bytes);
      // 篡改 payload（末尾字节）而不动 header 的 data_check
      corrupted.setUint8(bytes.length - 1, 8);
      final reader = AdbSizedReader(
          Stream<Uint8List>.fromIterable([corrupted.buffer.asUint8List()]));
      await expectLater(readAdbMessage(reader), throwsA(isA<AdbInvalidChecksumError>()));
    });

    test('data_check==0 视为跳过校验', () async {
      final msg = AdbMessage(commandCnxn, version, maxAdbData, [5, 6]);
      final reader =
          AdbSizedReader(Stream<Uint8List>.fromIterable([
        msg.pack(skipChecksum: true)
      ]));
      final got = await readAdbMessage(reader);
      expect(got.data, [5, 6]);
    });
  });

  group('RSA 密钥生成与签名（步骤2）', () {
    test('生成 2048-bit 密钥且 p*q==n', () {
      final key = AdbRsaKeyPair.generate();
      expect(key.modulus.bitLength, 2048);
      key.validate();
    });

    test('SHA-1 PKCS#1 签名可被验证', () {
      final key = AdbRsaKeyPair.generate();
      final token = Uint8List.fromList(List.generate(20, (i) => i));
      final sig = key.signToken(token);
      expect(sig.length, 256);
      expect(key.verifyToken(token, sig), isTrue);
      final tampered = Uint8List.fromList(token);
      tampered[0] ^= 0xff;
      expect(key.verifyToken(tampered, sig), isFalse);
    });

    test('android_pubkey 编码为 524 字节且字段正确', () {
      final key = AdbRsaKeyPair.generate();
      final blob = key.encodeAndroidPublicKey();
      expect(blob.length, kAndroidPubkeySize);
      final h = ByteData.sublistView(blob);
      // words = 64（LE）
      expect(h.getUint32(0, Endian.little), kAndroidPubkeyModulusWords);
      // exponent 内存 LE {01,00,01,00}
      expect(blob[520], 0x01);
      expect(blob[521], 0x00);
      expect(blob[522], 0x01);
      expect(blob[523], 0x00);
    });

    test('android_pubkey 编码可无损解码（decode 返回 n,e）', () {
      final key = AdbRsaKeyPair.generate();
      final line = key.base64PublicKey();
      final decoded = AdbRsaKeyPair.decodeAndroidPublicKey(line);
      expect(decoded.modulus, key.modulus);
      expect(decoded.exponent, kAdbPublicExponent);
    });

    test('android_pubkey 的 n0inv 与 rr 符合定义', () {
      final key = AdbRsaKeyPair.generate();
      final blob = key.encodeAndroidPublicKey();
      final h = ByteData.sublistView(blob);
      // n0inv = -1/n0 mod 2^32 → n0 * n0inv ≡ -1 (mod 2^32)
      final n0inv = h.getUint32(4, Endian.little);
      final mod2e32 = BigInt.one << 32;
      final n = bigIntFromLittleEndianBytes(blob.sublist(8, 264));
      final n0 = n.remainder(mod2e32);
      final product = (n0 * BigInt.from(n0inv)).remainder(mod2e32);
      expect(product, mod2e32 - BigInt.one);
      // rr = (2^2048)^2 mod n，且编码后为 LE words
      final rrDecoded =
          bigIntFromLittleEndianBytes(blob.sublist(264, 520));
      final r2modN = (BigInt.one << 4096) % n;
      expect(rrDecoded, r2modN);
    });

    test('base64PublicKey 为 "<b64> user@host" 形式', () {
      final key = AdbRsaKeyPair.generate();
      final line = key.base64PublicKey(user: 'me', host: 'pc');
      expect(line, endsWith(' me@pc'));
      expect(base64.decode(line.split(' ').first).length, kAndroidPubkeySize);
    });

    test('PEM PKCS#1 往返', () {
      final key = AdbRsaKeyPair.generate();
      final pem = key.toPem();
      expect(pem, startsWith('-----BEGIN RSA PRIVATE KEY-----'));
      final restored = AdbRsaKeyPair.fromPem(pem);
      expect(restored.modulus, key.modulus);
      expect(restored.privateExponent, key.privateExponent);
    });

    test('PKCS#8 包装可解析', () {
      final key = AdbRsaKeyPair.generate();
      final pkcs1 = key.encodePkcs1Der();
      // rsaEncryption OID 1.2.840.113549.1.1.1
      const rsaOid = [0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01];
      final algId = derEncodeSequence([
        Uint8List.fromList(rsaOid),
        derEncodeTlv(0x05, Uint8List(0)), // NULL
      ]);
      final pkcs8 = derEncodeSequence([
        derEncodeInteger(BigInt.zero),
        algId,
        derEncodeOctetString(pkcs1),
      ]);
      final pem8 = encodePem('PRIVATE KEY', pkcs8);
      final restored = AdbRsaKeyPair.fromPem(pem8);
      expect(restored.modulus, key.modulus);
    });

    test('非法密钥校验 p*q==n', () {
      expect(
        () => AdbRsaKeyPair(
          modulus: BigInt.one,
          privateExponent: BigInt.one,
          p: BigInt.one,
          q: BigInt.two,
        ).validate(),
        throwsArgumentError,
      );
    });
  });
}