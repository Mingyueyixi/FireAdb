import 'dart:io';
import 'dart:typed_data';

import '../../../connection/model/connected_device.dart';
import '../../../files/data/source/remote_file_commands.dart';
import '../../../log/app_log.dart';

final _packagePattern = RegExp(r'^[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)+$');

final _lsLine = RegExp(
  r'^([dl\-])[rwxsStT-]{9}[.+]?\s+\d+\s+\S+\s+\S+\s+(\d+)\s+'
  r'\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}(?::\d{2})?\s+(.+)$',
);

const _emulatedPrefixes = <String>[
  '/sdcard/',
  '/storage/emulated/0/',
  '/storage/self/primary/',
];

/// shell 读不到 `Android/data` 时，给 shell 打开外部存储后再试一次。
const shellStorageGrantCommands = <String>[
  'appops set --uid 2000 MANAGE_EXTERNAL_STORAGE allow',
  'appops set com.android.shell MANAGE_EXTERNAL_STORAGE allow',
  'appops set com.android.shell LEGACY_STORAGE allow',
];

var _shellStorageGranted = false;

/// debug 应用数据目录里的一项。通过 `run-as` 列出来。
class RunAsEntry {
  const RunAsEntry({
    required this.name,
    required this.path,
    required this.directory,
    required this.link,
    required this.size,
  });

  final String name;
  final String path;
  final bool directory;
  final bool link;
  final int size;

  bool get canEnter => directory || link;
}

bool isAppPackageName(String packageName) =>
    _packagePattern.hasMatch(packageName);

/// `/data/data` 和 `/data/user` 只能用 `run-as` 读。SD 卡目录走 shell。
bool isPrivateAppDataPath(String path) {
  final value = normalizeRemotePath(path);
  return value.startsWith('/data/data/') || value.startsWith('/data/user/');
}

bool isRemotePermissionDenied(Object error) =>
    '$error'.toLowerCase().contains('permission denied');

/// FUSE 上的 `Android/data` 读不到时，换成存储卷上的真实目录。
List<String> externalDirectoryCandidates(String path) {
  final normalized = normalizeRemotePath(path);
  for (final prefix in _emulatedPrefixes) {
    if (!normalized.startsWith(prefix)) continue;
    final suffix = normalized.substring(prefix.length);
    return <String>[
      normalized,
      '/data/media/0/$suffix',
      '/mnt/pass_through/0/emulated/0/$suffix',
      '/mnt/user/0/emulated/0/$suffix',
      '/mnt/androidwritable/0/emulated/0/$suffix',
    ];
  }
  return <String>[normalized];
}

String shellListCommand(String directory) =>
    'ls -la ${quoteRemotePath(normalizeRemotePath(directory))}';

String shellCatCommand(String path) =>
    'cat ${quoteRemotePath(normalizeRemotePath(path))}';

String shellDeleteCommand(String path) =>
    'rm -rf ${quoteRemotePath(normalizeRemotePath(path))}';

/// 本地文件名里去掉 Windows 不能用的字符。
String localEntryName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[<>:"|?*\\]'), '_').trim();
  return cleaned.isEmpty ? '_' : cleaned;
}

/// [path] 落在 [root] 里面，并且没有 `..`。
bool isWithinAppRoot(String root, String path) {
  if (path.contains('\u0000') || path.split('/').contains('..')) return false;
  final base = normalizeRemotePath(root);
  final target = normalizeRemotePath(path);
  if (!target.startsWith('/')) return false;
  return target == base || target.startsWith('$base/');
}

String runAsListCommand(String packageName, String directory) {
  _requirePackage(packageName);
  final dir = quoteRemotePath(normalizeRemotePath(directory));
  return 'run-as ${quoteRemotePath(packageName)} ls -la $dir';
}

String runAsCatCommand(String packageName, String path) {
  _requirePackage(packageName);
  return 'run-as ${quoteRemotePath(packageName)} cat ${quoteRemotePath(path)}';
}

String runAsDeleteCommand(String packageName, String path) {
  _requirePackage(packageName);
  return 'run-as ${quoteRemotePath(packageName)} rm -rf ${quoteRemotePath(path)}';
}

