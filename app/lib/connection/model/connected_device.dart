import 'dart:convert';

import 'package:adb_core/adb_core.dart';

class ConnectedDevice {
  ConnectedDevice.direct(AdbDevice device)
    : serial = device.serial,
      _device = device,
      _hostClient = null,
      _adbSerial = null;

  ConnectedDevice.viaHost(AdbHostClient hostClient, this.serial)
    : _device = null,
      _hostClient = hostClient,
      _adbSerial = serial;

  final String serial;
  final AdbDevice? _device;
  final AdbHostClient? _hostClient;
  final String? _adbSerial;

  bool get isConnected => _device?.isConnected ?? true;

  Future<ConnectedShell> openShell(String command) async {
    final device = _device;
    if (device != null) {
      return ConnectedShell.direct(await device.connection.open('shell:$command'));
    }
    final hostClient = _hostClient!;
    return ConnectedShell.viaHost(
      await hostClient.openShell(_adbSerial!, command),
    );
  }

  Future<String> shell(String command) async {
    final stream = await openShell(command);
    try {
      final bytes = await stream.readStream
          .expand((chunk) => chunk)
          .toList();
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      await stream.close();
    }
  }

  Future<Map<String, String>> getProperties() async {
    final device = _device;
    if (device != null) return device.getProperties();
    final output = await shell('getprop');
    final properties = <String, String>{};
    for (final line in const LineSplitter().convert(output)) {
      final match = RegExp(r'^\[([^\]]+)\]: \[(.*)\]$').firstMatch(line);
      if (match != null) properties[match.group(1)!] = match.group(2)!;
    }
    return properties;
  }

  Future<void> close() async {
    await _device?.close();
  }
}

class ConnectedShell {
  ConnectedShell.direct(AdbStream stream)
    : _adbStream = stream,
      _hostShell = null,
      readStream = stream.readStream();

  ConnectedShell.viaHost(AdbHostShell shell)
    : _adbStream = null,
      _hostShell = shell,
      readStream = shell.readStream;

  final AdbStream? _adbStream;
  final AdbHostShell? _hostShell;
  final Stream<List<int>> readStream;

  Future<void> write(List<int> data) async {
    final adbStream = _adbStream;
    if (adbStream != null) {
      await adbStream.write(data);
      return;
    }
    await _hostShell!.write(data);
  }

  Future<void> close() async {
    final adbStream = _adbStream;
    if (adbStream != null) {
      await adbStream.close();
      return;
    }
    await _hostShell!.close();
  }
}
