import 'dart:math';
import 'dart:typed_data';

import 'adb_der.dart' show bigIntToLittleEndianBytes, bigIntFromLittleEndianBytes;

/// X25519 (RFC 7748) Montgomery curve scalar multiplication using BigInt.
///
/// Used for TLS 1.3 key_share / ECDHE. Not constant-time �?acceptable for
/// ephemeral handshake keys in this library.

final BigInt curve25519P = (BigInt.one << 255) - BigInt.from(19);

/// (486662 - 2) / 4. Montgomery ladder constant.
final BigInt curve25519A24 = BigInt.from(121665);

/// Decode and clamp an X25519 private scalar (RFC 7748 §5).
Uint8List clampX25519Scalar(List<int> k) {
  if (k.length != 32) throw ArgumentError('X25519 scalar must be 32 bytes');
  final out = Uint8List.fromList(k);
  out[0] &= 248;
  out[31] &= 127;
  out[31] |= 64;
  return out;
}

/// X25519(base=9, k). Equivalent to key generation.
Uint8List x25519Base(List<int> k) => x25519(_uCoordBase, k);

/// 32-byte little-endian u=9 base coordinate.
final Uint8List _uCoordBase = Uint8List.fromList(<int>[
  9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
]);

/// X25519(u, k): scalar multiplication of the point with u-coordinate [u].
/// [k] is a 32-byte little-endian scalar (will be clamped).
Uint8List x25519(List<int> u, List<int> k) {
  if (u.length != 32) throw ArgumentError('X25519 u must be 32 bytes');
  final scalar = clampX25519Scalar(k);
  final uCoord = bigIntFromLittleEndianBytes(u) &
      ((BigInt.one << 255) - BigInt.one); // clear top bit
  final x1 = uCoord;
  var x2 = BigInt.one;
  var z2 = BigInt.zero;
  var x3 = uCoord;
  var z3 = BigInt.one;
  var swap = 0;

  BigInt mod(BigInt v) => (v % curve25519P + curve25519P) % curve25519P;

  for (var t = 254; t >= 0; t--) {
    final kt = (scalar[t >> 3] >> (t & 7)) & 1;
    // Constant-time conditioning is skipped; this is a plain cswap.
    // RFC 7748 §5: swap ^= k_t, cond-swap, swap = k_t.
    swap ^= kt;
    if (swap == 1) {
      final tmp = x2;
      x2 = x3;
      x3 = tmp;
      final tmp2 = z2;
      z2 = z3;
      z3 = tmp2;
    }
    swap = kt;

    final a = mod(x2 + z2);
    final aa = mod(a * a);
    final b = mod(x2 - z2);
    final bb = mod(b * b);
    final e = mod(aa - bb);
    final c = mod(x3 + z3);
    final d = mod(x3 - z3);
    final da = mod(d * a);
    final cb = mod(c * b);
    x3 = mod((da + cb) * (da + cb));
    z3 = mod(x1 * (da - cb) * (da - cb));
    x2 = mod(aa * bb);
    z2 = mod(e * (aa + (curve25519A24 * e) % curve25519P));
  }

  final result = mod(x2 * z2.modPow(curve25519P - BigInt.two, curve25519P));
  return bigIntToLittleEndianBytes(result, minLength: 32);
}

/// Generate a random X25519 key pair. Returns the (public, private) pair.
({Uint8List publicKey, Uint8List privateKey}) x25519KeyPair() {
  final rng = Random.secure();
  final privateKey = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    privateKey[i] = rng.nextInt(256);
  }
  return (publicKey: x25519Base(privateKey), privateKey: privateKey);
}
