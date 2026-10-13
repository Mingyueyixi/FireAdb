import 'app_freeze.dart';

/// 设备上已安装应用的展示信息。
class InstalledApp {
  const InstalledApp({
    required this.packageName,
    this.label,
    this.versionName,
    this.versionCode,
    this.apkPaths = const <String>[],
    this.sizeBytes,
    this.isSystem = false,
    this.isDisabledUser = false,
    this.isSuspended = false,
    this.isAmFrozen = false,
    this.isDebuggable = false,
    this.dataDir,
    this.cacheDir,
    this.externalDir,
  });

  final String packageName;
  final String? label;
  final String? versionName;
  final int? versionCode;
  final List<String> apkPaths;
  final int? sizeBytes;
  final bool isSystem;
  final bool isDisabledUser;
  final bool isSuspended;
  final bool isAmFrozen;
  final bool isDebuggable;

  /// `/data/data` 或 `/data/user/0` 下的应用数据目录。
  final String? dataDir;

  /// 应用私有缓存目录。
  final String? cacheDir;

  /// SD 卡上的 `Android/data/包名` 目录。
  final String? externalDir;

  bool get isFrozen => isDisabledUser || isSuspended || isAmFrozen;

  /// 桌面、系统界面、设置、电话等，冻结后设备可能无法正常使用。
  bool get isCoreSystem => isCoreSystemPackage(packageName);

  Set<AppFreezeMethod> get activeFreezeMethods => {
    if (isDisabledUser) AppFreezeMethod.disableUser,
    if (isSuspended) AppFreezeMethod.suspend,
    if (isAmFrozen) AppFreezeMethod.amFreeze,
  };

  String get displayName {
    final name = label?.trim();
    if (name != null && name.isNotEmpty) return name;
    return packageName;
  }

  /// `versionName/versionCode`。缺一边时只保留有的那一边。
  String get versionLabel {
    final name = versionName?.trim() ?? '';
    final code = versionCode;
    if (name.isNotEmpty && code != null) return '$name/$code';
    if (name.isNotEmpty) return name;
    if (code != null) return '$code';
    return '';
  }

  String? get primaryPath {
    if (apkPaths.isEmpty) return null;
    for (final path in apkPaths) {
      if (path.endsWith('base.apk') || path.endsWith('.apk')) return path;
    }
    return apkPaths.first;
  }

  InstalledApp merge(InstalledApp other) {
    return InstalledApp(
      packageName: packageName,
      label: _prefer(other.label, label),
      versionName: _prefer(other.versionName, versionName),
      versionCode: other.versionCode ?? versionCode,
      apkPaths: _mergePaths(apkPaths, other.apkPaths),
      sizeBytes: other.sizeBytes ?? sizeBytes,
      isSystem: isSystem || other.isSystem,
      isDisabledUser: isDisabledUser || other.isDisabledUser,
      isSuspended: isSuspended || other.isSuspended,
      isAmFrozen: isAmFrozen || other.isAmFrozen,
      isDebuggable: isDebuggable || other.isDebuggable,
      dataDir: _prefer(other.dataDir, dataDir),
      cacheDir: _prefer(other.cacheDir, cacheDir),
      externalDir: _prefer(other.externalDir, externalDir),
    );
  }

  InstalledApp copyWith({
    String? label,
    String? versionName,
    int? versionCode,
    List<String>? apkPaths,
    int? sizeBytes,
    bool? isSystem,
    bool? isDisabledUser,
    bool? isSuspended,
    bool? isAmFrozen,
    bool? isDebuggable,
    String? dataDir,
    String? cacheDir,
    String? externalDir,
  }) {
    return InstalledApp(
      packageName: packageName,
      label: label ?? this.label,
      versionName: versionName ?? this.versionName,
      versionCode: versionCode ?? this.versionCode,
      apkPaths: apkPaths ?? this.apkPaths,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      isSystem: isSystem ?? this.isSystem,
      isDisabledUser: isDisabledUser ?? this.isDisabledUser,
      isSuspended: isSuspended ?? this.isSuspended,
      isAmFrozen: isAmFrozen ?? this.isAmFrozen,
      isDebuggable: isDebuggable ?? this.isDebuggable,
      dataDir: dataDir ?? this.dataDir,
      cacheDir: cacheDir ?? this.cacheDir,
      externalDir: externalDir ?? this.externalDir,
    );
  }

  static String? _prefer(String? first, String? second) {
    if (first != null && first.trim().isNotEmpty) return first;
    if (second != null && second.trim().isNotEmpty) return second;
    return null;
  }

  static List<String> _mergePaths(List<String> a, List<String> b) {
    final seen = <String>{};
    final result = <String>[];
    for (final path in [...a, ...b]) {
      final trimmed = path.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) continue;
      result.add(trimmed);
    }
    return result;
  }
}

enum AppListFilter { user, system, debug, frozen, all }

/// 一批应用里最高的系统风险。有核心组件时优先于普通系统应用。
enum SystemAppRisk { none, system, core }

SystemAppRisk systemAppRisk(Iterable<InstalledApp> apps) {
  var risk = SystemAppRisk.none;
  for (final app in apps) {
    if (app.isCoreSystem) return SystemAppRisk.core;
    if (app.isSystem) risk = SystemAppRisk.system;
  }
  return risk;
}
