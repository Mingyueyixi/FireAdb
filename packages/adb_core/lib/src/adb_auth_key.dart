import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/digests/sha1.dart';
import 'package:pointycastle/key_generators/api.dart';
import 'package:pointycastle/key_generators/rsa_key_generator.dart';
import 'package:pointycastle/random/fortuna_random.dart';
import 'package:pointycastle/signers/rsa_signer.dart';

import 'adb_der.dart';

/// adbd 发送的 AUTH TOKEN 长度（daemon/auth.cpp 使用 TOKEN_SIZE = 20）。
const int kAdbTokenSize = 20;

/// AOSP android_pubkey_encode 的结果大小（RSAPublicKey 结构）。
const int kAndroidPubkeySize = 524;

/// RSA 模数的字节大小（2048-bit）。
const int kAndroidPubkeyModulusSize = 256;

/// ANDROID_PUBKEY_MODULUS_SIZE_WORDS = 256 / 4 = 64。
const int kAndroidPubkeyModulusWords = 64;

/// ADB 默认的公钥指数。
final BigInt kAdbPublicExponent = BigInt.from(65537);

/// SHA-1 DigestInfo 前缀（DER 编码，由 RSASigner 内部处理，此处仅作参考）。
const String kSha1DigestInfoHex = '3021300906052b0e03021a05000414';

/// 一个 ADB 使用的 RSA-2048 密钥对。
///
/// 签名使用 SHA-1 的 PKCS#1 v1.5，与设备端 `RSA_verify(NID_sha1, ...)` 匹配。
/// 公钥以 AOSP `android_pubkey_encode` 格式导出（524 字节，base64 编码后以
/// `空格 + user@host` 结尾），而不是 OpenSSH ssh-rsa 格式。
class AdbRsaKeyPair {
  final BigInt modulus;
  final BigInt privateExponent;
  final BigInt p;
  final BigInt q;

  AdbRsaKeyPair({
    required this.modulus,
    required this.privateExponent,
    required this.p,
    required this.q,
  });

  /// 校验 p*q == modulus，避免构造非法密钥。
  void validate() {
    if (p * q != modulus) {
      throw ArgumentError('modulus inconsistent with RSA p and q');
    }
  }

  BigInt get _publicExponent => kAdbPublicExponent;

  /// 生成一个 2048-bit 的 ADB RSA 密钥对。
  static AdbRsaKeyPair generate({int bits = 2048}) {
    final random = FortunaRandom();
    final secure = Random.secure();
    final seed = Uint8List.fromList(
        List<int>.generate(32, (_) => secure.nextInt(256)));
    random.seed(KeyParameter(seed));

    final generator = RSAKeyGenerator();
    generator.init(ParametersWithRandom(
      RSAKeyGeneratorParameters(kAdbPublicExponent, bits, 8),
      random,
    ));

    final pair = generator.generateKeyPair();
    final RSAPrivateKey privateKey = pair.privateKey;

    return AdbRsaKeyPair(
      modulus: privateKey.modulus!,
      privateExponent: privateKey.privateExponent!,
      p: privateKey.p!,
      q: privateKey.q!,
    );
  }

  /// 对设备发来的 AUTH TOKEN 签名（SHA-1 的 PKCS#1 v1.5）。
  Uint8List signToken(Uint8List token) {
    final signer = RSASigner(SHA1Digest(), kSha1DigestInfoHex);
    signer.init(true,
        PrivateKeyParameter<RSAPrivateKey>(
            RSAPrivateKey(modulus, privateExponent, p, q)));
    final signature = signer.generateSignature(token);
    return signature.bytes;
  }

  /// 校验签名（用于单元测试）。
  bool verifyToken(Uint8List token, Uint8List signatureBytes) {
    final signer = RSASigner(SHA1Digest(), kSha1DigestInfoHex);
    signer.init(false, PublicKeyParameter<RSAPublicKey>(
        RSAPublicKey(modulus, kAdbPublicExponent)));
    return signer.verifySignature(token, RSASignature(signatureBytes));
  }

