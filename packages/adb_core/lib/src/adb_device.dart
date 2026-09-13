/// 高层设备抽象：包装一条已建立的 [AdbConnection]，提供用户级操作。
///
/// 直连路径（TCP→设备 5555，或 USB）都走 [AdbConnection] 的 adbd 协议，
/// 因此本类对 TCP / USB 统一可用。与 `google/python-adb` 的
/// `AdbCommands` 对应。
library;

import 'dart:io' show File;
import 'dart:typed_data';

import 'adb_auth_key.dart';
import 'adb_connection.dart';
import 'adb_filesync.dart';
import 'adb_tcp_transport.dart';

/// 连接到 TCP 设备（WiFi 5555 / 模拟器端口）。
Future<AdbDevice> adbConnectTcp(
  String host, {
  int port = 5555,
  List<AdbRsaKeyPair>? signers,
  Duration authTimeout = const Duration(seconds: 30),
  Duration connectTimeout = const Duration(seconds: 10),
}) async {
  final transport = await AdbTcpTransport.connect(
    host,
    port,
    connectTimeout: connectTimeout,
  );
  final connection = AdbConnection(
    transport,
    signers: signers,
    authTimeout: authTimeout,
  );
  await connection.connect();
  return AdbDevice(connection);
}

/// 一条已建立的设备连接。
class AdbDevice {
  AdbDevice(this._connection);

  final AdbConnection _connection;

  AdbConnection get connection => _connection;

  String get banner => _connection.deviceBanner;
  String get serial => _connection.deviceSerial;
  bool get isConnected => _connection.isConnected;

  /// 关闭连接。
  Future<void> close() => _connection.close();

  /// 运行非交互 shell 命令并返回输出。
  Future<String> shell(String command) => _connection.shell(command);

  /// 解析 getprop 输出为键值对。
  Future<Map<String, String>> getProperties() =>
      _connection.getSystemProperties();

  /// shell 命令的原始字节输出（注意 `/bin/sh` 会 CRLF 转换）。
  Future<Uint8List> shellBytes(String command) =>
      _connection.service('shell:$command');

  /// exec：精确字节输出（不经过 shell tty/CRLF 处理），如 PNG。
  Future<Uint8List> execOut(String command) async {
    final stream = await _connection.open('exec:$command');
    final data = await stream.readAll();
    await stream.close();
    return data;
  }

  /// 截图并返回 PNG 字节（`screencap -p`）。
  Future<Uint8List> screencapPng() => execOut('screencap -p');

  /// stat 远端文件。
  Future<AdbFileStat> stat(String path) async {
    final sync = await _openSync();
    try {
      return await sync.stat(path);
    } finally {
      await sync.quit();
    }
  }

  /// 列出远端目录。
  Future<List<AdbFileEntry>> list(String path) async {
    final sync = await _openSync();
    try {
      return await sync.list(path);
    } finally {
      await sync.quit();
    }
  }

  /// 拉取远端文件。
  Future<Uint8List> pull(String path, {AdbTransferProgress? onProgress}) async {
    final sync = await _openSync();
    try {
      return await sync.pull(path, onProgress: onProgress);
    } finally {
      await sync.quit();
    }
  }

  /// 推送字节到远端。
  Future<void> pushBytes(
    List<int> bytes,
    String remotePath, {
    int mode = 0x81a4, // 0o100644
    int? mtime,
    AdbTransferProgress? onProgress,
  }) async {
    final sync = await _openSync();
    try {
      await sync.push(bytes, remotePath,
          mode: mode, mtime: mtime, onProgress: onProgress);
    } finally {
      await sync.quit();
    }
  }

  /// 安装 APK：先推送到 /data/local/tmp，再 `pm install`，最后清理。
  Future<String> install(
    List<int> apkBytes, {
    String fileName = 'toolbox-install.apk',
    bool replaceExisting = true,
    bool grantPermissions = false,
    AdbTransferProgress? onProgress,
  }) async {
    final remote = '/data/local/tmp/$fileName';
    await pushBytes(apkBytes, remote, onProgress: onProgress);
    final buffer = StringBuffer('pm install');
    if (grantPermissions) buffer.write(' -g');
    if (replaceExisting) buffer.write(' -r');
    buffer.write(' "$remote"');
    final result = await shell(buffer.toString());
    await shell('rm -f "$remote"');
    return result;
  }

  /// 卸载应用。
  Future<String> uninstall(String packageName, {bool keepData = false}) async {
    final options = keepData ? ' -k' : '';
    return shell('pm uninstall$options "$packageName"');
  }

  /// 重启设备；[destination] 可为 ''（正常）或 'bootloader'。
  Future<void> reboot({String destination = ''}) async {
    final service = destination.isEmpty ? 'reboot' : 'reboot:$destination';
    final stream = await _connection.open(service);
    await stream.readAll();
    await stream.close();
  }

  /// 推送本地文件到远端（逐文件）。
  Future<void> pushFile(String localPath, String remotePath,
      {AdbTransferProgress? onProgress}) {
    // ignore: avoid_async_using_files
    final file = File(localPath);
    return pushBytes(file.readAsBytesSync(), remotePath,
        onProgress: onProgress);
  }

Future<AdbSyncClient> _openSync() async {
    final stream = await _connection.open('sync:');
    return AdbSyncClient(stream);
  }
}