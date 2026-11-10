import 'dart:async';
import 'dart:typed_data';

import '../../connection/model/connected_device.dart';
import '../../log/app_log.dart';
import '../fire_app_session.dart';
import '../protocol/fire_app_message.dart';

/// 列表阶段一次取回的应用信息，不含图标和目录。
class FireAppSummary {
  FireAppSummary({
    required this.packageName,
    required this.label,
    required this.versionName,
    required this.versionCode,
    required this.isSystem,
    required this.isDisabledUser,
    required this.isSuspended,
    required this.isDebuggable,
    this.apkPaths = const <String>[],
    this.sizeBytes,
  });

  final String packageName;
  final String label;
  final String versionName;
  final int? versionCode;
  final bool isSystem;
  final bool isDisabledUser;
  final bool isSuspended;
  final bool isDebuggable;
  final List<String> apkPaths;
  final int? sizeBytes;

  FireAppSummary withLabel(String label) {
    return FireAppSummary(
      packageName: packageName,
      label: label,
      versionName: versionName,
      versionCode: versionCode,
      isSystem: isSystem,
      isDisabledUser: isDisabledUser,
      isSuspended: isSuspended,
      isDebuggable: isDebuggable,
      apkPaths: apkPaths,
      sizeBytes: sizeBytes,
    );
  }
}

/// 列表读取各段耗时。［读取］不含把结果画到界面上的时间。
class FireAppListTiming {
  var jarMs = 0;
  var readyMs = 0;
  var listMs = 0;
  var nameMs = 0;
  var readMs = 0;
}

/// 刷新列表时，还在排队的单条查询会被丢掉。
class FireAppLoadCancelled implements Exception {
  const FireAppLoadCancelled();
}

class FireAppShow {
  FireAppShow({
    required this.packageName,
    required this.label,
    required this.versionName,
    required this.versionCode,
    required this.isSystem,
    required this.isDisabledUser,
    required this.isSuspended,
    required this.isDebuggable,
    required this.png,
    required this.dataDir,
    required this.cacheDir,
    required this.externalDir,
  });

  final String packageName;
  final String label;
  final String versionName;
  final int? versionCode;
  final bool isSystem;
  final bool isDisabledUser;
  final bool isSuspended;
  final bool isDebuggable;
  final Uint8List? png;
  final String dataDir;
  final String cacheDir;
  final String externalDir;
}

/// 把 `catalog.app` 的 JSON 收成列表项。没有版本号、体积不大于 0 时记为空。
FireAppSummary fireAppSummaryFromJson(Map<String, dynamic> json) {
  final code = json['versionCode'];
  final size = json['size'];
  final apk = json['apk'];
  return FireAppSummary(
    packageName: '${json['package'] ?? ''}',
    label: '${json['label'] ?? ''}',
    versionName: '${json['versionName'] ?? ''}',
    versionCode: code is num && code >= 0 ? code.toInt() : null,
    isSystem: json['system'] == true,
    isDisabledUser: json['disabled'] == true,
    isSuspended: json['suspended'] == true,
    isDebuggable: json['debuggable'] == true,
    apkPaths: <String>[
      if (apk is List)
        for (final path in apk)
          if ('$path'.trim().isNotEmpty) '$path'.trim(),
    ],
    sizeBytes: size is num && size > 0 ? size.toInt() : null,
  );
}

/// 把 `catalog.show` 的 JSON 和图标字节收成详情。空图标记为空。
FireAppShow fireAppShowFromJson(Map<String, dynamic> json, {Uint8List? png}) {
  final summary = fireAppSummaryFromJson(json);
  return FireAppShow(
    packageName: summary.packageName,
    label: summary.label,
    versionName: summary.versionName,
    versionCode: summary.versionCode,
    isSystem: summary.isSystem,
    isDisabledUser: summary.isDisabledUser,
    isSuspended: summary.isSuspended,
    isDebuggable: summary.isDebuggable,
    png: png == null || png.isEmpty ? null : png,
    dataDir: '${json['dataDir'] ?? ''}',
    cacheDir: '${json['cacheDir'] ?? ''}',
    externalDir: '${json['externalDir'] ?? ''}',
  );
}

typedef FireAppListProgress = void Function(
  List<FireAppSummary> items,
  FireAppListTiming timing,
);

class FireAppListLoad {
  const FireAppListLoad({required this.summaries, required this.timing});

  final List<FireAppSummary> summaries;
  final FireAppListTiming timing;
}

/// 一次取回全部应用的名称、版本、标记、APK 路径和体积。
/// 服务进程会留给随后的图标查询，避免再启动一次。
Future<FireAppListLoad> loadFireAppSummaries(
  ConnectedDevice device, {
  FireAppListProgress? onCatalog,
  FireAppListProgress? onNames,
}) {
  final session = fireAppSession(device);
  session.advanceEpoch();
  session.cancelIdle();
  return session.run(() async {
    try {
      return await _loadList(session, device, onCatalog, onNames);
    } catch (error) {
      // 重连后首轮偶发半截超时：丢掉死会话再拉一次。
      await session.drop();
      try {
        return await _loadList(session, device, onCatalog, onNames);
      } catch (_) {
        rethrow;
      }
    } finally {
      session.scheduleIdle();
    }
  });
}

