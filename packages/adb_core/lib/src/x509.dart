import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/asymmetric/rsa.dart';
import 'package:pointycastle/digests/sha1.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/random/fortuna_random.dart';
import 'package:pointycastle/signers/pss_signer.dart';
import 'package:pointycastle/signers/rsa_signer.dart';

import 'adb_auth_key.dart';
import 'adb_der.dart';

/// AOSP x509_generator.cpp 使用的自签证书模板：basicConstraints CA:TRUE、
/// keyUsage keyCertSign+cRLSign+digitalSignature、subjectKeyIdentifier=hash、
/// 有效期 10 年。证书仅用于 pairing 的 TLS 临时身份，对端 verify 接受任意证书。

const List<int> _oidRsaEncryption = [1, 2, 840, 113549, 1, 1, 1];
const List<int> _oidSha256WithRsa = [1, 2, 840, 113549, 1, 1, 11];

/// SHA-256 DigestInfo 前缀（PKCS#1 v1.5 的 EMSA-PKCS1-v1_5 编码）。
const String kSha256DigestInfoHex = '3031300d060960864801650304020105000420';

/// TLS 1.3 rsa_pss_rsae_sha256 的盐长（= SHA-256 输出长度）。
const int kTls13PssSaltLength = 32;

/// 证书（或 SPKI）中的 RSA 公钥。
class RsaPublicKey {
  final BigInt modulus;
  final BigInt exponent;

  RsaPublicKey({required this.modulus, required this.exponent});

  RSAPublicKey get pointyKey => RSAPublicKey(modulus, exponent);
}

/// 解析出来的 X.509 证书。
class ParsedX509Certificate {
  final Uint8List der;
  final RsaPublicKey publicKey;
  final Uint8List tbsDer;
  final Uint8List signatureBytes;

  ParsedX509Certificate({
    required this.der,
    required this.publicKey,
    required this.tbsDer,
    required this.signatureBytes,
  });

  /// 自签名是否通过（SHA-256 PKCS#1 v1.5）。
  bool verifySelfSigned() =>
      _pkcs1Sha256Verify(publicKey, tbsDer, signatureBytes);

  static ParsedX509Certificate parse(Uint8List der) {
    final outer = DerParser(der);
    final cert = outer.read();
    if (cert.tag != derTagSequence || outer.isNotEmpty) {
      throw FormatException('Certificate: expected exactly one SEQUENCE');
    }
    final certParser = DerParser(cert.content);

    final tbs = certParser.read();
    if (tbs.tag != derTagSequence) {
      throw FormatException('TBSCertificate: expected SEQUENCE');
    }

    final sigAlg = certParser.read();
    if (sigAlg.tag != derTagSequence) {
      throw FormatException('signatureAlgorithm: expected SEQUENCE');
    }

    final signature = certParser.read();
    if (signature.tag != derTagBitString || signature.content.isEmpty) {
      throw FormatException('signatureValue: expected BIT STRING');
    }

    final rsa = _extractRsaFromTbs(tbs.content);
    final sigBytes = signature.content.length > 1
        ? Uint8List.sublistView(signature.content, 1)
        : Uint8List(0);
    return ParsedX509Certificate(
      der: der,
      publicKey: rsa,
      tbsDer: tbs.reencoded,
      signatureBytes: sigBytes,
    );
  }
}

/// 解析 TBSCertificate 的内容，抽取其中的 RSA SPKI 公钥。
RsaPublicKey _extractRsaFromTbs(Uint8List tbsContent) {
  final parser = DerParser(tbsContent);
  while (parser.isNotEmpty) {
    final element = parser.read();
    if (element.tag != derTagSequence) {
      continue;
    }
    // SPKI 是首个内容以 AlgorithmIdentifier(rsaEncryption) + BIT STRING 开头的
    // SEQUENCE；issuer/validity/subject 与签名算法均不匹配。
    final inner = DerParser(element.content);
    final alg = inner.read();
    if (alg.tag != derTagSequence) {
      continue;
    }
    final algInner = DerParser(alg.content);
    final oid = algInner.read();
    if (oid.tag != derTagObjectIdentifier ||
        !_isRsaEncryptionOid(oid.content)) {
      continue;
    }
    final bitString = inner.read();
    if (bitString.tag != derTagBitString || bitString.content.isEmpty) {
      continue;
    }
    return _parseRsaPublicKey(bitString.content.sublist(1));
  }
  throw FormatException('TBSCertificate: RSA SPKI not found');
}

