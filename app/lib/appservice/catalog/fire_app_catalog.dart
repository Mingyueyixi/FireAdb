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

/// 一次取回全部应用的包名、版本、标记、APK 路径和体积。不含名称和图标。
/// 服务进程会留给随后的外观查询，避免再启动一次。
Future<FireAppListLoad> loadFireAppSummaries(
  ConnectedDevice device, {
  FireAppListProgress? onCatalog,
}) {
  final session = fireAppSession(device);
  session.advanceEpoch();
  session.cancelIdle();
  return session.run(() async {
    try {
      return await _loadList(session, device, onCatalog);
    } catch (error) {
      // 重连后首轮偶发半截超时：丢掉死会话再拉一次。
      await session.drop();
      try {
        return await _loadList(session, device, onCatalog);
      } catch (_) {
        rethrow;
      }
    } finally {
      session.scheduleIdle();
    }
  });
}

/// 一批应用名。不含图标。
class FireAppName {
  const FireAppName({required this.packageName, required this.label});

  final String packageName;
  final String label;
}

/// 把 `catalog.names` 的 JSON 收成应用名。空包名跳过。
List<FireAppName> fireAppNamesFromJson(Map<String, dynamic> json) {
  final items = json['items'];
  if (items is! List) return const <FireAppName>[];
  return <FireAppName>[
    for (final raw in items)
      if (raw is Map)
        FireAppName(
          packageName: '${raw['package'] ?? ''}'.trim(),
          label: '${raw['label'] ?? ''}'.trim(),
        ),
  ].where((item) => item.packageName.isNotEmpty).toList();
}

/// 一次取回这些包的应用名。包名顺序与请求一致。超时不再重试。
Future<List<FireAppName>> loadFireAppNames(
  ConnectedDevice device,
  List<String> packages, {
  Duration timeout = const Duration(seconds: 60),
}) {
  if (packages.isEmpty) {
    return Future<List<FireAppName>>.value(const <FireAppName>[]);
  }
  final session = fireAppSession(device);
  final epoch = session.epoch;
  session.cancelIdle();
  return session.run(() async {
    try {
      if (epoch != session.epoch) throw const FireAppLoadCancelled();
      try {
        return await _loadNames(session, device, packages, timeout);
      } on FireAppLoadCancelled {
        rethrow;
      } on TimeoutException {
        rethrow;
      } catch (error) {
        await session.drop();
        if (epoch != session.epoch) throw const FireAppLoadCancelled();
        return await _loadNames(session, device, packages, timeout);
      }
    } finally {
      session.scheduleIdle();
    }
  });
}

/// 读取一个包的图标。空图返回空。失败不拆掉会话，避免挡住后面的图标。
Future<Uint8List?> loadFireAppIcon(ConnectedDevice device, String packageName) {
  final session = fireAppSession(device);
  final epoch = session.epoch;
  session.cancelIdle();
  return session.run(() async {
    try {
      if (epoch != session.epoch) throw const FireAppLoadCancelled();
      await session.ensureReady(device);
      final id = session.nextId();
      await session.send(
        FireDataRequest.json(
          name: 'catalog.icon',
          id: id,
          body: <String, String>{'package': packageName},
        ),
      );
      final message = await session.next().timeout(const Duration(seconds: 15));
      if (message.name == 'session.error') {
        throw StateError(message.errorText('读取应用图标失败'));
      }
      if (message.id != id || message.name != 'catalog.icon') {
        throw StateError('应用图标响应无效');
      }
      if (message.body.isEmpty) return null;
      return message.body;
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
) async {
  final timing = FireAppListTiming();
  final ready = await session.ensureReady(device);
  timing.jarMs = ready.jarMs;
  timing.readyMs = ready.readyMs;

  log.info('应用列表已发送 catalog.list（${device.serial}，就绪 ${timing.readyMs} ms）');
  final id = session.nextId();
  await session.send(FireDataRequest.none(name: 'catalog.list', id: id));

  final readClock = Stopwatch()..start();
  final FireDataResponse message;
  try {
    message = await session.next().timeout(const Duration(seconds: 15));
  } on TimeoutException {
    throw TimeoutException(
      '应用列表超过 15 秒没有返回（缓冲 ${session.pendingBytes} 字节）',
    );
  }
  if (message.name == 'session.error') {
    throw StateError(message.errorText('读取应用列表失败'));
  }
  if (message.id != id || message.name != 'catalog.apps') {
    throw StateError('应用列表响应无效');
  }
  final summaries = fireAppSummariesFromJson(message.json);
  timing.listMs = readClock.elapsedMilliseconds;
  timing.readMs = timing.listMs;
  onCatalog?.call(List<FireAppSummary>.of(summaries), timing);
  return FireAppListLoad(summaries: summaries, timing: timing);
}

List<FireAppSummary> fireAppSummariesFromJson(Map<String, dynamic> json) {
  final items = json['items'];
  if (items is! List) return const <FireAppSummary>[];
  return <FireAppSummary>[
    for (final item in items)
      if (item is Map) fireAppSummaryFromJson(Map<String, dynamic>.from(item)),
  ].where((item) => item.packageName.isNotEmpty).toList();
}

Future<List<FireAppName>> _loadNames(
  FireAppSession session,
  ConnectedDevice device,
  List<String> packages,
  Duration timeout,
) async {
  await session.ensureReady(device);
  final id = session.nextId();
  await session.send(
    FireDataRequest.json(
      name: 'catalog.names',
      id: id,
      body: <String, List<String>>{'packages': packages},
    ),
  );
  final message = await session.next().timeout(timeout);
  if (message.name == 'session.error') {
    throw StateError(message.errorText('读取应用名失败'));
  }
  if (message.id != id || message.name != 'catalog.names') {
    throw StateError('应用名响应无效');
  }
  return fireAppNamesFromJson(message.json);
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
