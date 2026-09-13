import 'dart:convert';
import 'dart:typed_data';

import 'package:adb_core/src/ed25519.dart';
import 'package:adb_core/src/spake25519.dart';
import 'package:adb_core/src/x25519.dart';
import 'package:test/test.dart';

List<int> _hex(String s) =>
    List.generate(s.length ~/ 2, (i) => int.parse(s.substring(i * 2, i * 2 + 2), radix: 16));

void main() {
  group('Ed25519 群运算（RFC 8032）', () {
    test('编码恒等式：encode(decode(s)) == s', () {
      final samples = <String>[
        '5866666666666666666666666666666666666666666666666666666666666666',
        '5ada7e4bf6ddd9adb6626d32131c6b5c51a1e347a3478f53cfcf441b88eed12e',
        '10e3df0ae37d8e7a99b5fe74b44672103dbddcbd06af680d71329a11693bc778',
      ];
      for (final s in samples) {
        final bytes = _hex(s);
        final pt = decodePoint(bytes);
        expect(encodePoint(pt), bytes);
      }
    });

    test('基点的压缩编码为 5866...66', () {
      final scalarOne = List<int>.filled(32, 0)..[0] = 1;
      final bytes = encodePoint(Ed25519Point.scalarmultBase(scalarOne));
      expect(bytes, _hex('5866666666666666666666666666666666666666666666666666666666666666'));
    });

    test('RFC 8032 §7.1：seed 展开标量 → 公钥', () {
      // seed 9d61... 的消息签名公钥
      final seed = _hex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60');
      final h = sha512(seed);
      final a = List<int>.from(h.sublist(0, 32));
      a[0] &= 248;
      a[31] &= 63;
      a[31] |= 64;
      final pub = encodePoint(Ed25519Point.scalarmultBase(a));
      expect(pub, _hex('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a'));
    });

    test('标量乘 分配性：2P == P+P', () {
      final two = List<int>.filled(32, 0)..[0] = 2;
      final P = decodePoint(_hex('5866666666666666666666666666666666666666666666666666666666666666'));
      final doubled = encodePoint(Ed25519Point.add(P, P));
      final scaled = encodePoint(Ed25519Point.scalarmult(P, two));
      expect(doubled, scaled);
    });

    test('标量乘交换律：a*(bP) == b*(aP)', () {
      final a = _hex('198c42f8a2c83292ab2c602812c5a0e30d38a935341ae3d1c7d55f6f50e51b36');
      final b = _hex('bad0a1e4c7e31b51e36546dfe78a1c73c1f71df6ecfc88c4eab114d5a3ccee1c');
      final bp = Ed25519Point.scalarmultBase(b);
      final abP = encodePoint(Ed25519Point.scalarmult(bp, a));
      final ap = Ed25519Point.scalarmultBase(a);
      final baP = encodePoint(Ed25519Point.scalarmult(ap, b));
      expect(abP, baP);
    });
  });

  group('X25519（RFC 7748）', () {
    test('§5.2 Test vector: X25519(u=e6db.., k=a546..)', () {
      final k = _hex('a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4');
      final u = _hex('e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c');
      final out = x25519(u, k);
      expect(out, _hex('c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552'));
    });

    test('§6.1: X25519(a, 9) 基点乘 = 公钥', () {
      final a = _hex('77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a');
      final out = x25519Base(a);
      expect(out, _hex('8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a'));
    });

    test('§6.1: ECDH 共享密钥一致', () {
      final a = _hex('77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a');
      final b = _hex('5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb');
      final kb = _hex('de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f');
      final ka = _hex('8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a');
      final kAB = x25519(kb, a);
      final kBA = x25519(ka, b);
      expect(kAB, kBA);
      expect(kAB, _hex('4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742'));
    });

    test('Test vector 2', () {
      final k = _hex('4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d');
      final u = _hex('e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493');
      final out = x25519(u, k);
      expect(out, _hex('95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957'));
    });

    test('DH 一致性：双方共享密钥相同', () {
      final alice = x25519KeyPair();
      final bob = x25519KeyPair();
      final aShared = x25519(bob.publicKey, alice.privateKey);
      final bShared = x25519(alice.publicKey, bob.privateKey);
      expect(aShared, bShared);
    });
  });

  group('SPAKE2（BoringSSL/ADB 兼容）', () {
    // AOSP 名称（含结尾 NUL，与 sizeof() 一致）
    final aliceName = <int>[...utf8.encode('adb pair client'), 0];
    final bobName = <int>[...utf8.encode('adb pair server'), 0];

    test('M/N 点与 BoringSSL 常量一致', () {
      expect(spake2M.x,
          BigInt.parse('31406539342727633121250288103050113562375374900226415211311216773867585644232'));
      expect(spake2M.y,
          BigInt.parse('21177308356423958466833845032658859666296341766942662650232962324899758529114'));
      expect(spake2N.x,
          BigInt.parse('49918732221787544735331783592030787422991506689877079631459872391322455579424'));
      expect(spake2N.y,
          BigInt.parse('54629554431565467720832445949441049581317094546788069926228343916274969994000'));
    });

    test('相同密码：双方派生 64 字节密钥材料一致', () {
      final password = utf8.encode('123456');
      final alice = Spake25519(
          client: true, password: password, myName: aliceName, theirName: bobName);
      final bob = Spake25519(
          client: false, password: password, myName: bobName, theirName: aliceName);

      expect(alice.message.length, 32);
      expect(bob.message.length, 32);

      final aliceKey = alice.processMessage(bob.message);
      final bobKey = bob.processMessage(alice.message);

      expect(aliceKey.length, 64);
      expect(aliceKey, bobKey);
    });

    test('不同密码：密钥材料不同', () {
      final alice = Spake25519(
          client: true, password: utf8.encode('123456'), myName: aliceName, theirName: bobName);
      final bob = Spake25519(
          client: false, password: utf8.encode('654321'), myName: bobName, theirName: aliceName);
      final aliceKey = alice.processMessage(bob.message);
      final bobKey = bob.processMessage(alice.message);
      expect(aliceKey == bobKey, isFalse);
    });

    test('角色互换时名字顺序一致（等价性）', () {
      final password = utf8.encode('000000');
      final a1 = Spake25519(
          client: true, password: password, myName: aliceName, theirName: bobName);
      final b1 = Spake25519(
          client: false, password: password, myName: bobName, theirName: aliceName);
      expect(a1.processMessage(b1.message), b1.processMessage(a1.message));
    });
  });

  group('Pairing 帧', () {
    test('PairingPacketHeader 编解码', () {
      final header = PairingPacketHeader(version: 1, type: 0, payloadSize: 32);
      final bytes = header.toBytes();
      expect(bytes.length, 6);
      final parsed = PairingPacketHeader.parse(bytes);
      expect(parsed.version, 1);
      expect(parsed.type, 0);
      expect(parsed.payloadSize, 32);
    });

    test('PeerInfo 编解码', () {
      final info = AdbPeerInfo(type: AdbPeerInfo.typeRsaPubKey,
          data: Uint8List.fromList('AAAAB3NzaC1yc2E= user@host\x00'.codeUnits));
      final bytes = info.toBytes();
      expect(bytes.length, 8192);
      final back = AdbPeerInfo.fromBytes(bytes);
      expect(back.type, 0);
      expect(String.fromCharCodes(back.data), 'AAAAB3NzaC1yc2E= user@host');
    });
  });
}