bool _isRsaEncryptionOid(Uint8List content) {
  final decoded = derDecodeOid(content);
  if (decoded.length != _oidRsaEncryption.length) {
    return false;
  }
  for (var i = 0; i < decoded.length; i++) {
    if (decoded[i] != _oidRsaEncryption[i]) {
      return false;
    }
  }
  return true;
}

RsaPublicKey _parseRsaPublicKey(Uint8List spkiBits) {
  final outer = DerParser(spkiBits);
  final rsaSeq = outer.read();
  if (rsaSeq.tag != derTagSequence) {
    throw FormatException('RSAPublicKey: expected SEQUENCE');
  }
  final rsa = DerParser(rsaSeq.content);
  final n = rsa.read();
  final e = rsa.read();
  if (n.tag != derTagInteger || e.tag != derTagInteger) {
    throw FormatException('RSAPublicKey: expected two INTEGERS');
  }
  return RsaPublicKey(
    modulus: bigIntFromBigEndianBytes(n.content),
    exponent: bigIntFromBigEndianBytes(e.content),
  );
}

/// 生成与 AOSP x509_generator 模板一致的自签 RSA 证书（DER）。
///
/// [notBefore] 缺省为当前时间，有效期 [lifetime] 默认 10 年。
/// Subject/Issuer 采用固定值：C=US, O=Android, CN=Adb。
AdbX509Certificate buildSelfSignedRsaCertificate(
  AdbRsaKeyPair key, {
  DateTime? notBefore,
  Duration lifetime = const Duration(days: 365 * 10),
}) {
  final start = (notBefore ?? DateTime.now().toUtc()).toUtc();
  final end = start.add(lifetime);

  final pkcs1Pub = derEncodeSequence([
    derEncodeInteger(key.modulus),
    derEncodeInteger(kAdbPublicExponent),
  ]);

  final spki = derEncodeSequence([
    _rsaAlgorithmId(),
    derEncodeBitString(pkcs1Pub),
  ]);

  final sha256AlgorithmId = _sha256AlgorithmId();

  final subject = _encodeName([
    (_oidCountry, 'US'),
    (_oidOrganization, 'Android'),
    (_oidCommonName, 'Adb'),
  ]);

  final validity = derEncodeSequence([
    _encodeUtcTime(start),
    _encodeUtcTime(end),
  ]);

  final ski = _sha1(pkcs1Pub);
  final extensions = derEncodeSequence([
    // subjectKeyIdentifier（非 critical）
    derEncodeSequence([
      derEncodeOid(_oidSubjectKeyIdentifier),
      derEncodeOctetString(ski),
    ]),
    // basicConstraints: critical, CA:TRUE
    derEncodeSequence([
      derEncodeOid(_oidBasicConstraints),
      derEncodeBool(true),
      derEncodeOctetString(derEncodeSequence([derEncodeBool(true)])),
    ]),
    // keyUsage: critical, digitalSignature | keyCertSign | cRLSign
    derEncodeSequence([
      derEncodeOid(_oidKeyUsage),
      derEncodeBool(true),
      derEncodeOctetString(derEncodeBitString(Uint8List.fromList([0x86]))),
    ]),
  ]);

  final tbs = derEncodeSequence([
    derEncodeTlv(derTagContext0, derEncodeInteger(BigInt.from(2))),
    derEncodeInteger(BigInt.zero),
    sha256AlgorithmId,
    subject,
    validity,
    subject,
    spki,
    derEncodeTlv(0xa3, extensions),
  ]);

  final signature = _pkcs1Sha256Sign(key, tbs);

  final cert = derEncodeSequence([
    tbs,
    sha256AlgorithmId,
    derEncodeBitString(signature),
  ]);
  return AdbX509Certificate(cert);
}

/// 生成的自签证书，以 PEM 形式输出。
class AdbX509Certificate {
  final Uint8List der;

  AdbX509Certificate(this.der);

  String toPem() => encodePem('CERTIFICATE', der);

  static AdbX509Certificate fromPem(String pem) {
    final (label: label, der: der) = decodePem(pem);
    if (label != 'CERTIFICATE') {
      throw FormatException('Expected CERTIFICATE PEM, got $label');
    }
    return AdbX509Certificate(der);
  }
}

// ---- X.501 Name / time ----

