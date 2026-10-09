import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adb_core/adb_core.dart';
import 'package:test/test.dart';

import 'fake_adbd.dart';

void main() {
  test('空端口可以启动，占用后再启动返回 null', () async {
    final server = AdbServer();
    await server.start(port: 0, scanEmulators: false);
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

  test('host:version 写完结果后关闭连接', () async {
    final server = AdbServer();
    await server.start(port: 0, scanEmulators: false);
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port!,
    );
    try {
      socket.add(encodeServiceRequest('host:version'));
      await socket.flush();
      final payload = await socket.fold<List<int>>(<int>[], (collected, chunk) {
        collected.addAll(chunk);
        return collected;
      });
      expect(ascii.decode(payload.sublist(0, 4)), 'OKAY');
      expect(payload.length, greaterThan(8));
    } finally {
      await socket.close();
      await server.close();
    }
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
    await server.start(port: 0, scanEmulators: false);
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
    expect(listed.single.devPath, isNull);
    expect(listed.single.product, 'test');
    expect(listed.single.model, 'Phone');
    expect(listed.single.transportId, '1');
    final listing = await _hostPayload(server.port!, 'host:devices-l');
    expect(
      listing,
      '${'USB123'.padRight(22)} device product:test model:Phone '
      'device:test transport_id:1\n',
    );

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
    await server.start(port: 0, scanEmulators: false);
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

  test('host:features 和 host:tport 与官方 adb 客户端对齐', () async {
    final key = AdbRsaKeyPair.generate();
    final pair = MemoryPair.create();
    final fake =
        FakeAdbd(
            serial: 'USB123',
            banner: 'ro.product.name=test;features=shell_v2,cmd',
          )
          ..serviceHandler = (String dest) async =>
              dest == 'shell:echo hi' ? 'hi' : '';
    unawaited(fake.serve(pair.device));
    final connection = AdbConnection(pair.host, signers: <AdbRsaKeyPair>[key]);
    await connection.connect();
    final server = AdbServer();
    await server.start(port: 0, scanEmulators: false);
    server.upsert(
      AdbServerDevice(
        connection: connection,
        serial: connection.deviceSerial,
        devPath: '1-3',
        usb: true,
      ),
    );
    final port = server.port!;
    try {
      expect(await _hostPayload(port, 'host:features'), 'shell_v2,cmd');
      expect(
        await _hostPayload(port, 'host-serial:USB123:features'),
        'shell_v2,cmd',
      );
      expect(
        await _hostPayload(port, 'host-serial:1-3:features'),
        'shell_v2,cmd',
      );
      expect(
        await _hostPayload(port, 'host-serial:usb:1-3:features'),
        'shell_v2,cmd',
      );

      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      final reader = AdbSizedReader(socket);
      try {
        socket.add(encodeServiceRequest('host:tport:serial:1-3'));
        await socket.flush();
        expect(
          ascii.decode(await reader.readExactly(4), allowInvalid: true),
          'OKAY',
        );
        final id = await reader.readExactly(8);
        expect(id.length, 8);
        expect(id[0], 1);
        expect(id.sublist(1), List<int>.filled(7, 0));
        socket.add(encodeServiceRequest('shell:echo hi'));
        await socket.flush();
        expect(
          ascii.decode(await reader.readExactly(4), allowInvalid: true),
          'OKAY',
        );
      } finally {
        await reader.close();
        await socket.close();
      }
    } finally {
      await server.close();
      await connection.close();
    }
  });

  test('本机模拟器端口登记为 emulator-<控制台端口>', () async {
    final key = AdbRsaKeyPair.generate();
    final pair = MemoryPair.create();
    final fake = FakeAdbd(
      serial: 'ignored',
      banner: 'ro.product.name=PD2309;ro.product.model=V2366GA;ro.product.device=PD2309;features=shell_v2',
    )..serviceHandler = (String dest) async => '';
    unawaited(fake.serve(pair.device));
    final server = AdbServer(signers: <AdbRsaKeyPair>[key]);
    await server.start(
      port: 0,
      emulatorPorts: const <int>[5557],
      openEmulator: (int port) async {
        expect(port, 5557);
        return pair.host;
      },
    );
    final client = AdbHostClient(
      port: server.port!,
      connectTimeout: const Duration(seconds: 2),
    );
    try {
      AdbDeviceInfo? found;
      for (var attempt = 0; attempt < 20; attempt++) {
        final devices = await client.devices(long: true);
        for (final device in devices) {
          if (device.serial == 'emulator-5556') found = device;
        }
        if (found != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(found, isNotNull);
      expect(found!.product, 'PD2309');
      expect(found.model, 'V2366GA');
      expect(found.device, 'PD2309');
      expect(found.devPath, isNull);
      final listing = await _hostPayload(server.port!, 'host:devices-l');
      expect(
        listing,
        '${'emulator-5556'.padRight(22)} device '
        'product:PD2309 model:V2366GA device:PD2309 transport_id:1\n',
      );
    } finally {
      await server.close();
    }
  });

  test('forward:tcp:0 在本机监听，不把 forward 命令 OPEN 给设备', () async {
    final key = AdbRsaKeyPair.generate();
    final pair = MemoryPair.create();
    final opened = <String>[];
    final fake = FakeAdbd(serial: 'emulator-5554')
      ..serviceHandler = (String dest) async {
        opened.add(dest);
        if (dest.startsWith('tcp:')) return null;
        return '';
      };
    unawaited(fake.serve(pair.device));
    final connection = AdbConnection(pair.host, signers: <AdbRsaKeyPair>[key]);
    await connection.connect();
    final server = AdbServer();
    await server.start(port: 0, scanEmulators: false);
    server.upsert(
      AdbServerDevice(connection: connection, serial: 'emulator-5554'),
    );
    final port = server.port!;
    try {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      final reader = AdbSizedReader(socket);
      socket.add(encodeServiceRequest('host:tport:serial:emulator-5554'));
      await socket.flush();
      expect(
        ascii.decode(await reader.readExactly(4), allowInvalid: true),
        'OKAY',
      );
      await reader.readExactly(8);
      socket.add(encodeServiceRequest('host:forward:tcp:0;tcp:42337'));
      await socket.flush();
      expect(
        ascii.decode(await reader.readExactly(4), allowInvalid: true),
        'OKAY',
      );
      expect(
        ascii.decode(await reader.readExactly(4), allowInvalid: true),
        'OKAY',
      );
      final lenText = ascii.decode(
        await reader.readExactly(4),
        allowInvalid: true,
      );
      final length = int.parse(lenText, radix: 16);
      final forwarded = int.parse(
        utf8.decode(await reader.readExactly(length)),
      );
      await reader.close();
      await socket.close();

      expect(opened, isEmpty);
      final listing = await _hostPayload(port, 'host:list-forward');
      expect(listing, 'emulator-5554 tcp:$forwarded tcp:42337\n');

      final inbound = await Socket.connect(
        InternetAddress.loopbackIPv4,
        forwarded,
      );
      final echoed = Completer<String>();
      inbound.listen((data) {
        if (!echoed.isCompleted) echoed.complete(utf8.decode(data));
      });
      inbound.add(utf8.encode('ping'));
      await inbound.flush();
      expect(await echoed.future.timeout(const Duration(seconds: 2)), 'ping');
      expect(opened, ['tcp:42337']);
      await inbound.close();

      final removed = await _hostStatus(
        port,
        'host-serial:emulator-5554:killforward:tcp:$forwarded',
      );
      expect(removed, 'OKAY');
    } finally {
      await server.close();
      await connection.close();
    }
  });
}

Future<String> _hostStatus(int port, String service) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  final reader = AdbSizedReader(socket);
  try {
    socket.add(encodeServiceRequest(service));
    await socket.flush();
    return ascii.decode(await reader.readExactly(4), allowInvalid: true);
  } finally {
    await reader.close();
    await socket.close();
  }
}

Future<String> _hostPayload(int port, String service) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  final reader = AdbSizedReader(socket);
  try {
    socket.add(encodeServiceRequest(service));
    await socket.flush();
    final status = ascii.decode(
      await reader.readExactly(4),
      allowInvalid: true,
    );
    if (status != 'OKAY') {
      throw StateError('$service -> $status');
    }
    final lenText = ascii.decode(
      await reader.readExactly(4),
      allowInvalid: true,
    );
    final length = int.parse(lenText.trim(), radix: 16);
    return utf8.decode(await reader.readExactly(length));
  } finally {
    await reader.close();
    await socket.close();
  }
}
