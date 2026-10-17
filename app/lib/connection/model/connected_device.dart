import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:libadb/libadb.dart';

class ConnectedDevice {
  ConnectedDevice.direct(AdbDevice device)
    : serial = device.serial,
      _device = device,
      _hostClient = null,
      _adbSerial = null,
      _ownsConnection = true;

  /// Share the [AdbConnection] already owned by our LocalAdb server.
  /// Writes wait for device OKAY (unlike viaHost TCP flush). [close] does not
  /// tear down the server's transport.
  ConnectedDevice.shared(AdbDevice device, {String? serial})
    : serial = serial ?? device.serial,
      _device = device,
      _hostClient = null,
      _adbSerial = serial ?? device.serial,
      _ownsConnection = false;

  ConnectedDevice.viaHost(AdbHostClient hostClient, this.serial)
    : _device = null,
      _hostClient = hostClient,
      _adbSerial = serial,
      _ownsConnection = false;

  final String serial;
  final AdbDevice? _device;
  AdbHostClient? _hostClient;
  final String? _adbSerial;
  final bool _ownsConnection;

  /// 本机 adb server 端口变了之后，后续命令改连新端口。
  void retargetHostClient(AdbHostClient client) {
    if (_ownsConnection) return;
    if (_device != null) return;
    _hostClient = client;
  }

  bool get isConnected => _device?.isConnected ?? true;

  /// 连接由本机 adb server 持有时，root 后由 server 重新接上设备。
  bool get usesHost => !_ownsConnection;

  /// 打开任意设备服务并读完一行输出，例如 `root:`。
  ///
  /// `adb root` 写完提示后不会自己关连接，要等这边关掉才会重启。
  /// 读到换行或超时就返回已收到的内容，避免一直等对端关闭。
  Future<String> serviceText(String service) {
    return _serviceText(service).timeout(const Duration(seconds: 4));
  }

  Future<String> _serviceText(String service) async {
    final device = _device;
    if (device != null) {
      final stream = await device.connection.open(service);
      try {
        return await collectServiceText(stream.readStream());
      } finally {
        await stream.close();
      }
    }
    final session = await _hostClient!.openDeviceService(_adbSerial!, service);
    try {
      return await collectServiceText(session.readStream);
    } finally {
      await session.close();
    }
  }

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
    if (!_ownsConnection) return;
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

  /// 对端关闭或本地 close 结束。直连时可用来等 exec 进程退出。
  Future<void>? get closed {
    final adbStream = _adbStream;
    if (adbStream != null) return adbStream.closed;
    return null;
  }
}

/// 读到第一行，或对端关闭。没有换行时最多等 3 秒，已收到的字节仍然返回。
Future<String> collectServiceText(Stream<List<int>> stream) async {
  final bytes = <int>[];
  final done = Completer<void>();
  final subscription = stream.listen(
    (chunk) {
      if (chunk.isEmpty) return;
      bytes.addAll(chunk);
      if (!done.isCompleted && bytes.contains(0x0a)) done.complete();
    },
    onError: (Object error, StackTrace stack) {
      if (bytes.isNotEmpty) {
        if (!done.isCompleted) done.complete();
        return;
      }
      if (!done.isCompleted) done.completeError(error, stack);
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
  );
  try {
    await done.future.timeout(const Duration(seconds: 3));
  } on TimeoutException {
    if (bytes.isEmpty) rethrow;
  } finally {
    await subscription.cancel();
  }
  return utf8.decode(bytes, allowMalformed: true);
}
