import 'dart:async';
import 'dart:convert';

import 'package:adb_core/adb_core.dart';
import 'package:test/test.dart';

import 'fake_adbd.dart';

void main() {
  test('空端口可以启动，占用后再启动返回 null', () async {
    final server = AdbServer();
    await server.start(port: 0);
    final blocked = await AdbServer.tryStart(port: server.port!);
    expect(blocked, isNull);
    final client = AdbHostClient(
      port: server.port!,
      connectTimeout: const Duration(seconds: 2),
    );
    expect((await client.version()).value, adbServerVersion);
    expect(await client.devices(), isEmpty);
    await server.close();
  });

  test('登记的设备出现在 devices -l，shell 经 host:transport 转发', () async {
    final key = AdbRsaKeyPair.generate();
    final pair = MemoryPair.create();
    final fake = FakeAdbd(serial: 'USB123')
      ..serviceHandler = (String dest) async =>
          dest == 'shell:echo hi' ? 'hi' : '';
    unawaited(fake.serve(pair.device));
    final connection = AdbConnection(pair.host, signers: <AdbRsaKeyPair>[key]);
    await connection.connect();
    final server = AdbServer();
    await server.start(port: 0);
    server.upsert(
      AdbServerDevice(
        connection: connection,
        serial: connection.deviceSerial,
        devPath: '1-1',
        product: 'test',
        model: 'Phone',
        deviceName: 'test',
        usb: true,
      ),
    );
    final client = AdbHostClient(
      port: server.port!,
      connectTimeout: const Duration(seconds: 2),
    );
    final listed = await client.devices(long: true);
    expect(listed, hasLength(1));
    expect(listed.single.serial, 'USB123');
    expect(listed.single.state, 'device');
    expect(listed.single.devPath, '1-1');
    expect(listed.single.product, 'test');
    expect(listed.single.model, 'Phone');
    expect(listed.single.transportId, isNotNull);

    try {
      final shell = await client.openShell('USB123', 'echo hi');
      final output = await shell.readStream.transform(utf8.decoder).join();
      expect(output, 'hi');
      await shell.close();
    } finally {
      await server.close();
      await connection.close();
    }
  });

  test('不存在的序列号返回 FAIL', () async {
    final server = AdbServer();
    await server.start(port: 0);
    final client = AdbHostClient(
      port: server.port!,
      connectTimeout: const Duration(seconds: 2),
    );
    try {
      expect((await client.version()).value, adbServerVersion);
      await expectLater(
        client.openShell('missing', 'echo'),
        throwsA(isA<AdbHostError>()),
      );
    } finally {
      await server.close();
    }
  });
}