List<RunAsEntry> parseRunAsList(String output, String directory) {
  final entries = <RunAsEntry>[];
  final errors = <String>[];
  for (final raw in output.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('total ')) continue;
    final match = _lsLine.firstMatch(line);
    if (match == null) {
      errors.add(line);
      continue;
    }
    final kind = match.group(1)!;
    var name = match.group(3)!;
    if (kind == 'l') {
      final arrow = name.indexOf(' -> ');
      if (arrow > 0) name = name.substring(0, arrow);
    }
    if (name == '.' || name == '..' || !isSafeRemoteName(name)) continue;
    final size = int.tryParse(match.group(2)!) ?? 0;
    entries.add(
      RunAsEntry(
        name: name,
        path: joinRemotePath(directory, name),
        directory: kind == 'd',
        link: kind == 'l',
        size: size,
      ),
    );
  }
  if (entries.isEmpty && errors.isNotEmpty) {
    throw StateError(errors.join('\n'));
  }
  entries.sort((a, b) {
    final aDir = a.directory || a.link;
    final bDir = b.directory || b.link;
    if (aDir != bDir) return aDir ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return entries;
}

Future<List<RunAsEntry>> listRunAsDirectory({
  required ConnectedDevice device,
  required String packageName,
  required String root,
  required String directory,
}) async {
  _requireInside(root, directory);
  final output = await device.shell(runAsListCommand(packageName, directory));
  return parseRunAsList(output, directory);
}

Future<Uint8List> readRunAsFile({
  required ConnectedDevice device,
  required String packageName,
  required String root,
  required String path,
}) async {
  _requireInside(root, path);
  if (normalizeRemotePath(path) == normalizeRemotePath(root)) {
    throw StateError('不能把目录当文件读取');
  }
  return device.execOut(runAsCatCommand(packageName, path));
}

Future<void> deleteRunAsPath({
  required ConnectedDevice device,
  required String packageName,
  required String root,
  required String path,
}) async {
  _requireInside(root, path);
  if (normalizeRemotePath(path) == normalizeRemotePath(root)) {
    throw StateError('不能删除目录本身');
  }
  final output = await device.shell(runAsDeleteCommand(packageName, path));
  final trimmed = output.trim();
  if (trimmed.isNotEmpty) throw StateError(trimmed);
}

/// 一次列目录的结果。SD 卡路径读不到时，[root] 会换成实际能读的路径。
class AppDirectoryPage {
  const AppDirectoryPage({
    required this.root,
    required this.directory,
    required this.entries,
  });

  final String root;
  final String directory;
  final List<RunAsEntry> entries;
}

Future<AppDirectoryPage> listAppDirectory({
  required ConnectedDevice device,
  required String packageName,
  required String root,
  required String directory,
}) async {
  _requireInside(root, directory);
  if (isPrivateAppDataPath(root)) {
    final entries = await listRunAsDirectory(
      device: device,
      packageName: packageName,
      root: root,
      directory: directory,
    );
    return AppDirectoryPage(root: root, directory: directory, entries: entries);
  }
  final opened = await openExternalDirectory(device, directory);
  return AppDirectoryPage(
    root: _remapRoot(root, directory, opened.directory),
    directory: opened.directory,
    entries: opened.entries,
  );
}

Future<({String directory, List<RunAsEntry> entries})> openExternalDirectory(
  ConnectedDevice device,
  String directory,
) async {
  final candidates = externalDirectoryCandidates(directory);
  final first = await _firstReadableDirectory(device, candidates);
  if (first.page != null) return first.page!;
  if (first.denied) {
    log.info('SD 卡目录没有读取权限，为 shell 打开外部存储访问后再试');
    await grantShellExternalStorage(device);
    final second = await _firstReadableDirectory(device, candidates);
    if (second.page != null) return second.page!;
  }
  final error = first.error ?? StateError('没有权限读取目录');
  throw error;
}

Future<void> grantShellExternalStorage(ConnectedDevice device) async {
  if (_shellStorageGranted) return;
  _shellStorageGranted = true;
  for (final command in shellStorageGrantCommands) {
    try {
      await device.shell(command);
    } catch (error, stackTrace) {
      log.warning('打开 shell 外部存储失败：$command', error, stackTrace);
    }
  }
}

Future<Uint8List> readAppFile({
  required ConnectedDevice device,
  required String packageName,
  required String root,
  required String path,
}) async {
  _requireInside(root, path);
  if (normalizeRemotePath(path) == normalizeRemotePath(root)) {
    throw StateError('不能把目录当文件读取');
  }
  final command = isPrivateAppDataPath(root)
      ? runAsCatCommand(packageName, path)
      : shellCatCommand(path);
  return device.execOut(command);
}

Future<void> deleteAppPath({
  required ConnectedDevice device,
  required String packageName,
  required String root,
  required String path,
}) async {
  _requireInside(root, path);
  if (normalizeRemotePath(path) == normalizeRemotePath(root)) {
    throw StateError('不能删除目录本身');
  }
  if (isPrivateAppDataPath(root)) {
    await deleteRunAsPath(
      device: device,
      packageName: packageName,
      root: root,
      path: path,
    );
    return;
  }
  final output = await device.shell(shellDeleteCommand(path));
  final trimmed = output.trim();
  if (trimmed.isNotEmpty) throw StateError(trimmed);
}

/// 把应用目录拉到 [localParent] 下的 [folderName]。
Future<String> exportAppDirectory({
  required ConnectedDevice device,
  required String packageName,
  required String remoteDirectory,
  required String localParent,
  required String folderName,
}) async {
  final localRoot = Directory(
    '$localParent${Platform.pathSeparator}${localEntryName(folderName)}',
  );
  await localRoot.create(recursive: true);
  await _copyTree(
    device: device,
    packageName: packageName,
    remoteRoot: normalizeRemotePath(remoteDirectory),
    remoteDirectory: normalizeRemotePath(remoteDirectory),
    localDirectory: localRoot,
  );
  return localRoot.path;
}

Future<
  ({
    ({String directory, List<RunAsEntry> entries})? page,
    Object? error,
    bool denied,
  })
>
_firstReadableDirectory(ConnectedDevice device, List<String> candidates) async {
  Object? lastError;
  var denied = false;
  for (final candidate in candidates) {
    try {
      final output = await device.shell(shellListCommand(candidate));
      final entries = parseRunAsList(output, candidate);
      return (
        page: (directory: candidate, entries: entries),
        error: null,
        denied: false,
      );
    } catch (error) {
      lastError = error;
      if (isRemotePermissionDenied(error)) {
        denied = true;
        continue;
      }
      if (error is StateError) continue;
      rethrow;
    }
  }
  return (page: null, error: lastError, denied: denied);
}

String _remapRoot(String root, String requested, String resolved) {
  final base = normalizeRemotePath(root);
  final from = normalizeRemotePath(requested);
  final to = normalizeRemotePath(resolved);
  if (from == to) return base;
  if (from == base) return to;
  if (from.startsWith('$base/') && to.endsWith(from.substring(base.length))) {
    return to.substring(0, to.length - (from.length - base.length));
  }
  return to;
}

Future<void> _copyTree({
  required ConnectedDevice device,
  required String packageName,
  required String remoteRoot,
  required String remoteDirectory,
  required Directory localDirectory,
}) async {
  final page = await listAppDirectory(
    device: device,
    packageName: packageName,
    root: remoteRoot,
    directory: remoteDirectory,
  );
  for (final entry in page.entries) {
    if (entry.link || !isWithinAppRoot(page.root, entry.path)) continue;
    final name = localEntryName(entry.name);
    if (entry.directory) {
      final child = Directory(
        '${localDirectory.path}${Platform.pathSeparator}$name',
      );
      await child.create(recursive: true);
      await _copyTree(
        device: device,
        packageName: packageName,
        remoteRoot: page.root,
        remoteDirectory: entry.path,
        localDirectory: child,
      );
      continue;
    }
    await _copyFile(
      device: device,
      packageName: packageName,
      root: page.root,
      remotePath: entry.path,
      localFile: File('${localDirectory.path}${Platform.pathSeparator}$name'),
    );
  }
}

Future<void> _copyFile({
  required ConnectedDevice device,
  required String packageName,
  required String root,
  required String remotePath,
  required File localFile,
}) async {
  final command = isPrivateAppDataPath(root)
      ? runAsCatCommand(packageName, remotePath)
      : shellCatCommand(remotePath);
  final exec = await device.openExec(command);
  final sink = localFile.openWrite();
  Object? error;
  try {
    await for (final chunk in exec.readStream) {
      sink.add(chunk);
    }
  } catch (caught) {
    error = caught;
    rethrow;
  } finally {
    await sink.flush();
    await sink.close();
    await exec.close();
    if (error != null) {
      try {
        await localFile.delete();
      } catch (_) {}
    }
  }
}

void _requirePackage(String packageName) {
  if (!isAppPackageName(packageName)) {
    throw ArgumentError.value(packageName, 'packageName', '非法包名');
  }
}

void _requireInside(String root, String path) {
  if (!isWithinAppRoot(root, path)) {
    throw StateError('路径超出应用目录');
  }
}
