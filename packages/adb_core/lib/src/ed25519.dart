import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' show SHA512Digest;

import 'adb_der.dart' show bigIntToLittleEndianBytes, bigIntFromLittleEndianBytes;

/// Edwards25519 curve group arithmetic (RFC 8032) using BigInt.
///
/// Provides base/point scalar multiplication and SPAKE2所需的编�?解码.
/// Not constant-time �?acceptable for ephemeral pairing keys.

// Field prime: p = 2^255 - 19
final BigInt p = (BigInt.one << 255) - BigInt.from(19);

// Subgroup (prime) order l
final BigInt l = (BigInt.one << 252) +
    BigInt.parse('27742317777372353535851937790883648493');

// d = -121665 / 121666 mod p
final BigInt d = (-BigInt.from(121665) * _modInverse(BigInt.from(121666), p)) % p;

// sqrt(-1) mod p  (I^2 = -1 mod p)
final BigInt sqrtMinus1 = _modPow(BigInt.from(2), (p - BigInt.one) >> 2, p);

// Base point B = (Bx, By)
final BigInt basePointY = (BigInt.from(4) * _modInverse(BigInt.from(5), p)) % p;
// Bx = sqrt((By^2 - 1) / (d*By^2 + 1))
final BigInt basePointX = _recoverXFromY(basePointY);

// 2*d mod p for addition formula
final BigInt _twoD = (d << 1) % p;

/// Modular inverse via Fermat's little theorem: a^(p-2) mod p.
BigInt _modInverse(BigInt a, BigInt mod) => _modPow(a, mod - BigInt.two, mod);

/// Modular exponentiation: base^exp mod mod.
BigInt _modPow(BigInt base, BigInt exp, BigInt mod) {
  var result = BigInt.one;
  var b = base % mod;
  var e = exp;
  while (e > BigInt.zero) {
    if (e.isOdd) result = (result * b) % mod;
    e = e >> 1;
    b = (b * b) % mod;
  }
  return result;
}

/// Recover x-coordinate from y: x² = u / v with u = y²-1, v = d*y²+1.
BigInt _recoverXFromY(BigInt y) {
  final y2 = (y * y) % p;
  final u = (y2 - BigInt.one + p) % p;
  final v = ((d * y2 + BigInt.one) % p + p) % p;
  final x2 = (u * _modInverse(v, p)) % p;
  // p = 2^255 - 19 ≡ 5 (mod 8), so (p+1)/4 is not a valid sqrt exponent.
  // Use exponent (p+3)/8 and multiply by sqrt(-1) when the first try misses.
  var x = _modPow(x2, (p + BigInt.from(3)) >> 3, p);
  if (x * x % p != x2) {
    x = (x * sqrtMinus1) % p;
  }
  if (x * x % p != x2) {
    throw ArgumentError('Not a quadratic residue');
  }
  if (x.isOdd) x = p - x;
  return x;
}

/// Extended twisted Edwards point (X : Y : Z : T) with T = X*Y/Z (mod p).
class Ed25519Point {
  BigInt X, Y, Z, T;
  Ed25519Point(this.X, this.Y, this.Z, this.T);

  /// Identity (point at infinity).
  factory Ed25519Point.identity() =>
      Ed25519Point(BigInt.zero, BigInt.one, BigInt.one, BigInt.zero);

  /// Affine coordinates.
  BigInt get x => (X * _modInverse(Z, p)) % p;
  BigInt get y => (Y * _modInverse(Z, p)) % p;

  /// Scalar addition (unified, works for P + Q, P + P, P + identity).
  /// Formula from RFC 8032 §5.1.4.
  static Ed25519Point add(Ed25519Point a, Ed25519Point b) {
    final A = ((a.Y - a.X + p) * (b.Y - b.X)) % p;
    final B = ((a.Y + a.X) * (b.Y + b.X)) % p;
    final C = (_twoD * a.T * b.T) % p;
    final D = ((a.Z << 1) * b.Z) % p;
    final E = (B - A + p) % p;
    final F = (D - C + p) % p;
    final G = (D + C) % p;
    final H = (B + A) % p;
    final x3 = (E * F) % p;
    final y3 = (G * H) % p;
    final t3 = (E * H) % p;
    final z3 = (F * G) % p;
    return Ed25519Point(x3, y3, z3, t3);
  }

  /// Point doubling.
  /// Formula from RFC 8032 §5.1.4.
  static Ed25519Point double(Ed25519Point pt) {
    final A = (pt.X * pt.X) % p;
    final B = (pt.Y * pt.Y) % p;
    final C = ((pt.Z << 1) * pt.Z) % p;
    final H = (A + B) % p;
    final E = (H - (((pt.X + pt.Y) * (pt.X + pt.Y)) % p) + p) % p;
    final G = (A - B + p) % p;
    final F = (C + G) % p;
    final x3 = (E * F) % p;
    final y3 = (G * H) % p;
    final t3 = (E * H) % p;
    final z3 = (F * G) % p;
    return Ed25519Point(x3, y3, z3, t3);
  }

  /// Negate a point: (-X : Y : Z : -T).
  static Ed25519Point negate(Ed25519Point pt) =>
      Ed25519Point(pt.X == BigInt.zero ? BigInt.zero : p - pt.X, pt.Y, pt.Z,
          pt.T == BigInt.zero ? BigInt.zero : p - pt.T);

