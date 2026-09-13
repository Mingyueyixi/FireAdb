import 'dart:typed_data';

import 'package:pointycastle/export.dart' show SHA512Digest;

import 'adb_der.dart' show bigIntFromLittleEndianBytes, bigIntToLittleEndianBytes;
import 'ed25519.dart';

/// BoringSSL-compatible SPAKE2 over Ed25519 (used by ADB wireless pairing).
///
/// Both sides create a context, generate a message, exchange it, then call
/// processMessage to derive the same 64-byte key material (fed into AES-128-GCM
/// via HKDF later).
///
/// Transcript: SHA-512 over length-prefixed (LE uint64) fields:
///   [myName][theirName][myMsg][theirMsg][dhShared][passwordHash]
class Spake25519 {
  /// Create a client (alice) or server (bob) SPAKE2 context.
  /// [password] is the raw pairing code bytes (UTF-8 encoded digits).
  /// Names MUST include the trailing NUL byte (as AOSP uses sizeof with NUL).
  Spake25519({
    required bool client,
    required List<int> password,
    required List<int> myName,
    required List<int> theirName,
  })  : isClient = client,
        _myName = Uint8List.fromList(myName),
        _theirName = Uint8List.fromList(theirName) {
    if (password.isEmpty) throw ArgumentError('password must not be empty');

    _passwordHash = sha512(password);

    // sc_reduce(SHA-512(password)) → password_scalar
    var w = bigIntFromLittleEndianBytes(scReduce(_passwordHash));

    // BoringSSL "password scalar hack": clear bottom 3 bits via sequential adds
    // of l (kOrder). Each add flips the tested bit because l is odd.
    if ((w & BigInt.one) != BigInt.zero) w += l;
    if (((w >> 1) & BigInt.one) != BigInt.zero) w += BigInt.two * l;
    if (((w >> 2) & BigInt.one) != BigInt.zero) w += BigInt.from(4) * l;

    _passwordScalar = bigIntToLittleEndianBytes(w, minLength: 32);

    // Generate ephemeral private scalar (reduced, cofactor-multiplied)
    _privateKey = generatePrivateKey();

    // Compute our SPAKE2 message: Pstar = P + w*maskPoint
    final P = Ed25519Point.scalarmultBase(_privateKey);
    final maskPoint = isClient ? spake2M : spake2N;
    final wMask = Ed25519Point.scalarmult(maskPoint, _passwordScalar);
    final pstar = Ed25519Point.add(P, wMask);
    _myMsg = encodePoint(pstar);
  }

  /// Whether this side is alice (client) or bob (server).
  final bool isClient;
  final Uint8List _myName;
  final Uint8List _theirName;

  /// SHA-512(password) = 64 bytes (used in transcript, NOT reduced).
  late final Uint8List _passwordHash;

  /// Password scalar w (32-byte LE, reduced mod l + bit-clearing hack).
  late final Uint8List _passwordScalar;

  /// Ephemeral private key (32-byte LE, already cofactor-multiplied by 8).
  late final Uint8List _privateKey;

  /// Our 32-byte SPAKE2 message to exchange with peer.
  late final Uint8List _myMsg;

  /// The SPAKE2 message to send to the peer. Read after construction.
  Uint8List get message => Uint8List.fromList(_myMsg);

  /// Process the peer's SPAKE2 message and return 64-byte key material
  /// (SHA-512 of the transcript) to feed into Aes128Gcm / HKDF.
  Uint8List processMessage(List<int> theirMsg) {
    if (theirMsg.length != 32) {
      throw FormatException('their_msg must be 32 bytes, got ${theirMsg.length}');
    }

    final qstar = decodePoint(Uint8List.fromList(theirMsg));
    final peerMask = isClient ? spake2N : spake2M;
    final wPeerMask = Ed25519Point.scalarmult(peerMask, _passwordScalar);
    // Q_ext = qstar - wPeerMask
    final negWPeerMask = Ed25519Point.negate(wPeerMask);
    final qext = Ed25519Point.add(qstar, negWPeerMask);

    // DH shared point
    final dhShared = Ed25519Point.scalarmult(qext, _privateKey);
    final dhEncoded = encodePoint(dhShared);

    // Transcript hash (BoringSSL order: canonicalized to alice-first so both
    // sides hash [alice_name, bob_name, alice_msg, bob_msg]).
    final transcript = SHA512Digest();
    if (isClient) {
      _updateWithLengthPrefix(transcript, _myName);
      _updateWithLengthPrefix(transcript, _theirName);
      _updateWithLengthPrefix(transcript, _myMsg);
      _updateWithLengthPrefix(transcript, Uint8List.fromList(theirMsg));
    } else {
      _updateWithLengthPrefix(transcript, _theirName);
      _updateWithLengthPrefix(transcript, _myName);
      _updateWithLengthPrefix(transcript, Uint8List.fromList(theirMsg));
      _updateWithLengthPrefix(transcript, _myMsg);
    }
    _updateWithLengthPrefix(transcript, dhEncoded);
    _updateWithLengthPrefix(transcript, _passwordHash);

    final keyMaterial = Uint8List(64);
    transcript.doFinal(keyMaterial, 0);
    return keyMaterial;
  }
}

