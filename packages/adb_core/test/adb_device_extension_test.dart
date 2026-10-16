import 'dart:async';
import 'dart:convert';

import 'package:adb_core/adb_core.dart';
import 'package:test/test.dart';

import 'fake_adbd.dart';

void main() {
  test('扩展扫到的设备进入 host:devices', () async {
    final pair = MemoryPair.create();
    unawaited(_accept(pair.device, 'USB123'));
    final server = AdbServer();
    await server.start(
      port: 0,
      scanEmulators: false,
      extensions: <AdbDeviceExtension>[_OneDevice(pair.host, 'USB123')],
    );

    final client = AdbHostClient(
      port: server.port!,
      connectTimeout: const Duration(seconds: 2),
    );
    AdbDeviceInfo? listed;
    for (var attempt = 0; attempt < 50; attempt++) {
      final devices = await client.devices(long: true);
      if (devices.any((device) => device.serial == 'USB123')) {
        listed = devices.single;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(listed?.serial, 'USB123');
    expect(listed?.state, 'device');
    expect(listed?.devPath, isNull);

    final shell = await client.openShell('USB123', 'echo');
    expect(await shell.readStream.transform(utf8.decoder).join(), 'pong');
    await shell.close();
    await server.close();
  });

  test('两个扩展的扫描结果进入同一份 host:devices', () async {
    final first = MemoryPair.create();
    final second = MemoryPair.create();
    unawaited(_accept(first.device, 'USB123'));
    unawaited(_accept(second.device, 'USB456'));
    final server = AdbServer();
    await server.start(
      port: 0,
      scanEmulators: false,
      extensions: <AdbDeviceExtension>[
        _OneDevice(first.host, 'USB123'),
        _OneDevice(second.host, 'USB456'),
      ],
    );

    final client = AdbHostClient(
      port: server.port!,
      connectTimeout: const Duration(seconds: 2),
    );
    List<AdbDeviceInfo> listed = const <AdbDeviceInfo>[];
    for (var attempt = 0; attempt < 50; attempt++) {
      listed = await client.devices();
      final serials = listed.map((device) => device.serial).toSet();
      if (serials.contains('USB123') && serials.contains('USB456')) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(listed.map((device) => device.serial).toSet(), <String>{
      'USB123',
      'USB456',
    });
    await server.close();
  });
}

class _OneDevice extends AdbDeviceExtension {
  _OneDevice(this.transport, this.serial);

  final AdbTransport transport;
  final String serial;

  @override
  void listen(AdbScanListener listener) {
    late final AdbConnection connection;
    connection = AdbConnection(
      transport,
      onStateChanged: (state) {
        if (state != AdbConnectionState.device) return;
        listener.onScan(<AdbScannedDevice>[
          AdbScannedDevice(
            id: serial,
            connection: connection,
            serial: serial,
            devPath: '1-1',
          ),
        ]);
      },
    );
    unawaited(connection.connect());
  }

  @override
  Future<void> cancel() async {}
}

Future<void> _accept(AdbTransport transport, String serial) async {
  final reader = AdbSizedReader(transport.stream);
  await readAdbMessage(reader, verifyChecksum: false);
  await transport.write(
    AdbMessage(
      commandCnxn,
      version,
      maxAdbData,
      encodeConnectPayload(type: 'device', serial: serial, banner: 'test'),
    ).pack(),
  );
  try {
    while (true) {
      final message = await readAdbMessage(reader, verifyChecksum: false);
      if (message.command != commandOpen) continue;
      final localId = 9;
      await transport.write(
        AdbMessage(commandOkay, localId, message.arg0, const <int>[]).pack(),
      );
      await transport.write(
        AdbMessage(
          commandWrite,
          localId,
          message.arg0,
          utf8.encode('pong'),
        ).pack(),
      );
      await transport.write(
        AdbMessage(commandClose, localId, message.arg0, const <int>[]).pack(),
      );
    }
  } catch (_) {}
}
