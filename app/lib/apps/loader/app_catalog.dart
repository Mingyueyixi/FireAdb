import '../../app_feedback.dart';
import '../data/bean/installed_app.dart';
import '../data/repo/device_app_repository.dart';

/// 首屏之后补上的系统应用、停用标记和 AM 冻结。
class AppCatalog {
  final Set<String> _system = <String>{};
  final Set<String> _disabled = <String>{};
  final Set<String> _amFrozen = <String>{};
  final Map<String, List<String>> _paths = <String, List<String>>{};

  void clear() {
    _system.clear();
    _disabled.clear();
    _amFrozen.clear();
    _paths.clear();
  }

  /// 读到标记时返回 true，调用方再刷新一次列表。
  Future<bool> load(DeviceAppRepository repo, {required String serial}) async {
    final flagsFuture = _flags(repo, serial);
    final frozenFuture = _frozen(repo, serial);
    final flags = await flagsFuture;
    final frozen = await frozenFuture;
    if (flags == null && frozen.isEmpty) return false;
    if (flags != null) {
      _system
        ..clear()
        ..addAll(flags.systemPackages);
      _disabled
        ..clear()
        ..addAll(flags.disabledPackages);
      _paths.addAll(flags.systemPaths);
    }
    _amFrozen
      ..clear()
      ..addAll(frozen);
    return true;
  }

  List<InstalledApp> merge(
    Iterable<InstalledApp> apps, {
    required bool resort,
  }) {
    final byName = <String, InstalledApp>{
      for (final app in apps) app.packageName: app,
    };
    for (final name in _system) {
      byName.putIfAbsent(name, () => InstalledApp(packageName: name));
    }
    final next = <InstalledApp>[for (final app in byName.values) _apply(app)];
    if (resort) {
      next.sort(
        (a, b) =>
            a.packageName.toLowerCase().compareTo(b.packageName.toLowerCase()),
      );
    }
    return next;
  }

  InstalledApp _apply(InstalledApp app) {
    final paths = _paths[app.packageName];
    return app.copyWith(
      isSystem: app.isSystem || _system.contains(app.packageName),
      isDisabledUser: app.isDisabledUser || _disabled.contains(app.packageName),
      isAmFrozen: app.isAmFrozen || _amFrozen.contains(app.packageName),
      apkPaths: paths == null || paths.isEmpty ? null : paths,
    );
  }

  Future<
    ({
      Set<String> systemPackages,
      Map<String, List<String>> systemPaths,
      Set<String> disabledPackages,
    })?
  >
  _flags(DeviceAppRepository repo, String serial) async {
    try {
      return await repo.loadPackageFlags();
    } catch (error, stackTrace) {
      logAppError('读取应用标记失败：$serial', error, stackTrace);
      return null;
    }
  }

  Future<Set<String>> _frozen(DeviceAppRepository repo, String serial) async {
    try {
      return await repo.listAmFrozenPackages();
    } catch (error, stackTrace) {
      logAppError('读取 AM 冻结列表失败：$serial', error, stackTrace);
      return const <String>{};
    }
  }
}
