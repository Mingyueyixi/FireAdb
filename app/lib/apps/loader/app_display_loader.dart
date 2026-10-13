import 'dart:async';
import 'dart:typed_data';

import '../../common/object_loader.dart';
import '../../connection/model/connected_device.dart';
import '../../log/app_log.dart';
import '../data/bean/installed_app.dart';
import '../data/repo/device_app_repository.dart';
import '../data/source/fire_app_service.dart';

/// 图标和体积在行显示出来之后再取。名称、版本和 Debug 标记来自列表。
class AppDisplay {
  const AppDisplay({
    required this.label,
    required this.versionName,
    required this.versionCode,
    required this.png,
    required this.sizeBytes,
    required this.isSystem,
    required this.isDisabledUser,
    required this.isSuspended,
    required this.isDebuggable,
    this.dataDir,
    this.cacheDir,
    this.externalDir,
  });

  final String label;
  final String versionName;
  final int? versionCode;
  final Uint8List? png;
  final int? sizeBytes;
  final bool isSystem;
  final bool isDisabledUser;
  final bool isSuspended;
  final bool isDebuggable;
  final String? dataDir;
  final String? cacheDir;
  final String? externalDir;
}

InstalledApp applyAppSummary(InstalledApp app, FireAppSummary summary) {
  final label = summary.label.trim();
  final versionName = summary.versionName.trim();
  return app.copyWith(
    label: label.isEmpty ? null : label,
    versionName: versionName.isEmpty ? null : versionName,
    versionCode: summary.versionCode,
    isSystem: app.isSystem || summary.isSystem,
    isDisabledUser: app.isDisabledUser || summary.isDisabledUser,
    isSuspended: app.isSuspended || summary.isSuspended,
    isDebuggable: summary.isDebuggable,
    apkPaths: summary.apkPaths,
    sizeBytes: summary.sizeBytes ?? app.sizeBytes,
  );
}

InstalledApp installedAppFromSummary(FireAppSummary summary) {
  return applyAppSummary(
    InstalledApp(packageName: summary.packageName),
    summary,
  );
}

InstalledApp applyAppDisplay(InstalledApp app, AppDisplay details) {
  final label = details.label.trim();
  final versionName = details.versionName.trim();
  return app.copyWith(
    label: label.isEmpty ? null : label,
    versionName: versionName.isEmpty ? null : versionName,
    versionCode: details.versionCode,
    sizeBytes: details.sizeBytes,
    isSystem: app.isSystem || details.isSystem,
    isDisabledUser: app.isDisabledUser || details.isDisabledUser,
    isSuspended: app.isSuspended || details.isSuspended,
    isDebuggable: app.isDebuggable || details.isDebuggable,
    dataDir: details.dataDir,
    cacheDir: details.cacheDir,
    externalDir: details.externalDir,
  );
}

/// 一个加载器负责可见行的详情。这一批全部结束后通知一次。
class AppDisplayLoader {
  AppDisplayLoader({
    required void Function() onUpdated,
    required this.deviceOf,
    required this.repositoryOf,
    required this.appOf,
  }) {
    _items = ObjectLoader<String, AppDisplay>(
      load: _load,
      onUpdated: onUpdated,
    );
  }

  final ConnectedDevice? Function() deviceOf;
  final DeviceAppRepository? Function() repositoryOf;
  final InstalledApp? Function(String packageName) appOf;

  late final ObjectLoader<String, AppDisplay> _items;
  var _generation = 0;

  AppDisplay? operator [](String packageName) => _items[packageName];

  Uint8List? iconOf(String packageName) {
    final png = _items[packageName]?.png;
    if (png == null || png.isEmpty) return null;
    return png;
  }

  void ensure(InstalledApp app) {
    final path = app.primaryPath;
    if (deviceOf() == null && (path == null || path.isEmpty)) return;
    _items.ensure(app.packageName);
  }

  void reset() {
    _generation++;
    _items.clear();
  }

  void dispose() {
    _generation++;
    _items.dispose();
  }

  Future<AppDisplay?> _load(String packageName) async {
    final current = appOf(packageName);
    final path = current?.primaryPath;
    final showFuture = _loadShow(packageName);
    final sizeFuture =
        current?.sizeBytes != null || path == null || path.isEmpty
        ? Future<int?>.value()
        : _loadSize(packageName, path);
    final show = await showFuture;
    final size = await sizeFuture;
    if (show == null && size == null) return null;
    return AppDisplay(
      label: show?.label ?? '',
      versionName: show?.versionName ?? '',
      versionCode: show?.versionCode,
      png: show?.png,
      sizeBytes: size,
      isSystem: show?.isSystem ?? false,
      isDisabledUser: show?.isDisabledUser ?? false,
      isSuspended: show?.isSuspended ?? false,
      isDebuggable: show?.isDebuggable ?? false,
      dataDir: _directory(show?.dataDir),
      cacheDir: _directory(show?.cacheDir),
      externalDir: _directory(show?.externalDir),
    );
  }

  String? _directory(String? path) {
    final value = path?.trim();
    if (value == null || value.isEmpty) return null;
    return value;
  }

  Future<FireAppShow?> _loadShow(String packageName) async {
    final device = deviceOf();
    final generation = _generation;
    if (device == null) return null;
    try {
      final shown = await loadFireAppShow(device, packageName);
      if (generation != _generation) return null;
      return shown;
    } on FireAppLoadCancelled {
      return null;
    } on TimeoutException catch (error, stackTrace) {
      log.severe('读取应用信息超时：$packageName', error, stackTrace);
      return null;
    } catch (error, stackTrace) {
      log.severe('读取应用信息失败：$packageName', error, stackTrace);
      return null;
    }
  }

  Future<int?> _loadSize(String packageName, String path) async {
    final repo = repositoryOf();
    if (repo == null) return null;
    try {
      final sized = await repo.loadPackageSizes(<InstalledApp>[
        InstalledApp(packageName: packageName, apkPaths: <String>[path]),
      ]);
      for (final app in sized) {
        if (app.packageName == packageName) return app.sizeBytes;
      }
      return null;
    } catch (error, stackTrace) {
      log.severe('读取应用体积失败：$packageName', error, stackTrace);
      return null;
    }
  }
}