const List<int> _oidSubjectKeyIdentifier = [2, 5, 29, 14];
const List<int> _oidBasicConstraints = [2, 5, 29, 19];
const List<int> _oidKeyUsage = [2, 5, 29, 15];
const List<int> _oidCountry = [2, 5, 4, 6];
const List<int> _oidOrganization = [2, 5, 4, 10];
const List<int> _oidCommonName = [2, 5, 4, 3];

Uint8List _rsaAlgorithmId() => derEncodeSequence([
      derEncodeOid(_oidRsaEncryption),
      derEncodeTlv(0x05, Uint8List(0)),
    ]);

Uint8List _sha256AlgorithmId() => derEncodeSequence([
      derEncodeOid(_oidSha256WithRsa),
      derEncodeTlv(0x05, Uint8List(0)),
    ]);

Uint8List _encodeName(List<(List<int>, String)> attributeValues) {
  final rdns = <Uint8List>[];
  for (final (oid, value) in attributeValues) {
    final atv = derEncodeSequence([
      derEncodeOid(oid),
      derEncodeTlv(derTagPrintableString, Uint8List.fromList(value.codeUnits)),
    ]);
    rdns.add(derEncodeSet([atv]));
  }
  return derEncodeSequence(rdns);
}

Uint8List _encodeUtcTime(DateTime utc) {
  String two(int v) => v.toString().padLeft(2, '0');
  final text =
      '${two(utc.year % 100)}${two(utc.month)}${two(utc.day)}'
      '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
  return derEncodeTlv(
      derTagUtcTime, Uint8List.fromList(text.codeUnits));
}

// ---- RSA signatures ----

/// PKCS#1 v1.5 SHA-256 签署。
Uint8List pkcs1Sha256Sign(AdbRsaKeyPair key, Uint8List digestInput) {
  final signer = RSASigner(SHA256Digest(), kSha256DigestInfoHex);
  signer.init(true,
      PrivateKeyParameter<RSAPrivateKey>(
          RSAPrivateKey(key.modulus, key.privateExponent, key.p, key.q)));
  return signer.generateSignature(digestInput).bytes;
}

bool _pkcs1Sha256Verify(
    RsaPublicKey publicKey, Uint8List digestInput, Uint8List signature) {
  final signer = RSASigner(SHA256Digest(), kSha256DigestInfoHex);
  signer.init(false, PublicKeyParameter<RSAPublicKey>(publicKey.pointyKey));
  return signer.verifySignature(digestInput, RSASignature(signature));
}

Uint8List _pkcs1Sha256Sign(AdbRsaKeyPair key, Uint8List digestInput) =>
    pkcs1Sha256Sign(key, digestInput);

/// TLS 1.3 rsa_pss_rsae_sha256 验签。[message] 为待验签原文。
bool rsaPssSha256Verify(
    RsaPublicKey publicKey, Uint8List message, Uint8List signature) {
  final signer = PSSSigner(RSAEngine(), SHA256Digest(), SHA256Digest());
  signer.init(
      false,
      ParametersWithSaltConfiguration(
        PublicKeyParameter<RSAPublicKey>(publicKey.pointyKey),
        _secureRandom(),
        kTls13PssSaltLength,
      ));
  return signer.verifySignature(message, PSSSignature(signature));
}

/// TLS 1.3 rsa_pss_rsae_sha256 签名（客户端 CertificateVerify 用）。
Uint8List rsaPssSha256Sign(AdbRsaKeyPair key, Uint8List message) {
  final signer = PSSSigner(RSAEngine(), SHA256Digest(), SHA256Digest());
  signer.init(
      true,
      ParametersWithSaltConfiguration(
        PrivateKeyParameter<RSAPrivateKey>(
            RSAPrivateKey(key.modulus, key.privateExponent, key.p, key.q)),
        _secureRandom(),
        kTls13PssSaltLength,
      ));
  return signer.generateSignature(message).bytes;
}

FortunaRandom _secureRandom() {
  final random = FortunaRandom();
  final source = Random.secure();
  random.seed(KeyParameter(Uint8List.fromList(
      List<int>.generate(32, (_) => source.nextInt(256)))));
  return random;
}

Uint8List _sha1(Uint8List input) {
  final digest = SHA1Digest();
  final out = Uint8List(digest.digestSize);
  digest.update(input, 0, input.length);
  digest.doFinal(out, 0);
  return out;
}