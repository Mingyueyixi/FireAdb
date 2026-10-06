import 'dart:convert';
import 'dart:typed_data';

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
      return ConnectedShell.direct(
        await device.connection.open('shell:$command'),
      );
    }
    final hostClient = _hostClient!;
    return ConnectedShell.viaHost(
      await hostClient.openShell(_adbSerial!, command),
    );
  }

  Future<String> shell(String command) async {
    final stream = await openShell(command);
    try {
      final bytes = await stream.readStream.expand((chunk) => chunk).toList();
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

  /// 打开一条可读写的 `exec:`。没有终端，适合来回传输二进制帧。
  Future<ConnectedShell> openExec(String command) async {
    final device = _device;
    if (device != null) {
      return ConnectedShell.direct(
        await device.connection.open('exec:$command'),
      );
    }
    return ConnectedShell.viaHost(
      await _hostClient!.openDeviceService(_adbSerial!, 'exec:$command'),
    );
  }

  /// exec：精确字节输出（不经过 shell tty/CRLF 处理）。
  Future<Uint8List> execOut(String command) async {
    final device = _device;
    if (device != null) return device.execOut(command);
    final stream = await _hostClient!.openDeviceService(
      _adbSerial!,
      'exec:$command',
    );
    try {
      final bytes = await stream.readStream.expand((chunk) => chunk).toList();
      return Uint8List.fromList(bytes);
    } finally {
      await stream.close();
    }
  }

  /// 打开 `sync:`。调用方保存返回值，关掉 [ConnectedSync.close] 即可停止传输。
  Future<ConnectedSync> openSync() async {
    final device = _device;
    if (device != null) {
      final stream = await device.connection.open('sync:');
      return ConnectedSync(AdbSyncClient(stream), stream.close);
    }
    final channel = await _hostClient!.openSync(_adbSerial!);
    return ConnectedSync(channel.client, channel.close);
  }

  Future<Uint8List> pull(String path, {AdbTransferProgress? onProgress}) async {
    final sync = await openSync();
    try {
      final bytes = await sync.client.pull(path, onProgress: onProgress);
      await sync.client.quit();
      return bytes;
    } finally {
      await sync.close();
    }
  }

  Future<AdbFileStat> stat(String path) async {
    final sync = await openSync();
    try {
      final stat = await sync.client.stat(path);
      await sync.client.quit();
      return stat;
    } finally {
      await sync.close();
    }
  }

  Future<void> close() async {
    await _device?.close();
  }
}

/// 上层持有的 sync 会话。 [close] 关闭底层流或 socket，不经过协议层的取消接口。
class ConnectedSync {
  ConnectedSync(this.client, Future<void> Function() close) : _close = close;

  final AdbSyncClient client;
  final Future<void> Function() _close;
  var _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _close();
    } catch (_) {}
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
