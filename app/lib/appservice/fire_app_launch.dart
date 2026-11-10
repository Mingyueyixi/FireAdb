import 'dart:convert';
import 'dart:typed_data';

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
/// [argument] 仅测试或调试用；正常路径不传。
String fireAppServiceCommand(String remotePath, {String? argument}) {
  final base =
      'CLASSPATH=$remotePath app_process -Djava.class.path=$remotePath '
      '/system/bin $fireAppServiceMainClass';
  if (argument == null || argument.isEmpty) return base;
  return '$base $argument';
}

Uint8List? _cachedJar;
String? _cachedJarVersion;
final _jarPushed = <String, String>{};

/// 把辅助服务 jar 推到设备。
///
/// 不要对可能不存在的 stamp 做 sync pull：经 SDK adb 时缺失文件会掐断
/// sync 流，随后 `readExactly(8)` 报「流已结束」。stamp 只用 **stat 大小**
/// 区分版本（内容按 version 号填充，保证 29→30 时长度变化）。
Future<void> ensureFireAppService(ConnectedDevice device) async {
  final jar = _cachedJar ??= await _loadFireAppJar();
  final version = _cachedJarVersion ??= await _loadFireAppJarVersion();
  final versionNumber = int.tryParse(version) ?? 0;
  final stamp = Uint8List.fromList(
    utf8.encode('fire-app-service:$version:${jar.length}:') +
        List<int>.filled(versionNumber, 0x2e),
  );
  final token = '${jar.length}:${stamp.length}';
  if (_jarPushed[device.serial] == token) return;
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
      return;
    }
    await sync.client.push(jar, fireAppServiceRemotePath);
    await sync.client.push(stamp, fireAppServiceRemoteVersionPath);
    try {
      await sync.client.quit();
    } catch (_) {}
    _jarPushed[device.serial] = token;
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