/// 同一台设备上的图标查询走已经打开的服务进程。
Future<FireAppShow> loadFireAppShow(
  ConnectedDevice device,
  String packageName,
) {
  final session = fireAppSession(device);
  final epoch = session.epoch;
  session.cancelIdle();
  return session.run(() async {
    try {
      if (epoch != session.epoch) throw const FireAppLoadCancelled();
      try {
        return await _loadShow(session, device, packageName);
      } catch (error) {
        if (error is FireAppLoadCancelled) rethrow;
        await session.drop();
        if (epoch != session.epoch) throw const FireAppLoadCancelled();
        return await _loadShow(session, device, packageName);
      }
    } finally {
      session.scheduleIdle();
    }
  });
}

Future<FireAppListLoad> _loadList(
  FireAppSession session,
  ConnectedDevice device,
  FireAppListProgress? onCatalog,
  FireAppListProgress? onNames,
) async {
  final timing = FireAppListTiming();
  final ready = await session.ensureReady(device);
  timing.jarMs = ready.jarMs;
  timing.readyMs = ready.readyMs;

  log.info('应用列表已发送 catalog.list（${device.serial}，就绪 ${timing.readyMs} ms）');
  final id = session.nextId();
  await session.send(FireDataRequest.none(name: 'catalog.list', id: id));

  final readClock = Stopwatch()..start();
  final summaries = <FireAppSummary>[];
  final seen = <String>{};
  final labels = <String, String>{};
  var catalogSent = false;

  void sendCatalog() {
    if (catalogSent) return;
    catalogSent = true;
    timing.listMs = readClock.elapsedMilliseconds;
    timing.readMs = timing.listMs;
    onCatalog?.call(List<FireAppSummary>.of(summaries), timing);
  }

  List<FireAppSummary> withNames() {
    if (labels.isEmpty) return List<FireAppSummary>.of(summaries);
    return <FireAppSummary>[
      for (final item in summaries)
        switch (labels[item.packageName]) {
          final name? => item.withLabel(name),
          _ => item,
        },
    ];
  }

  void sendNames() {
    if (labels.isEmpty) return;
    timing.readMs = readClock.elapsedMilliseconds;
    timing.nameMs = timing.readMs - timing.listMs;
    onNames?.call(withNames(), timing);
  }

  while (true) {
    final FireDataResponse message;
    try {
      message = await session.next().timeout(const Duration(seconds: 5));
    } on TimeoutException {
      final phase = catalogSent ? '名称' : '目录';
      throw TimeoutException(
        '应用列表$phase阶段超过 5 秒无数据'
        '（已收 ${summaries.length} 包名、${labels.length} 名称，'
        '缓冲 ${session.pendingBytes} 字节）',
      );
    } on StateError catch (error) {
      if (summaries.isEmpty || !'$error'.contains('应用信息服务已结束')) {
        rethrow;
      }
      log.warning('应用列表提前结束，已收到 ${summaries.length} 个', error);
      sendCatalog();
      final named = withNames();
      if (labels.isNotEmpty) sendNames();
      timing.readMs = readClock.elapsedMilliseconds;
      return FireAppListLoad(summaries: named, timing: timing);
    }
    if (message.name == 'session.error') {
      throw StateError(message.errorText('读取应用列表失败'));
    }
    if (message.id != id) throw StateError('应用列表响应无效');
    if (message.name == 'catalog.app') {
      final summary = fireAppSummaryFromJson(message.json);
      if (!seen.add(summary.packageName)) {
        if (!catalogSent) sendCatalog();
        final name = summary.label.trim();
        if (name.isNotEmpty && name != summary.packageName) {
          labels[summary.packageName] = name;
        }
      } else {
        summaries.add(summary);
      }
      continue;
    }
    if (message.name == 'session.done') {
      if (!catalogSent) sendCatalog();
      final named = withNames();
      sendNames();
      timing.readMs = readClock.elapsedMilliseconds;
      return FireAppListLoad(summaries: named, timing: timing);
    }
  }
}

Future<FireAppShow> _loadShow(
  FireAppSession session,
  ConnectedDevice device,
  String packageName,
) async {
  await session.ensureReady(device);
  final id = session.nextId();
  await session.send(
    FireDataRequest.json(
      name: 'catalog.show',
      id: id,
      body: <String, String>{'package': packageName},
    ),
  );
  Map<String, dynamic>? json;
  Uint8List? png;
  var gotIcon = false;
  while (json == null || !gotIcon) {
    final message = await session.next().timeout(const Duration(seconds: 20));
    if (message.name == 'session.error') {
      throw StateError(message.errorText('读取应用信息失败'));
    }
    if (message.id != id) throw StateError('应用信息响应无效');
    if (message.name == 'catalog.show') {
      json = message.json;
    } else if (message.name == 'catalog.icon') {
      gotIcon = true;
      png = message.body;
    }
  }
  return fireAppShowFromJson(json, png: png);
}
