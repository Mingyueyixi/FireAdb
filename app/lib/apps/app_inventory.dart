import 'installed_app.dart';

final _packageHeader = RegExp(r'^\s{2}Package \[([^\]]+)\]');
final _userZero = RegExp(r'^\s+User 0:');
final _enabledValue = RegExp(r'\benabled=([0-9A-Za-z_]+)');
final _suspendedValue = RegExp(r'\bsuspended=([A-Za-z]+)');
final _userFrozenValue = RegExp(r'\bfrozen=([A-Za-z]+)');
final _iconEntry = RegExp(
  r'(?:^|\s)((?:res|assets)/[^\s]+\.(?:png|webp))$',
  caseSensitive: false,
);

/// 解析 `pm list packages` / `pm list packages -f` 输出。
Map<String, InstalledApp> parsePmListPackages(
  String output, {
  bool withPath = false,
}) {
  final apps = <String, InstalledApp>{};
  for (final raw in const LineSplitterCompat().convert(output)) {
    final line = raw.trim();
    if (!line.startsWith('package:')) continue;
    final rest = line.substring('package:'.length);
    String packageName;
    String? path;
    if (withPath) {
      final eq = rest.lastIndexOf('=');
      if (eq > 0) {
        path = rest.substring(0, eq);
        packageName = rest.substring(eq + 1);
      } else {
        packageName = rest;
      }
    } else {
      packageName = rest.contains(' ') ? rest.split(' ').first : rest;
    }
    if (packageName.isEmpty) continue;
    apps[packageName] = InstalledApp(
      packageName: packageName,
      apkPaths: path == null || path.isEmpty
          ? const <String>[]
          : <String>[path],
    );
  }
  return apps;
}

/// 解析 `pm path <pkg>` 输出为 APK 路径列表。
List<String> parsePmPath(String output) {
  final paths = <String>[];
  for (final raw in const LineSplitterCompat().convert(output)) {
    final line = raw.trim();
    if (!line.startsWith('package:')) continue;
    final path = line.substring('package:'.length).trim();
    if (path.isNotEmpty) paths.add(path);
  }
  return paths;
}

/// 解析 `dumpsys package` 中的包信息，补全版本、系统标记、冻结状态等。
Map<String, InstalledApp> parseDumpsysPackages(String output) {
  final apps = <String, InstalledApp>{};
  String? current;
  String? versionName;
  int? versionCode;
  String? codePath;
  String? label;
  var isSystem = false;
  var isDisabledUser = false;
  var isSuspended = false;
  var isAmFrozen = false;

  void flush() {
    final pkg = current;
    if (pkg == null) return;
    final resolvedPath = codePath;
    apps[pkg] = InstalledApp(
      packageName: pkg,
      label: label,
      versionName: versionName,
      versionCode: versionCode,
      apkPaths: resolvedPath == null
          ? const <String>[]
          : <String>[resolvedPath],
      isSystem: isSystem,
      isDisabledUser: isDisabledUser,
      isSuspended: isSuspended,
      isAmFrozen: isAmFrozen,
    );
    current = null;
    versionName = null;
    versionCode = null;
    codePath = null;
    label = null;
    isSystem = false;
    isDisabledUser = false;
    isSuspended = false;
    isAmFrozen = false;
  }

  for (final raw in const LineSplitterCompat().convert(output)) {
    final header = _packageHeader.firstMatch(raw);
    if (header != null) {
      flush();
      current = header.group(1);
      continue;
    }
    if (current == null) continue;
    final line = raw.trim();
    if (line.startsWith('versionName=')) {
      versionName = line.substring('versionName='.length).trim();
    } else if (line.startsWith('versionCode=')) {
      final first = line
          .substring('versionCode='.length)
          .split(RegExp(r'\s+'))
          .first;
      versionCode = int.tryParse(first);
    } else if (line.startsWith('codePath=')) {
      codePath = line.substring('codePath='.length).trim();
    } else if (line.startsWith('applicationLabel=') ||
        line.startsWith('appName=')) {
      label = line.substring(line.indexOf('=') + 1).trim();
    } else if (line.startsWith('flags=') || line.startsWith('pkgFlags=')) {
      if (RegExp(r'\bSYSTEM\b').hasMatch(line)) isSystem = true;
    } else if (_userZero.hasMatch(raw)) {
      final enabled = _enabledValue.firstMatch(line)?.group(1);
      isDisabledUser = _isFrozenEnabledState(enabled);
      isSuspended = _isTrueFlag(_suspendedValue.firstMatch(line)?.group(1));
      isAmFrozen = _isTrueFlag(_userFrozenValue.firstMatch(line)?.group(1));
    }
  }
  flush();
  return apps;
}

bool _isTrueFlag(String? value) {
  if (value == null) return false;
  final lower = value.toLowerCase();
  return lower == 'true' || lower == '1';
}