  /// 将公钥编码为 AOSP `android_pubkey_encode` 的 524 字节 blob。
  ///
  /// 布局（与 system/core/libcrypto_utils/android_pubkey.h 一致）：
  /// ```
  /// uint32_t modulus_size_words;   // 0x00000040 (64)，LE
  /// uint32_t n0inv;                // -1/n[0] mod 2^32，LE
  /// uint8_t  modulus[256];         // 模数 as LE words (即 BE 字节反序)
  /// uint8_t  rr[256];              // R^2 mod n as LE words, R = 2^2048
  /// uint32_t exponent;             // 0x00010001 的字节为 {01,00,01,00}，内存 LE
  /// ```
  /// 共 4+4+256+256+4 = 524 字节。base64 后即为
  /// `mDUr... user@host` 的形式。
  Uint8List encodeAndroidPublicKey() {
    final out = Uint8List(kAndroidPubkeySize);
    final data = ByteData.sublistView(out);

    data.setUint32(0, kAndroidPubkeyModulusWords, Endian.little);

    // 模数 as LE words（即 BE 字节反序）。
    final modulusLE = bigIntToLittleEndianBytes(modulus,
        minLength: kAndroidPubkeyModulusSize);
    if (modulusLE.length != kAndroidPubkeyModulusSize) {
      throw ArgumentError('modulus overflows 2048-bit slot');
    }
    out.setRange(8, 8 + kAndroidPubkeyModulusSize, modulusLE);

    // n0inv = -1/n[0] mod 2^32，其中 n[0] 是 LE word 数组的第 0 个字。
    final bigN0 = bigIntFromLittleEndianBytes(modulusLE.sublist(0, 4));
    final n0inv = -bigN0.modInverse(BigInt.one << 32) &
        ((BigInt.one << 32) - BigInt.one);
    data.setUint32(4, n0inv.toInt(), Endian.little);

    // rr = R^2 mod n，R = 2^(words*32) = 2^2048 → rr = 2^4096 mod n；写为 LE words。
    final rr =
        (BigInt.one << (2 * kAndroidPubkeyModulusWords * 32)) % modulus;
    final rrLE = bigIntToLittleEndianBytes(rr,
        minLength: kAndroidPubkeyModulusSize);
    if (rrLE.length != kAndroidPubkeyModulusSize) {
      throw ArgumentError('rr overflows 2048-bit slot');
    }
    out.setRange(8 + kAndroidPubkeyModulusSize,
        8 + 2 * kAndroidPubkeyModulusSize, rrLE);

    // exponent 以 LE 写入内存（65537 → {0x01,0x00,0x01,0x00}）。
    data.setUint32(8 + 2 * kAndroidPubkeyModulusSize, _publicExponent.toInt(),
        Endian.little);

    return out;
  }

  /// 生成 ADB 传输所用的 `base64(pubkey) user@host` 字符串。
  String base64PublicKey({String user = 'adb', String host = 'localhost'}) {
    return '${base64.encode(encodeAndroidPublicKey())} $user@$host';
  }

