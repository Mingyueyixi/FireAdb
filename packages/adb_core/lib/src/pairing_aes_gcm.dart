import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';

import 'tls_prf.dart';

/// AOSP `Aes128Gcm`（pairing_auth/aes_128_gcm.cpp）的 Dart 等价实现。
///
/// - 密钥：HKDF-SHA256(ikm=SPAKE2 的 64 字节密钥材料, salt="" ,
///   info="adb pairing_auth aes-128-gcm key", L=16)。
/// - AEAD：AES-128-GCM，128-bit tag，无 AAD。
/// - nonce：12 字节，低 8 字节为各方向的 64 位 LE 序号（首包为全零），
///   高 4 字节恒为零（对应 AOSP `memcpy(nonce, &seq, sizeof(seq))`）。
class PairingAes128Gcm {
  static const int tagLength = 16;
  static const int nonceLength = 12;
  static const int _seqBytes = 8;

  final Uint8List _key;
  int _encSeq = 0;
  int _decSeq = 0;

  PairingAes128Gcm._(this._key);

  /// 由 SPAKE2 派生出的 64 字节密钥材料构造密码器。
  static PairingAes128Gcm fromSpakeKey(Uint8List spakeKeyMaterial) {
    final prk = hkdfExtract(salt: Uint8List(0), ikm: spakeKeyMaterial);
    final info = Uint8List.fromList(
        'adb pairing_auth aes-128-gcm key'.codeUnits);
    final key = hkdfExpand(prk: prk, info: info, length: kGcmKeyLen);
    return PairingAes128Gcm._(key);
  }

  /// 加密并追加 16 字节 tag（返回 `in_len + 16`）。
  Uint8List encrypt(Uint8List plaintext) {
    final cipher = GCMBlockCipher(AESEngine());
    cipher.init(true, AEADParameters(
        KeyParameter(_key), tagLength * 8, _nonce(_encSeq++), Uint8List(0)));
    return cipher.process(plaintext);
  }

  /// 解密并校验 tag；失败抛 [InvalidCipherTextException]。
  Uint8List decrypt(Uint8List ciphertext) {
    final cipher = GCMBlockCipher(AESEngine());
    cipher.init(false, AEADParameters(
        KeyParameter(_key), tagLength * 8, _nonce(_decSeq++), Uint8List(0)));
    return cipher.process(ciphertext);
  }

  Uint8List _nonce(int seq) {
    final nonce = Uint8List(nonceLength);
    var s = seq;
    for (var i = 0; i < _seqBytes; i++) {
      nonce[i] = s & 0xff;
      s >>= 8;
    }
    return nonce;
  }
}

const int kGcmKeyLen = 16;