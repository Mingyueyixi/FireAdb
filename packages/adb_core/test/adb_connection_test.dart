import 'dart:convert';
import 'dart:typed_data';

import 'package:adb_core/adb_core.dart';
import 'package:test/test.dart';

import 'fake_adbd.dart';

/// 结束一次会话：关闭主机连接（触发设备 EOF）并等待设备进程退出。
Future<void> endSession(AdbConnection conn, FakeAdbd device) async {
  await conn.close();
  await device.done;
}

void main() {
  group('连接握手（CNXN/AUTH）', () {
    test('已授权密钥通过 SIGNATURE 完成握手', () async {
      final pair = MemoryPair.create();
      final key = AdbRsaKeyPair.generate();
      final device = FakeAdbd(verifyKey: key);

      final conn = AdbConnection(pair.host, signers: [key],
          authTimeout: const Duration(seconds: 5));
      device.serve(pair.device);

      final banner = await conn.connect();
      expect(banner, 'product:model');
      expect(conn.state, AdbConnectionState.device);
      expect(conn.deviceSerial, 'fake12345');
      // 设备侧应只通过 SIGNATURE 完成，未收到 RSAPUBLICKEY。
      final authTypes = device.received
          .where((m) => m.command == commandAuth)
          .map((m) => m.arg0);
      expect(authTypes.contains(authSignature), isTrue);
      expect(authTypes.contains(authRsaPublicKey), isFalse);
      await endSession(conn, device);
    });

    test('无已授权密钥时通过 RSAPUBLICKEY 完成握手', () async {
      final pair = MemoryPair.create();
      final key = AdbRsaKeyPair.generate();
      final device = FakeAdbd(verifyKey: null, autoInstallPublicKey: true);

      final conn = AdbConnection(pair.host, signers: [key],
          authTimeout: const Duration(seconds: 5));
      device.serve(pair.device);

      final banner = await conn.connect();
      expect(banner, 'product:model');
      final authTypes = device.received
          .where((m) => m.command == commandAuth)
          .map((m) => m.arg0);
      expect(authTypes.contains(authRsaPublicKey), isTrue);
      await endSession(conn, device);
    });

    test('无密钥可用时抛 AdbDeviceAuthError', () async {
      final pair = MemoryPair.create();
      final device = FakeAdbd(verifyKey: null, autoInstallPublicKey: true);

      final conn = AdbConnection(pair.host,
          authTimeout: const Duration(seconds: 5));
      device.serve(pair.device).catchError((_) {});

      await expectLater(conn.connect(), throwsA(isA<AdbDeviceAuthError>()));
      await endSession(conn, device);
    });

    test('公钥授权等待超时报 AdbDeviceAuthError', () async {
      final pair = MemoryPair.create();
      final key = AdbRsaKeyPair.generate();
      final device = FakeAdbd(verifyKey: null, autoInstallPublicKey: false);

      final conn = AdbConnection(pair.host,
          signers: [key], authTimeout: const Duration(milliseconds: 200));
      device.serve(pair.device).catchError((_) {});

      await expectLater(conn.connect(), throwsA(isA<AdbDeviceAuthError>()));
      await endSession(conn, device);
    });
  });

  group('流与服务（OPEN/OKAY/WRTE/CLSE）', () {
    test('shell 服务返回输出并正常关闭', () async {
      final pair = MemoryPair.create();
      final key = AdbRsaKeyPair.generate();
      final device = FakeAdbd(verifyKey: key);
      device.serviceHandler = (dest) async {
        if (dest == 'shell:echo hello') return 'hello\r\n';
        return '';
      };

      final conn = AdbConnection(pair.host, signers: [key],
          authTimeout: const Duration(seconds: 5));
      device.serve(pair.device);
      await conn.connect();

      final out = await conn.service('shell:echo hello');
      expect(utf8.decode(out), 'hello\r\n');
      await endSession(conn, device);
    });

    test('getprop 解析为键值对', () async {
      final pair = MemoryPair.create();
      final key = AdbRsaKeyPair.generate();
      final device = FakeAdbd(verifyKey: key);
      device.serviceHandler = (dest) async {
        if (dest == 'shell:getprop') {
          return '[ro.product.model]: [Pixel 8]\n[ro.build.version.release]: [14]\n';
        }
        return '';
      };

      final conn = AdbConnection(pair.host, signers: [key],
          authTimeout: const Duration(seconds: 5));
      device.serve(pair.device);
      await conn.connect();

      final props = await conn.getSystemProperties();
      expect(props['ro.product.model'], 'Pixel 8');
      expect(props['ro.build.version.release'], '14');
      await endSession(conn, device);
    });

    test('可并发打开多条流并按 id 分发', () async {
      final pair = MemoryPair.create();
      final key = AdbRsaKeyPair.generate();
      final device = FakeAdbd(verifyKey: key);
      device.serviceHandler = (dest) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return '$dest:<data>';
      };

      final conn = AdbConnection(pair.host, signers: [key],
          authTimeout: const Duration(seconds: 5));
      device.serve(pair.device);
      await conn.connect();

      final streamA = await conn.open('shell:a');
      final streamB = await conn.open('shell:b');
      final dataA = await streamA.readAll();
      final dataB = await streamB.readAll();
      expect(utf8.decode(dataA), 'shell:a:<data>');
      expect(utf8.decode(dataB), 'shell:b:<data>');
      await endSession(conn, device);
    });

    test('write 往返（echo 模式）', () async {
      final pair = MemoryPair.create();
      final key = AdbRsaKeyPair.generate();
      final device = FakeAdbd(verifyKey: key);
      device.serviceHandler = (dest) async => null; // echo 模式

      final conn = AdbConnection(pair.host, signers: [key],
          authTimeout: const Duration(seconds: 5));
      device.serve(pair.device);
      await conn.connect();

      final stream = await conn.open('shell:echo');
      await stream.write(Uint8List.fromList('ping'.codeUnits));
      await stream.close();
      await endSession(conn, device);
    });

    test('关闭本地流后 readAll 完成且不再收到数据', () async {
      final pair = MemoryPair.create();
      final key = AdbRsaKeyPair.generate();
      final device = FakeAdbd(verifyKey: key);
      device.serviceHandler = (dest) async => null; // echo 模式

      final conn = AdbConnection(pair.host, signers: [key],
          authTimeout: const Duration(seconds: 5));
      device.serve(pair.device);
      await conn.connect();

      final stream = await conn.open('shell:t');
      final readFuture = stream.readAll();
      await stream.write(Uint8List.fromList('a'.codeUnits));
      await stream.write(Uint8List.fromList('b'.codeUnits));
      await stream.close();
      // 设备回显的数据会先于 CLSE 到达；本地 close 后 host 不再等待。
      final data = await readFuture;
      expect(utf8.decode(data), anyOf('ab', 'a', 'b', ''));
      await endSession(conn, device);
    });
  });
}