/// Length-prefix helper: 8-byte LE uint64 || data.
void _updateWithLengthPrefix(SHA512Digest digest, Uint8List data) {
  final lenBuf = Uint8List(8);
  final len = data.length;
  for (var i = 0; i < 8; i++) {
    lenBuf[i] = (len >> (8 * i)) & 0xff;
  }
  digest.update(lenBuf, 0, lenBuf.length);
  digest.update(data, 0, data.length);
}

/// ADB peer info exchanged encrypted over SPAKE2.
class AdbPeerInfo {
  AdbPeerInfo({required this.type, required this.data});
  static const int typeRsaPubKey = 0;
  static const int typeDeviceGuid = 1;

  /// Type byte (PeerInfoType enum).
  final int type;

  /// NUL-terminated data string (8191 bytes max).
  final Uint8List data;

  /// Encode to the 8192-byte PeerInfo struct format.
  Uint8List toBytes() {
    final out = Uint8List(kPeerInfoSize);
    out[0] = type;
    if (data.length > kPeerInfoSize - 1) {
      throw ArgumentError('data too long for PeerInfo');
    }
    out.setRange(1, 1 + data.length, data);
    return out;
  }

  /// Decode from 8192-byte buffer.
  static AdbPeerInfo fromBytes(List<int> bytes) {
    if (bytes.length != kPeerInfoSize) {
      throw FormatException('PeerInfo must be $kPeerInfoSize bytes');
    }
    final type = bytes[0];
    // Read NUL-terminated string
    final end = bytes.indexOf(0, 1);
    final dataLen = end == -1 ? kPeerInfoSize - 1 : end - 1;
    return AdbPeerInfo(
      type: type,
      data: Uint8List.fromList(bytes.sublist(1, 1 + dataLen)),
    );
  }
}

const int kPeerInfoSize = 8192;

/// Pairing packet types.
const int pairingPacketSpake2Msg = 0;
const int pairingPacketPeerInfo = 1;

/// Pairing packet header: 6 bytes.
class PairingPacketHeader {
  final int version;
  final int type;
  final int payloadSize;

  PairingPacketHeader({
    required this.version,
    required this.type,
    required this.payloadSize,
  });

  static const int currentVersion = 1;
  static const int headerSize = 6;

  Uint8List toBytes() {
    final out = Uint8List(headerSize);
    out[0] = version;
    out[1] = type;
    // 4-byte big-endian payload length
    out[2] = (payloadSize >> 24) & 0xff;
    out[3] = (payloadSize >> 16) & 0xff;
    out[4] = (payloadSize >> 8) & 0xff;
    out[5] = payloadSize & 0xff;
    return out;
  }

  static PairingPacketHeader parse(List<int> bytes) {
    if (bytes.length < headerSize) {
      throw FormatException('Header too short');
    }
    final version = bytes[0];
    if (version < 1 || version > 1) {
      throw FormatException('Unsupported header version: $version');
    }
    final type = bytes[1];
    if (type != pairingPacketSpake2Msg && type != pairingPacketPeerInfo) {
      throw FormatException('Unknown packet type: $type');
    }
    final payloadSize = (bytes[2] << 24) | (bytes[3] << 16) |
        (bytes[4] << 8) | bytes[5];
    if (payloadSize == 0 || payloadSize > kPeerInfoSize * 2) {
      throw FormatException('Invalid payload size: $payloadSize');
    }
    return PairingPacketHeader(
        version: version, type: type, payloadSize: payloadSize);
  }
}