  /// Scalar multiplication of an arbitrary point: scalar * pt.
  /// [scalar] is a little-endian encoded scalar (must be at least 32 bytes).
  static Ed25519Point scalarmult(Ed25519Point pt, List<int> scalar) {
    final bytes = scalar is Uint8List ? scalar : Uint8List.fromList(scalar);
    var result = Ed25519Point.identity();
    var addend = pt;
    for (var i = 0; i < 256; i++) {
      final bit = (bytes[i >> 3] >> (i & 7)) & 1;
      if (bit == 1) result = add(result, addend);
      addend = double(addend);
    }
    return result;
  }

  /// Scalar multiplication of base point B.
  static Ed25519Point scalarmultBase(List<int> scalar) =>
      scalarmult(_basePoint, scalar);

  @override
  String toString() => 'E($x, $y)';
}

/// Base point as extended coordinates.
final Ed25519Point _basePoint = _initBasePoint();

Ed25519Point _initBasePoint() {
  final bx = basePointX;
  final by = basePointY;
  return Ed25519Point(bx, by, BigInt.one, (bx * by) % p);
}

/// Encode a point to 32-byte compressed format (RFC 8032 §5.1.2).
/// Format: y + (x & 1) << 255  as 32-byte little-endian.
Uint8List encodePoint(Ed25519Point pt) {
  final xi = pt.x;
  final yi = pt.y;
  final bytes = bigIntToLittleEndianBytes(yi, minLength: 32);
  if (xi.isOdd) bytes[31] |= 0x80;
  return bytes;
}

/// Decode a 32-byte compressed point (RFC 8032 §5.1.3).
/// Returns (x, y) as Ed25519Point or throws FormatException.
Ed25519Point decodePoint(List<int> bytes) {
  if (bytes.length != 32) throw FormatException('Ed25519 point must be 32 bytes');
  final s = Uint8List.fromList(bytes);
  final sign = (s[31] >> 7) & 1;
  s[31] &= 0x7f;
  final y = bigIntFromLittleEndianBytes(s);
  if (y >= p) throw FormatException('y out of range');

  // x² = (y² - 1) * inv(d*y² + 1)
  final y2 = (y * y) % p;
  final u = (y2 - BigInt.one + p) % p;
  final v = ((d * y2 + BigInt.one) % p + p) % p;
  final x2 = (u * _modInverse(v, p)) % p;
  // p = 2^255 - 19 ≡ 5 (mod 8): exponent (p+3)/8, fallback * sqrt(-1).
  var x = _modPow(x2, (p + BigInt.from(3)) >> 3, p);
  if (x * x % p != x2) x = (x * sqrtMinus1) % p;
  if (x * x % p != x2) throw FormatException('Invalid Ed25519 point');
  if (x.isOdd && sign == 0) x = p - x;
  if (!x.isOdd && sign == 1) x = p - x;
  return Ed25519Point(x, y, BigInt.one, (x * y) % p);
}

/// SPAKE2 Ed25519 point M (compressed encoding, hex string).
/// From BoringSSL spake25519.c comments.
final Ed25519Point spake2M = _initSpake2Point('5ada7e4bf6ddd9adb6626d32131c6b5c51a1e347a3478f53cfcf441b88eed12e');
/// SPAKE2 Ed25519 point N (compressed encoding, hex string).
final Ed25519Point spake2N = _initSpake2Point('10e3df0ae37d8e7a99b5fe74b44672103dbddcbd06af680d71329a11693bc778');

Ed25519Point _initSpake2Point(String hexEncoded) {
  final bytes = _hexDecode(hexEncoded);
  return decodePoint(bytes);
}

Uint8List _hexDecode(String hex) {
  assert(hex.length == 64);
  final bytes = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}

/// Reduce a 64-byte scalar modulo l (Ed25519 group order).
/// This is x25519_sc_reduce: input 64 bytes LE, output 32 bytes LE (reduced mod l).
Uint8List scReduce(List<int> bytes64) {
  if (bytes64.length != 64) throw ArgumentError('sc_reduce requires 64 bytes');
  final val = bigIntFromLittleEndianBytes(bytes64);
  final reduced = val % l;
  return bigIntToLittleEndianBytes(reduced, minLength: 32);
}

/// Generate a random 64-byte nonce and reduce to a cofactor-multiple private key.
/// Returns 32-byte private scalar = (sc_reduce(random64) << 3) mod 2^256.
Uint8List generatePrivateKey() {
  final rng = Random.secure();
  final randBytes = Uint8List(64);
  for (var i = 0; i < 64; i++) {
    randBytes[i] = rng.nextInt(256);
  }
  var scalar = bigIntFromLittleEndianBytes(scReduce(randBytes));
  scalar = (scalar << 3) & ((BigInt.one << 256) - BigInt.one);
  return bigIntToLittleEndianBytes(scalar, minLength: 32);
}

/// SHA-512 hash.
Uint8List sha512(List<int> data) {
  final input = data is Uint8List ? data : Uint8List.fromList(data);
  final digest = SHA512Digest();
  final out = Uint8List(64);
  digest.update(input, 0, input.length);
  digest.doFinal(out, 0);
  return out;
}