bool _isFrozenEnabledState(String? value) {
  if (value == null) return false;
  switch (value) {
    case '2':
    case '3':
    case 'false':
    case 'COMPONENT_ENABLED_STATE_DISABLED':
    case 'COMPONENT_ENABLED_STATE_DISABLED_USER':
      return true;
    default:
      return false;
  }
}

/// 合并 `pm list` 与 dumpsys 结果。
List<InstalledApp> mergeInstalledApps({
  required Map<String, InstalledApp> listed,
  Map<String, InstalledApp> systemPackages = const <String, InstalledApp>{},
  Map<String, InstalledApp> disabledPackages = const <String, InstalledApp>{},
  Map<String, InstalledApp> dumpsys = const <String, InstalledApp>{},
  Set<String> amFrozenPackages = const <String>{},
}) {
  final names = <String>{...listed.keys, ...dumpsys.keys, ...amFrozenPackages};
  final result = <InstalledApp>[];
  for (final name in names) {
    var app = listed[name] ?? InstalledApp(packageName: name);
    final dump = dumpsys[name];
    if (dump != null) app = app.merge(dump);
    if (systemPackages.containsKey(name)) {
      app = app.copyWith(isSystem: true);
    }
    if (disabledPackages.containsKey(name)) {
      app = app.copyWith(isDisabledUser: true);
    }
    if (amFrozenPackages.contains(name)) {
      app = app.copyWith(isAmFrozen: true);
    }
    result.add(app);
  }
  result.sort(
    (a, b) =>
        a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
  );
  return result;
}

List<InstalledApp> filterInstalledApps(
  List<InstalledApp> apps, {
  required AppListFilter filter,
  String query = '',
}) {
  final needle = query.trim().toLowerCase();
  return apps.where((app) {
    switch (filter) {
      case AppListFilter.user:
        if (app.isSystem) return false;
      case AppListFilter.system:
        if (!app.isSystem) return false;
      case AppListFilter.frozen:
        if (!app.isFrozen) return false;
      case AppListFilter.all:
        break;
    }
    if (needle.isEmpty) return true;
    return app.displayName.toLowerCase().contains(needle) ||
        app.packageName.toLowerCase().contains(needle);
  }).toList();
}

/// 从 `unzip -l` 输出中挑选最合适的启动图标条目。
String? pickBestIconEntry(String unzipListOutput) {
  String? best;
  var bestScore = -1;
  for (final raw in const LineSplitterCompat().convert(unzipListOutput)) {
    final match = _iconEntry.firstMatch(raw.trim());
    if (match == null) continue;
    final entry = match.group(1)!;
    final lower = entry.toLowerCase();
    if (lower.contains('background') && !lower.contains('foreground')) {
      continue;
    }
    final score = _iconScore(lower);
    if (score > bestScore) {
      bestScore = score;
      best = entry;
    }
  }
  return best;
}

int _iconScore(String path) {
  var score = 0;
  if (path.contains('xxxhdpi')) {
    score += 40;
  } else if (path.contains('xxhdpi')) {
    score += 35;
  } else if (path.contains('xhdpi')) {
    score += 30;
  } else if (path.contains('hdpi')) {
    score += 20;
  } else if (path.contains('mdpi')) {
    score += 10;
  }
  if (path.contains('mipmap')) score += 8;
  if (path.contains('ic_launcher_foreground')) {
    score += 6;
  } else if (path.contains('ic_launcher')) {
    score += 10;
  } else if (path.contains('icon')) {
    score += 4;
  }
  if (path.endsWith('.png')) score += 2;
  return score;
}

bool looksLikeImageBytes(List<int> bytes) {
  if (bytes.length < 12) return false;
  if (bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47) {
    return true;
  }
  if (bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return true;
  }
  if (bytes[0] == 0xff && bytes[1] == 0xd8) return true;
  return false;
}

String formatByteSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const kb = 1024;
  const mb = 1024 * 1024;
  const gb = 1024 * 1024 * 1024;
  if (bytes < mb) return '${(bytes / kb).toStringAsFixed(1)} KB';
  if (bytes < gb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  return '${(bytes / gb).toStringAsFixed(1)} GB';
}

/// `pm` 成功输出通常为 `Success`；部分 disable/enable 命令成功时无输出。
void ensurePmSuccess(String output, {bool allowEmpty = false}) {
  final trimmed = output.trim();
  if (trimmed.isEmpty) {
    if (allowEmpty) return;
    throw StateError('命令无输出');
  }
  if (RegExp(r'^Success\b', caseSensitive: false).hasMatch(trimmed)) return;
  throw StateError(trimmed);
}

/// 兼容 `\n` / `\r\n` 的分行。
class LineSplitterCompat {
  const LineSplitterCompat();

  Iterable<String> convert(String input) sync* {
    final normalized = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    yield* normalized.split('\n');
  }
}
