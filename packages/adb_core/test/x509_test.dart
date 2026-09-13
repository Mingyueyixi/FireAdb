import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:adb_core/src/adb_auth_key.dart';
import 'package:adb_core/src/x509.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/asymmetric/rsa.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/random/fortuna_random.dart';
import 'package:pointycastle/signers/pss_signer.dart';
import 'package:test/test.dart';

void main() {
  AdbRsaKeyPair freshKey() {
    final k = AdbRsaKeyPair.generate();
    k.validate();
    return k;
  }

  group('X.509 自签证书（AOSP x509_generator 模板）', () {
    test('生成并可解析回同一 RSA 公钥', () {
      final k = freshKey();
      final cert = buildSelfSignedRsaCertificate(k,
          notBefore: DateTime.utc(2026, 1, 1, 0, 0, 5));
      final parsed = ParsedX509Certificate.parse(cert.der);
      expect(parsed.publicKey.modulus, k.modulus);
      expect(parsed.publicKey.exponent, kAdbPublicExponent);
    });

    test('自签名验证通过；篡改签名后失败', () {
      final k = freshKey();
      final cert = buildSelfSignedRsaCertificate(k);
      final parsed = ParsedX509Certificate.parse(cert.der);
      expect(parsed.verifySelfSigned(), isTrue);

      final corrupted = Uint8List.fromList(cert.der);
      corrupted[corrupted.length - 1] ^= 0xff;
      final bad = ParsedX509Certificate.parse(corrupted);
      expect(bad.verifySelfSigned(), isFalse);
    });

    test('DER 结构：Certificate ::= SEQ{ tbs, alg, BIT STRING }', () {
      final k = freshKey();
      final cert = buildSelfSignedRsaCertificate(k);
      expect(cert.der[0], 0x30); // SEQUENCE
      expect(cert.der[1], 0x82); // 长格式长度
      expect(cert.der.length, greaterThan(600));
    });

    test('PEM 往返', () {
      final k = freshKey();
      final cert = buildSelfSignedRsaCertificate(k);
      final restored = AdbX509Certificate.fromPem(cert.toPem());
      expect(restored.der, cert.der);
    });

    test('与 openssl 交叉验证（openssl 不可用则跳过）', () async {
      final opensslOk = await _opensslAvailable();
      if (!opensslOk) {
        markTestSkipped('openssl not available');
        return;
      }
      final k = freshKey();
      final cert = buildSelfSignedRsaCertificate(k);
      final tmp = File(
          '${Directory.systemTemp.createTempSync('x509_test').path}/cert.der');
      tmp.writeAsBytesSync(cert.der);
      try {
        final result = await Process.run(
            'openssl', ['x509', '-inform', 'DER', '-in', tmp.path, '-text', '-noout']);
        expect(result.exitCode, 0,
            reason: 'openssl stderr: ${result.stderr}');
      } finally {
        tmp.deleteSync();
      }
    });
  });

  group('RSA-PSS-SHA256（TLS 1.3 rsa_pss_rsae_sha256）', () {
    test('正确签名通过，篡改签名失败', () {
      final k = freshKey();
      final pub = RsaPublicKey(modulus: k.modulus, exponent: kAdbPublicExponent);
      final message = Uint8List.fromList(List<int>.generate(64, (i) => i * 7));
      final signature = _pssSignForTest(k, message);
      expect(rsaPssSha256Verify(pub, message, signature), isTrue);

      final corrupted = Uint8List.fromList(signature);
      corrupted[0] ^= 0x01;
      expect(rsaPssSha256Verify(pub, message, corrupted), isFalse);
    });

    test('不同消息不通过', () {
      final k = freshKey();
      final pub = RsaPublicKey(modulus: k.modulus, exponent: kAdbPublicExponent);
      final message = Uint8List(48);
      final signature = _pssSignForTest(k, message);
      final other = Uint8List(48)..[0] = 1;
      expect(rsaPssSha256Verify(pub, other, signature), isFalse);
    });
  });

  group('PKCS#1 v1.5 SHA-256', () {
    test('证书签名外观：256 字节、非全零', () {
      final k = freshKey();
      final parsed = ParsedX509Certificate.parse(
          buildSelfSignedRsaCertificate(k).der);
      expect(parsed.signatureBytes.length, 256);
      expect(parsed.signatureBytes.any((b) => b != 0), isTrue);
    });
  });
}

Uint8List _pssSignForTest(AdbRsaKeyPair k, Uint8List message) {
  final signer = PSSSigner(RSAEngine(), SHA256Digest(), SHA256Digest());
  signer.init(
      true,
      ParametersWithSaltConfiguration(
        PrivateKeyParameter<RSAPrivateKey>(
            RSAPrivateKey(k.modulus, k.privateExponent, k.p, k.q)),
        _random(),
        kTls13PssSaltLength,
      ));
  return signer.generateSignature(message).bytes;
}

FortunaRandom _random() {
  final random = FortunaRandom();
  final source = Random.secure();
  random.seed(KeyParameter(Uint8List.fromList(
      List<int>.generate(32, (_) => source.nextInt(256)))));
  return random;
}

Future<bool> _opensslAvailable() async {
  try {
    final result = await Process.run('openssl', ['version']);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}