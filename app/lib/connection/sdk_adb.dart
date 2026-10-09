import 'dart:io';

/// 按「which / where、ANDROID_HOME、各平台常见 SDK 目录」查找 adb。
String? resolveSdkAdb({
  required bool windows,
  required Map<String, String> environment,
  String? whichOutput,
  required bool Function(String path) exists,
}) {
  final fromPath = _firstExistingPath(whichOutput, exists);
  if (fromPath != null) return fromPath;
  for (final candidate in sdkAdbCandidates(
    windows: windows,
    environment: environment,
  )) {
    if (exists(candidate)) return candidate;
  }
  return null;
}

/// `where` / `which` 的输出里，第一条真实存在的路径。
String? _firstExistingPath(String? output, bool Function(String path) exists) {
  if (output == null || output.trim().isEmpty) return null;
  for (final raw in output.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (exists(line)) return line;
  }
  return null;
}

/// ANDROID_HOME、ANDROID_SDK_ROOT，以及各平台默认 SDK 位置下的 adb。
List<String> sdkAdbCandidates({
  required bool windows,
  required Map<String, String> environment,
}) {
  final exe = windows ? 'adb.exe' : 'adb';
  final sep = windows ? r'\' : '/';
  final paths = <String>[];
  void addSdk(String? root) {
    final trimmed = root?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    var base = trimmed;
    if (base.length > 1 && (base.endsWith('/') || base.endsWith(r'\'))) {
      base = base.substring(0, base.length - 1);
    }
    paths.add('$base${sep}platform-tools$sep$exe');
  }

  addSdk(environment['ANDROID_HOME']);
  addSdk(environment['ANDROID_SDK_ROOT']);
  final home = environment['HOME'] ?? environment['USERPROFILE'];
  if (windows) {
    addSdk(
      environment['LOCALAPPDATA'] == null
          ? null
          : '${environment['LOCALAPPDATA']}\\Android\\Sdk',
    );
    if (home != null && home.isNotEmpty) {
      addSdk('$home\\AppData\\Local\\Android\\Sdk');
    }
    return paths;
  }
  if (home != null && home.isNotEmpty) {
    addSdk('$home/Library/Android/sdk');
    addSdk('$home/Android/Sdk');
  }
  paths.add('/usr/lib/android-sdk/platform-tools/adb');
  paths.add('/usr/local/share/android-sdk/platform-tools/adb');
  paths.add('/opt/android-sdk/platform-tools/adb');
  return paths;
}

/// 在 PATH 里查找 adb。找不到时返回 null。
Future<String?> whichAdb() async {
  try {
    final result = Platform.isWindows
        ? await Process.run('where.exe', <String>['adb'])
        : await Process.run('which', <String>['adb']);
    if (result.exitCode != 0) return null;
    return '${result.stdout}';
  } catch (_) {
    return null;
  }
}

/// 查找本机 SDK 的 adb。没有时返回 null。
Future<String?> findSdkAdb() async {
  final whichOutput = await whichAdb();
  return resolveSdkAdb(
    windows: Platform.isWindows,
    environment: Platform.environment,
    whichOutput: whichOutput,
    exists: (path) => File(path).existsSync(),
  );
}

/// 让找到的 adb 在 [port] 上启动它自己的 server。
Future<void> startSdkAdbServer(String adb, {required int port}) async {
  final result = await Process.run(adb, <String>[
    '-P',
    '$port',
    'start-server',
  ]);
  if (result.exitCode != 0) {
    final detail = '${result.stderr}'.trim();
    throw StateError(detail.isEmpty ? 'adb start-server 失败' : detail);
  }
}

/// 关掉 [port] 上由 adb 启动的 server，给 FireAdb 自己的 server 让出端口。
Future<void> killSdkAdbServer(String adb, {required int port}) async {
  final result = await Process.run(adb, <String>['-P', '$port', 'kill-server']);
  if (result.exitCode != 0) {
    final detail = '${result.stderr}'.trim();
    throw StateError(detail.isEmpty ? 'adb kill-server 失败' : detail);
  }
}
