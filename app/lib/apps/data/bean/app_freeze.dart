/// 应用冻结方式。效果与系统版本支持范围不同，由用户显式选择，互不自动回退。
enum AppFreezeMethod {
  /// `pm disable-user`：用户停用，应用无法启动。
  disableUser,

  /// `pm suspend`：暂停应用（对用户隐藏图标，数据保留）。
  suspend,

  /// `am freeze`：ActivityManager 冻结（Android 15+）。
  amFreeze,
}

extension AppFreezeMethodCommands on AppFreezeMethod {
  String get id => switch (this) {
    AppFreezeMethod.disableUser => 'disable-user',
    AppFreezeMethod.suspend => 'suspend',
    AppFreezeMethod.amFreeze => 'am-freeze',
  };

  static AppFreezeMethod fromId(String? id) {
    return AppFreezeMethod.values.firstWhere(
      (method) => method.id == id,
      orElse: () => AppFreezeMethod.disableUser,
    );
  }

  String freezeCommand(String packageName) {
    final pkg = quoteShellArg(packageName);
    return switch (this) {
      AppFreezeMethod.disableUser => 'pm disable-user $pkg',
      AppFreezeMethod.suspend => 'pm suspend $pkg',
      AppFreezeMethod.amFreeze => 'am freeze $pkg',
    };
  }

  String unfreezeCommand(String packageName) {
    final pkg = quoteShellArg(packageName);
    return switch (this) {
      AppFreezeMethod.disableUser => 'pm enable $pkg',
      AppFreezeMethod.suspend => 'pm unsuspend $pkg',
      AppFreezeMethod.amFreeze => 'am unfreeze $pkg',
    };
  }
}

String quoteShellArg(String value) => "'${value.replaceAll("'", "'\\''")}'";

/// 冻结后可能导致无法开机、没有桌面、无法通话或无法进入设置的包。
bool isCoreSystemPackage(String packageName) {
  return _coreSystemPackages.contains(packageName);
}

const _coreSystemPackages = <String>{
  'android',
  'com.android.systemui',
  'com.android.settings',
  'com.android.providers.settings',
  'com.android.phone',
  'com.android.server.telecom',
  'com.android.incallui',
  'com.android.providers.telephony',
  'com.android.bluetooth',
  'com.android.nfc',
  'com.android.shell',
  'com.android.packageinstaller',
  'com.google.android.packageinstaller',
  'com.android.permissioncontroller',
  'com.google.android.permissioncontroller',
  'com.android.networkstack',
  'com.android.networkstack.tethering',
  'com.android.providers.media',
  'com.android.providers.media.module',
  'com.google.android.providers.media.module',
  'com.android.externalstorage',
  'com.android.keychain',
  'com.android.inputdevices',
  'com.android.location.fused',
  'com.android.documentsui',
  'com.android.providers.downloads',
  'com.android.providers.contacts',
  'com.android.emergency',
  'com.android.cellbroadcastreceiver',
  'com.android.cellbroadcastservice',
  'com.android.mms.service',
  'com.android.stk',
  'com.android.carrierconfig',
  'com.android.se',
  'com.android.vpndialogs',
  'com.android.captiveportallogin',
  'com.android.launcher',
  'com.android.launcher2',
  'com.android.launcher3',
  'com.google.android.apps.nexuslauncher',
  'com.miui.home',
  'com.huawei.android.launcher',
  'com.sec.android.app.launcher',
  'com.oppo.launcher',
  'com.oplus.launcher',
  'com.coloros.launcher',
  'com.bbk.launcher2',
  'com.samsung.android.incallui',
};

/// 冻结/解冻命令成功时可能无输出，或为 Success / new suspended state。
void ensureFreezeCommandSuccess(String output) {
  final trimmed = output.trim();
  if (trimmed.isEmpty) return;
  final lower = trimmed.toLowerCase();
  if (RegExp(r'^Success\b', caseSensitive: false).hasMatch(trimmed)) return;
  if (lower.contains('new suspended state')) return;
  if (_isFreezeCommandFailure(lower)) {
    throw StateError(trimmed);
  }
}

bool _isFreezeCommandFailure(String lower) {
  return lower.startsWith('failure') ||
      lower.startsWith('error') ||
      lower.contains('unknown command') ||
      lower.contains('class not found') ||
      lower.contains('does not exist') ||
      lower.contains('cannot find') ||
      lower.contains('not a valid') ||
      (lower.contains('unknown') && lower.contains('freeze'));
}

final _packageNameInLine = RegExp(
  r'\b([a-zA-Z][\w]*\.(?:[a-zA-Z][\w]*\.)*[a-zA-Z][\w]*)\b',
);

/// 从 `dumpsys activity freezer` 一类输出中提取被 AM 冻结的包名。
Set<String> parseAmFrozenPackages(String output) {
  final names = <String>{};
  var inFrozenSection = false;
  for (final raw
      in output.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n')) {
    final line = raw.trim();
    final lower = line.toLowerCase();
    if (lower.contains('unfrozen') || lower.contains('unfreeze')) {
      inFrozenSection = false;
      continue;
    }
    if (lower.contains('frozen') || lower.contains('freeze')) {
      inFrozenSection = true;
      for (final match in _packageNameInLine.allMatches(line)) {
        names.add(match.group(1)!);
      }
      continue;
    }
    if (!inFrozenSection || line.isEmpty) {
      if (line.isEmpty) inFrozenSection = false;
      continue;
    }
    for (final match in _packageNameInLine.allMatches(line)) {
      names.add(match.group(1)!);
    }
  }
  return names;
}
