import 'dart:async';
import 'dart:typed_data';

import '../../app_feedback.dart';
import '../../common/object_loader.dart';
import '../../connection/model/connected_device.dart';
import '../data/bean/installed_app.dart';
import '../data/repo/device_app_repository.dart';
import '../data/source/fire_app_service.dart';

/// 一行显示出来之后才取的名称、图标、版本和体积。
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
  });

  final String label;
  final String versionName;
  final int? versionCode;
  final Uint8List? png;
  final int? sizeBytes;
  final bool isSystem;
  final bool isDisabledUser;
  final bool isSuspended;
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
  FireAppServiceSession? _service;
  var _generation = 0;

  AppDisplay? operator [](String packageName) => _items[packageName];

  Uint8List? iconOf(String packageName) {
    final png = _items[packageName]?.png;
    if (png == null || png.isEmpty) return null;
    return png;
  }

  void ensure(InstalledApp app) {
    final path = app.primaryPath;
    if (_service == null && (path == null || path.isEmpty)) return;
    _items.ensure(app.packageName);
  }

  void reset() {
    _generation++;
    _items.clear();
    final previous = _service;
    _service = null;
    if (previous != null) unawaited(previous.close());
  }

  void open() {
    final device = deviceOf();
    if (device == null) return;
    final service = FireAppServiceSession(device);
    _service = service;
    unawaited(_start(service, device.serial));
  }

  void dispose() {
    _generation++;
    _items.dispose();
    final service = _service;
    _service = null;
    if (service != null) unawaited(service.close());
  }

  Future<void> _start(FireAppServiceSession service, String serial) async {
    try {
      await service.start();
    } catch (error, stackTrace) {
      logAppError('启动应用信息服务失败：$serial', error, stackTrace);
      if (identical(_service, service)) _service = null;
      await service.close();
    }
  }

  Future<AppDisplay?> _load(String packageName) async {
    final path = appOf(packageName)?.primaryPath;
    final showFuture = _loadShow(packageName);
    final sizeFuture = path == null || path.isEmpty
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
    );
  }

  Future<FireAppShow?> _loadShow(String packageName) async {
    final service = _service;
    final generation = _generation;
    if (service == null) return null;
    try {
      final shown = await service.loadShow(packageName);
      if (generation != _generation) return null;
      return shown;
    } on TimeoutException catch (error, stackTrace) {
      logAppError('读取应用信息超时：$packageName', error, stackTrace);
      if (identical(_service, service)) _service = null;
      await service.close();
      return null;
    } catch (error, stackTrace) {
      logAppError('读取应用信息失败：$packageName', error, stackTrace);
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
      logAppError('读取应用体积失败：$packageName', error, stackTrace);
      return null;
    }
  }
}
