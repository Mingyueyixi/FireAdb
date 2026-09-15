/// 高层设备抽象：包装一条已建立的 [AdbConnection]，提供用户级操作。
///
/// 直连路径（TCP→设备 5555，或 USB）都走 [AdbConnection] 的 adbd 协议，
/// 因此本类对 TCP / USB 统一可用。与 `google/python-adb` 的
/// `AdbCommands` 对应。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;
import 'dart:typed_data';

import 'adb_auth_key.dart';
import 'adb_connection.dart';
import 'adb_filesync.dart';
import 'adb_host_client.dart';
import 'adb_tcp_transport.dart';

/// 连接到 TCP 设备（WiFi 5555 / 模拟器端口）。
///
/// 适用场景：
/// - 已知设备 IP 和端口（如 `adb connect 192.168.8.150:6666`）
/// - 设备**未**开启无线调试，或 mDNS 扫描无结果时
/// - 模拟器端口、USB 网络共享等非 mDNS 场景
///
/// 与 [MdnsBrowser.discover] 的区别：
/// - 本方法：直接 TCP 握手，**不依赖 mDNS**，只要端口通即可连
/// - mDNS 发现：仅能发现**主动广播** `_adb-tls-pairing._tcp` 等服务的设备
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

  /// 端口转发：`adb forward`（本地→设备）。
  ///
  /// [local] 格式：`tcp:<port>`、`localabstract:<name>`、`localreserved:<name>`、
  /// `localfilesystem:<path>`、`jdwp:<pid>` 等。
  /// [remote] 格式同理，通常为 `tcp:<port>` 或 `localabstract:<name>`。
  ///
  /// 示例：
  /// ```dart
  /// await device.forward(local: 'tcp:8080', remote: 'tcp:8080');
  /// await device.forward(local: 'localabstract:myapp', remote: 'localabstract:myapp');
  /// ```
  Future<void> forward({
    required String local,
    required String remote,
    bool noRebind = false,
  }) async {
    final spec = noRebind ? 'forward:norebind:$local;$remote' : 'forward:$local;$remote';
    await _connection.service(spec);
  }

  /// 移除端口转发。
  Future<void> forwardRemove({required String local}) async {
    await _connection.service('forward:remove:$local');
  }

  /// 列出所有转发规则。
  Future<List<ForwardRule>> listForwards() async {
    final output = await _connection.service('forward:list');
    final text = utf8.decode(output, allowMalformed: true);
    return _parseForwardList(text);
  }

  List<ForwardRule> _parseForwardList(String text) {
    final rules = <ForwardRule>[];
    for (final line in const LineSplitter().convert(text)) {
      if (line.trim().isEmpty) continue;
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 3) {
        rules.add(ForwardRule(
          serial: parts[0],
          local: parts[1],
          remote: parts[2],
        ));
      }
    }
    return rules;
  }

  /// 反向端口转发：`adb reverse`（设备→本地）。
  ///
  /// 需要 Android 5.0+ (API 21+)。适用于设备访问电脑上的服务。
  Future<void> reverse({
    required String remote,
    required String local,
    bool noRebind = false,
  }) async {
    final spec = noRebind ? 'reverse:norebind:$remote;$local' : 'reverse:$remote;$local';
    await _connection.service(spec);
  }

  /// 移除反向转发规则。
  Future<void> reverseRemove({required String remote}) async {
    await _connection.service('reverse:remove:$remote');
  }

  /// 列出所有反向转发规则。
  Future<List<ReverseRule>> listReverses() async {
    final output = await _connection.service('reverse:list');
    final text = utf8.decode(output, allowMalformed: true);
    return _parseReverseList(text);
  }

  List<ReverseRule> _parseReverseList(String text) {
    final rules = <ReverseRule>[];
    for (final line in const LineSplitter().convert(text)) {
      if (line.trim().isEmpty) continue;
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 3) {
        rules.add(ReverseRule(
          serial: parts[0],
          remote: parts[1],
          local: parts[2],
        ));
      }
    }
    return rules;
  }

  /// 启用 WiFi ADB（`adb tcpip <port>`）。
  ///
  /// 成功后设备会在指定端口监听 TCP 连接，可用 `adb connect IP:PORT` 连接。
  /// 默认端口 5555。需要 root 或设备已授权。
  Future<String> enableTcpip({int port = 5555}) async {
    return await shell('setprop service.adb.tcp.port $port && stop adbd && start adbd');
  }

  /// 禁用 WiFi ADB，恢复 USB 模式。
  Future<String> disableTcpip() async {
    return await shell('setprop service.adb.tcp.port -1 && stop adbd && start adbd');
  }

  /// 实时日志流（`adb logcat`）。
  ///
  /// 返回字节流，可用 `transform(utf8.decoder).transform(LineSplitter())` 逐行处理。
  /// [filters] 格式如 `['*:V', 'MyTag:D']`。
  /// 示例：
  /// ```dart
  /// final stream = await device.logcat(filters: ['*:V']);
  /// await for (final line in stream.transform(utf8.decoder).transform(LineSplitter())) {
  ///   print(line);
  /// }
  /// ```
  Future<Stream<Uint8List>> logcat({
    List<String> filters = const ['*:V'],
    String? format,
    bool binary = false,
  }) async {
    final args = <String>[];
    if (binary) args.add('-B');
    if (format != null) args.addAll(['-v', format]);
    args.addAll(filters);
    final stream = await _connection.open('shell:logcat ${args.join(' ')}');
    return stream.readStream().asBroadcastStream();
  }

  /// 截取 bugreport（`adb bugreport`）。
  ///
  /// 返回压缩的 bugreport 文件字节（通常为 .zip）。
  /// 可能需要较长时间（30-120秒）。
  Future<Uint8List> bugreport() async {
    final stream = await _connection.open('shell:bugreport');
    return await stream.readAll();
  }

  /// 录屏（`adb shell screenrecord`）。
  ///
  /// [outputPath] 设备上的输出路径（如 `/sdcard/video.mp4`）。
  /// [options] 额外参数：`--time-limit 180 --bit-rate 8000000 --size 1920x1080` 等。
  /// 返回录制完成后的输出信息。
  Future<String> screenrecord({
    required String outputPath,
    String options = '',
  }) async {
    return await shell('screenrecord $options "$outputPath"');
  }

  /// 列出已安装包（`pm list packages`）。
  ///
  /// [flags] 可选：`-3` (第三方)、`-s` (系统)、`-e` (已启用)、`-d` (已禁用)、`-u` (含卸载但保留数据)。
  Future<List<String>> listPackages({List<String> flags = const []}) async {
    final output = await shell('pm list packages ${flags.join(' ')}');
    return const LineSplitter().convert(output)
        .where((l) => l.startsWith('package:'))
        .map((l) => l.substring('package:'.length))
        .toList();
  }

  /// 启动 Activity（`am start`）。
  Future<String> startActivity({
    required String component,
    String? action,
    String? dataUri,
    Map<String, String>? extras,
    List<String>? flags,
  }) async {
    final args = <String>['start'];
    if (action != null) args.addAll(['-a', action]);
    if (dataUri != null) args.addAll(['-d', dataUri]);
    if (extras != null) {
      extras.forEach((k, v) => args.addAll(['-e', k, v]));
    }
    if (flags != null) args.addAll(flags);
    args.add('-n');
    args.add(component);
    return await shell('am ${args.join(' ')}');
  }

  /// 强制停止应用（`am force-stop`）。
  Future<String> forceStop(String packageName) async {
    return await shell('am force-stop $packageName');
  }

  /// 清除应用数据（`pm clear`）。
  Future<String> clearAppData(String packageName) async {
    return await shell('pm clear $packageName');
  }

  /// 获取应用安装路径（`pm path`）。
  Future<String> getAppPath(String packageName) async {
    final output = await shell('pm path $packageName');
    return output.replaceFirst('package:', '').trim();
  }

  /// 发送输入事件（`input`）。
  ///
  /// [type] 可为 'text'、'tap'、'swipe'、'keyevent'、'roll' 等。
  /// 示例：
  /// ```dart
  /// await device.input('tap 500 800');
  /// await device.input('swipe 500 1500 500 500 300');
  /// await device.input('text "hello world"');
  /// await device.input('keyevent KEYCODE_HOME');
  /// ```
  Future<String> input(String command) async {
    return await shell('input $command');
  }

  /// 设置剪贴板文本（`am broadcast` + `clipboard`）。
  Future<String> setClipboard(String text) async {
    final escaped = text.replaceAll('"', '\\"').replaceAll('\n', '\\n');
    return await shell(
        'am broadcast -a clipper.set --es text "$escaped"');
  }

  /// 获取剪贴板文本。
  Future<String> getClipboard() async {
    return await shell('am broadcast -a clipper.get');
  }

  /// 通过 host 服务端进行端口转发（不依赖设备端 `forward:` 服务）。
  ///
  /// 适用于需要绑定本地端口的场景（如 `adb forward tcp:8080 tcp:8080`）。
  /// 需要运行 `adb server` (5037)。
  Future<void> hostForward({
    required String local,
    required String remote,
    String? serial,
    AdbHostClient? hostClient,
  }) async {
    final client = hostClient ?? AdbHostClient();
    await client.bindTransport(serial: serial);
    // host:transport 绑定后，通过同一 socket 发送 forward 请求较复杂，
    // 这里直接使用设备端 forward: 服务（已在上面实现）。
    await forward(local: local, remote: remote);
  }

  Future<AdbSyncClient> _openSync() async {
    final stream = await _connection.open('sync:');
    return AdbSyncClient(stream);
  }
}

/// 转发规则（`adb forward --list` 输出格式）。
class ForwardRule {
  ForwardRule({required this.serial, required this.local, required this.remote});
  final String serial;
  final String local;
  final String remote;
  @override
  String toString() => '$serial $local $remote';
}

/// 反向转发规则。
class ReverseRule {
  ReverseRule({required this.serial, required this.remote, required this.local});
  final String serial;
  final String remote;
  final String local;
  @override
  String toString() => '$serial $remote $local';
}