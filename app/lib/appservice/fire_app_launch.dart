import 'dart:convert';

import 'package:flutter/services.dart';

import '../connection/model/connected_device.dart';

/// 手机上的 jar 路径。录屏入口也在这一份 jar 里。
const String fireAppServiceRemotePath = '/data/local/tmp/fire-app-service.jar';

/// 与 jar 一并推送，避免只比文件大小时漏掉同长度的新构建。
const String fireAppServiceRemoteVersionPath =
    '/data/local/tmp/fire-app-service.version';

/// `app_process` 入口。
const String fireAppServiceMainClass = 'com.fire.adb.appservice.FireAppService';

/// 启动应用信息服务。标准输入输出是 `name type id length:` 消息。
///
/// [argument] 仅测试或调试用；正常路径不传。录屏和一次性查询用这条，进程跟随着这次执行。
String fireAppServiceCommand(String remotePath, {String? argument}) {
  final base =
      'CLASSPATH=$remotePath app_process -Djava.class.path=$remotePath '
      '/system/bin $fireAppServiceMainClass';
  if (argument == null || argument.isEmpty) return base;
  return '$base $argument';
}

/// 把常驻服务放进新会话并立刻回到 shell。adb 连接断开时不再把它一起杀掉。
String fireAppServiceDaemonCommand(
  String remotePath, {
  required String argument,
}) {
  final inner = fireAppServiceCommand(remotePath, argument: argument);
  final quoted = inner.replaceAll("'", r"'\''");
  return 'if command -v setsid >/dev/null 2>&1; then '
      'setsid sh -c \'$quoted </dev/null >/dev/null 2>&1\' >/dev/null 2>&1 & '
      'else trap \'\' HUP; '
      'sh -c \'$quoted </dev/null >/dev/null 2>&1\' >/dev/null 2>&1 & fi';
}

Uint8List? _cachedJar;
String? _cachedJarVersion;
final _jarPushed = <String, String>{};

/// 把辅助服务 jar 推到设备。返回是否写下了新的 jar。
///
/// 不要对可能不存在的 stamp 做 sync pull：经 SDK adb 时缺失文件会掐断
/// sync 流，随后 `readExactly(8)` 报「流已结束」。stamp 只用 **stat 大小**
/// 区分版本（内容按 version 号填充，保证 29→30 时长度变化）。
Future<bool> ensureFireAppService(ConnectedDevice device) async {
  final jar = _cachedJar ??= await _loadFireAppJar();
  final version = _cachedJarVersion ??= await _loadFireAppJarVersion();
  final versionNumber = int.tryParse(version) ?? 0;
  final stamp = Uint8List.fromList(
    utf8.encode('fire-app-service:$version:${jar.length}:') +
        List<int>.filled(versionNumber, 0x2e),
  );
  final token = '${jar.length}:${stamp.length}';
  if (_jarPushed[device.serial] == token) return false;
  final sync = await device.openSync();
  try {
    final jarStat = await sync.client.stat(fireAppServiceRemotePath);
    final stampStat = await sync.client.stat(fireAppServiceRemoteVersionPath);
    if (jarStat.mode != 0 &&
        jarStat.size == jar.length &&
        stampStat.mode != 0 &&
        stampStat.size == stamp.length) {
      try {
        await sync.client.quit();
      } catch (_) {}
      _jarPushed[device.serial] = token;
      return false;
    }
    await sync.client.push(jar, fireAppServiceRemotePath);
    await sync.client.push(stamp, fireAppServiceRemoteVersionPath);
    try {
      await sync.client.quit();
    } catch (_) {}
    _jarPushed[device.serial] = token;
    return true;
  } finally {
    await sync.close();
  }
}

Future<Uint8List> _loadFireAppJar() async {
  final data = await rootBundle.load('assets/fire-app-service.jar');
  return Uint8List.fromList(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  );
}

Future<String> _loadFireAppJarVersion() async {
  try {
    return (await rootBundle.loadString(
      'assets/fire-app-service.version',
    )).trim();
  } catch (_) {
    return '0';
  }
}