  /// 解析 AOSP `base64(pubkey) user@host` 字符串，返回模数与指数。
  static ({BigInt modulus, BigInt exponent}) decodeAndroidPublicKey(
      String publicKeyLine) {
    final parts = publicKeyLine.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) {
      throw FormatException('Empty public key string');
    }
    final blob = base64.decode(parts[0]);
    if (blob.length != kAndroidPubkeySize) {
      throw FormatException(
          'Public key blob length ${blob.length} != $kAndroidPubkeySize');
    }
    final data = ByteData.sublistView(blob);
    final words = data.getUint32(0, Endian.little);
    if (words != kAndroidPubkeyModulusWords) {
      throw FormatException(
          'modulus_size_words $words != $kAndroidPubkeyModulusWords');
    }
    final modulusLE = blob.sublist(8, 8 + kAndroidPubkeyModulusSize);
    final modulus = bigIntFromLittleEndianBytes(modulusLE);
    // 指数在内存中为 LE，读成 BE 得到真实值（与 android_pubkey.c 的 BN_bin2bn 一致）。
    final exponent = bigIntFromLittleEndianBytes(blob.sublist(520, 524)).toInt();
    return (modulus: modulus, exponent: BigInt.from(exponent));
  }

  // ---- PEM 持久化（PKCS#1，兼容 AOSP adbkey 的读写） ----

  /// 编码为 PKCS#1 RSAPrivateKey 的 DER。
  Uint8List encodePkcs1Der() {
    final dP = privateExponent % (p - BigInt.one);
    final dQ = privateExponent % (q - BigInt.one);
    final qInv = q.modInverse(p);
    return derEncodeSequence([
      derEncodeInteger(BigInt.zero), // version
      derEncodeInteger(modulus),
      derEncodeInteger(_publicExponent),
      derEncodeInteger(privateExponent),
      derEncodeInteger(p),
      derEncodeInteger(q),
      derEncodeInteger(dP),
      derEncodeInteger(dQ),
      derEncodeInteger(qInv),
    ]);
  }

  /// 编码为 "RSA PRIVATE KEY" PEM 文本。
  String toPem() => encodePem('RSA PRIVATE KEY', encodePkcs1Der());

  /// 解码 PEM 文本（支持 PKCS#1 `RSA PRIVATE KEY` 与 PKCS#8 `PRIVATE KEY`）。
  static AdbRsaKeyPair fromPem(String pem) {
    final (label: label, der: der) = decodePem(pem);
    final Uint8List pkcs1Der;
    switch (label) {
      case 'RSA PRIVATE KEY':
        pkcs1Der = der;
        break;
      case 'PRIVATE KEY':
        pkcs1Der = _unwrapPkcs8(der);
        break;
      default:
        throw FormatException('Unsupported PEM label: $label');
    }
    return _parsePkcs1(pkcs1Der);
  }

  static Uint8List _unwrapPkcs8(Uint8List der) {
    final sequence = DerParser(derReadSequence(der));
    final version = sequence.read();
    if (version.tag != derTagInteger) {
      throw FormatException('PKCS#8: expected INTEGER version');
    }
    final algId = sequence.read();
    if (algId.tag != derTagSequence) {
      throw FormatException('PKCS#8: expected SEQUENCE algorithm identifier');
    }
    final privateKey = sequence.read();
    if (privateKey.tag != derTagOctetString) {
      throw FormatException('PKCS#8: expected OCTET STRING private key');
    }
    return privateKey.content;
  }

  static AdbRsaKeyPair _parsePkcs1(Uint8List der) {
    final parser = DerParser(derReadSequence(der));
    final values = <BigInt>[];
    for (var i = 0; i < 9; i++) {
      if (!parser.isNotEmpty) {
        throw FormatException('PKCS#1: truncated SEQUENCE');
      }
      final element = parser.read();
      if (element.tag != derTagInteger) {
        throw FormatException('PKCS#1: expected INTEGER at position $i');
      }
      values.add(bigIntFromSignedBigEndianBytes(element.content));
    }
    final pair = AdbRsaKeyPair(
      modulus: values[1],
      privateExponent: values[3],
      p: values[4],
      q: values[5],
    );
    pair.validate();
    return pair;
  }
}

/// 从 [path] 加载 ADB RSA 密钥；不存在则生成并保存（PKCS#1 PEM）。
///
/// 与真实 adb 一样，密钥应持久化：设备首次授权后即记住该公钥，后续连接不再弹窗。
AdbRsaKeyPair loadOrCreateAdbKey(String path) {
  final file = File(path);
  if (file.existsSync()) {
    return AdbRsaKeyPair.fromPem(file.readAsStringSync());
  }
  final key = AdbRsaKeyPair.generate();
  file.parent.createSync(recursive: true);
  file.writeAsStringSync('${key.toPem()}\n');
  return key;
}