import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:adb_core/adb_core.dart';
import 'package:adb_usb/adb_usb.dart';
import 'package:test/test.dart';

void main() {
  test('扫描到的 USB 设备握手后出现在本机 server 的设备列表', () async {
    final pair = _MemoryPair.create();
    unawaited(_accept(pair.device));
    final server = AdbServer();
    await server.start(port: 0, scanEmulators: false);
    final tracker = UsbAdbTracker(
      server: server,
      signers: const <AdbRsaKeyPair>[],
      listDevices: () async => <UsbAdbDevice>[
        const UsbAdbDevice(
          address: 'usb:1-1',
          portPath: '1-1',
          vendorId: 0x18d1,
          productId: 0x4ee7,
          interfaceNumber: 0,
          endpointIn: 0x81,
          endpointOut: 0x01,
          maxPacketSize: 512,
        ),
      ],
      openDevice: (UsbAdbDevice device) async => pair.host,
      interval: const Duration(hours: 1),
    );
    await tracker.scan();

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
    await tracker.close();
    await server.close();
  });
}

Future<void> _accept(AdbTransport transport) async {
  final reader = AdbSizedReader(transport.stream);
  await readAdbMessage(reader, verifyChecksum: false);
  await transport.write(
    AdbMessage(
      commandCnxn,
      version,
      maxAdbData,
      encodeConnectPayload(type: 'device', serial: 'USB123', banner: 'test'),
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

class _MemoryPair {
  _MemoryPair._(this.host, this.device);

  final AdbTransport host;
  final AdbTransport device;

  static _MemoryPair create() {
    final hostIn = StreamController<Uint8List>();
    final deviceIn = StreamController<Uint8List>();
    return _MemoryPair._(
      _MemoryTransport(hostIn, deviceIn),
      _MemoryTransport(deviceIn, hostIn),
    );
  }
}

class _MemoryTransport implements AdbTransport {
  _MemoryTransport(this._incoming, this._outgoing);

  final StreamController<Uint8List> _incoming;
  final StreamController<Uint8List> _outgoing;
  var _closed = false;

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  Future<void> write(List<int> data) async {
    if (_closed) throw StateError('transport closed');
    _outgoing.add(Uint8List.fromList(data));
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _outgoing.close();
  }
}
