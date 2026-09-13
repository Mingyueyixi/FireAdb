import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/macs/hmac.dart';

/// TLS 1.3 密钥调度所需的常量与工具函数。
/// 参考：RFC 8446 §7.1（Key Schedule）与 §4.2（Extension）。
const int kHashLen = 32;
const int kIvLen = 12;
const int kKeyLen = 16;
const int kGcmTagLen = 16;

// ---- Hash & HMAC ----

Uint8List sha256(List<int> data) {
  final d = SHA256Digest();
  final out = Uint8List(d.digestSize);
  final input = Uint8List.fromList(data);
  d.update(input, 0, input.length);
  d.doFinal(out, 0);
  return out;
}

Uint8List hmacSha256(List<int> key, List<int> data) {
  final hmac = HMac(SHA256Digest(), 64);
  hmac.init(KeyParameter(Uint8List.fromList(key)));
  hmac.update(Uint8List.fromList(data), 0, data.length);
  final out = Uint8List(hmac.macSize);
  hmac.doFinal(out, 0);
  return out;
}

// ---- HKDF (RFC 5869) ----

Uint8List hkdfExtract({required Uint8List salt, required Uint8List ikm}) {
  return hmacSha256(salt, ikm);
}

/// HKDF-Expand (RFC 5869 §2.3)。
Uint8List hkdfExpand(
    {required Uint8List prk, required Uint8List info, required int length}) {
  if (prk.length < 32) throw ArgumentError('PRK must be ≥ 32 bytes');
  final n = (length + 31) ~/ 32;
  var prev = Uint8List(0);
  final result = Uint8List(length);
  var offset = 0;
  for (var i = 1; i <= n; i++) {
    final input = Uint8List(prev.length + info.length + 1);
    input.setRange(0, prev.length, prev);
    input.setRange(prev.length, prev.length + info.length, info);
    input[input.length - 1] = i;
    prev = hmacSha256(prk, input);
    final copyLen = min(32, length - offset);
    result.setRange(offset, offset + copyLen, prev);
    offset += copyLen;
  }
  return result;
}

/// HKDF-Expand-Label (RFC 8446 §7.1）。
///
/// 返回 `length` 字节；`prk` 为 HKDF-Extract 得到的伪随机密钥。
Uint8List hkdfExpandLabel({
  required Uint8List prk,
  required String label,
  required List<int> context,
  required int length,
}) {
  final labelBytes = Uint8List.fromList(label.codeUnits);
  final contextBytes = Uint8List.fromList(context);
  final prefix = Uint8List.fromList('tls13 '.codeUnits);
  final buf = BytesBuilder();
  buf.addByte((length >> 8) & 0xff);
  buf.addByte(length & 0xff);
  buf.addByte(prefix.length + labelBytes.length);
  buf.add(prefix);
  buf.add(labelBytes);
  buf.addByte(contextBytes.length);
  buf.add(contextBytes);
  return hkdfExpand(prk: prk, info: buf.toBytes(), length: length);
}

/// Derive-Secret（RFC 8446 §7.1）。
Uint8List deriveSecret({
  required Uint8List secret,
  required String label,
  required Uint8List messages, // 所有 handshake 消息的级联
}) {
  final transcriptHash = sha256(messages);
  return hkdfExpandLabel(
      prk: secret, label: label, context: transcriptHash, length: kHashLen);
}

Uint8List deriveTrafficKey(Uint8List secret) =>
    hkdfExpandLabel(prk: secret, label: 'key', context: const [], length: kKeyLen);

Uint8List deriveTrafficIv(Uint8List secret) =>
    hkdfExpandLabel(prk: secret, label: 'iv', context: const [], length: kIvLen);

// ---- TLS 1.3 Record AEAD (AES-128-GCM) ----

Uint8List _nonceFromIvAndSeq(Uint8List iv, int seqNum) {
  final nonce = Uint8List(12);
  // seqNum is written as big-endian in the last 8 bytes.
  var s = seqNum;
  for (var i = 11; i >= 4; i--) {
    nonce[i] = s & 0xff;
    s >>= 8;
  }
  for (var i = 0; i < 12; i++) {
    nonce[i] ^= iv[i];
  }
  return nonce;
}

/// 加密 TLS 1.3 记录（RFC 8446 §5.2）。
///
/// - [innerType]：0x16（handshake）或 0x17（application data）。
/// - [payload]：应用层数据（不含内层类型字节）。
/// - 返回：完整 TLS 密文记录（含外层 5 字节 header）。
Uint8List sealRecord({
  required Uint8List key,
  required Uint8List iv,
  required int seqNum,
  required int innerType,
  required Uint8List payload,
}) {
  final cipher = GCMBlockCipher(AESEngine());
  final nonce = _nonceFromIvAndSeq(Uint8List.fromList(iv), seqNum);

  // 明文：payload || innerType
  final plaintext = Uint8List(payload.length + 1);
  plaintext.setRange(0, payload.length, payload);
  plaintext[plaintext.length - 1] = innerType;

  // 外层头：opaque_type || legacy_record_version || length（AAD = 完整头）
  final innerLen = payload.length + 1 + kGcmTagLen;
  final header = Uint8List(5);
  header[0] = 0x17; // TLS 1.3 hidden type: application data
  header[1] = 0x03;
  header[2] = 0x03;
  header[3] = (innerLen >> 8) & 0xff;
  header[4] = innerLen & 0xff;

  final aad = Uint8List.fromList(header);
  cipher.init(
      true, AEADParameters(
          KeyParameter(Uint8List.fromList(key)), 128, Uint8List.fromList(nonce), aad));
  final ciphertext = cipher.process(plaintext);

  final record = Uint8List(5 + ciphertext.length);
  record.setAll(0, header);
  record.setAll(5, ciphertext);
  return record;
}

/// 解密 TLS 1.3 记录。
///
/// 返回 `({int innerType, Uint8List payload})`；GCM 验证失败抛出异常。
({int innerType, Uint8List payload}) openRecord({
  required Uint8List key,
  required Uint8List iv,
  required int seqNum,
  required Uint8List record,
}) {
  if (record.length < 5 + kGcmTagLen) {
    throw FormatException('Record too short');
  }
  final header = record.sublist(0, 5);
  final ciphertext = record.sublist(5);
  final cipherTextLen = (header[3] << 8) | header[4];
  if (cipherTextLen != ciphertext.length) {
    throw FormatException(
        'Record length mismatch: header $cipherTextLen != actual ${ciphertext.length}');
  }

  final cipher = GCMBlockCipher(AESEngine());
  final nonce = _nonceFromIvAndSeq(Uint8List.fromList(iv), seqNum);
  final aad = Uint8List.fromList(header);

  cipher.init(
      false,
      AEADParameters(
          KeyParameter(Uint8List.fromList(key)), 128, Uint8List.fromList(nonce), aad));
  final plaintext = cipher.process(Uint8List.fromList(ciphertext));

  if (plaintext.isEmpty) {
    throw FormatException('Empty plaintext after decryption');
  }
  final innerType = plaintext[plaintext.length - 1];
  final payload =
      Uint8List.sublistView(plaintext, 0, plaintext.length - 1);
  return (innerType: innerType, payload: payload);
}

/// TLS 1.3 Finished MAC（RFC 8446 §4.4.4）。
Uint8List finishedMac(
    {required Uint8List trafficSecret,
    required Uint8List transcriptHash}) {
  final key = hkdfExpandLabel(
      prk: trafficSecret, label: 'finished', context: const [], length: kHashLen);
  return hmacSha256(key, transcriptHash);
}
