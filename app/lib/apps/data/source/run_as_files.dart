import 'dart:io';
import 'dart:typed_data';

import '../../../connection/model/connected_device.dart';
import '../../../files/data/source/remote_file_commands.dart';
import '../../../shell/root_shell.dart';

final _packagePattern = RegExp(r'^[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)+$');

final _lsLine = RegExp(
  r'^([dl\-])[rwxsStT-]{9}[.+]?\s+\d+\s+\S+\s+\S+\s+(\d+)\s+'
  r'\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}(?::\d{2})?\s+(.+)$',
);

/// 应用数据目录里的一项。debug 应用用 `run-as` 列出，root 模式直接列出。
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

/// `/data/data` 和 `/data/user` 默认用 `run-as`。root 模式下改为 root 读取。SD 卡目录走 shell。
bool isPrivateAppDataPath(String path) {
  final value = normalizeRemotePath(path);
  return value.startsWith('/data/data/') || value.startsWith('/data/user/');
}

/// 从 `/data/data/<包名>` 或 `/data/user/<用户>/<包名>` 取出包名。
String? packageOfPrivatePath(String path) {
  final value = normalizeRemotePath(path);
  const dataPrefix = '/data/data/';
  if (value.startsWith(dataPrefix)) {
    return _packageSegment(value.substring(dataPrefix.length));
  }
  final user = RegExp(r'^/data/user/\d+/([^/]+)').firstMatch(value);
  if (user == null) return null;
  return _packageSegment(user.group(1)!);
}

String? _packageSegment(String value) {
  final slash = value.indexOf('/');
  final packageName = slash < 0 ? value : value.substring(0, slash);
  if (!isAppPackageName(packageName)) return null;
  return packageName;
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
    final command = await _privateCommand(
      device,
      rooted: shellListCommand(directory),
      runAs: runAsListCommand(packageName, directory),
    );
    final output = await device.shell(command);
    return AppDirectoryPage(
      root: root,
      directory: directory,
      entries: parseRunAsList(output, directory),
    );
  }
  final opened = await openExternalDirectory(device, directory);
  return AppDirectoryPage(
    root: _remapRoot(root, directory, opened.directory),
    directory: opened.directory,
    entries: opened.entries,
  );
}

/// 只列调用方给出的目录。shell 读得到已创建的 `Android/data`。
///
/// 没创建过的目录就是不存在。`/mnt/androidwritable` 等挂载 shell 不能进，
/// 再去试只会得到 Permission denied。
Future<({String directory, List<RunAsEntry> entries})> openExternalDirectory(
  ConnectedDevice device,
  String directory,
) async {
  final normalized = normalizeRemotePath(directory);
  final output = await device.shell(shellListCommand(normalized));
  return (directory: normalized, entries: parseRunAsList(output, normalized));
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
      ? await _privateCommand(
          device,
          rooted: shellCatCommand(path),
          runAs: runAsCatCommand(packageName, path),
        )
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
  final command = isPrivateAppDataPath(root)
      ? await _privateCommand(
          device,
          rooted: shellDeleteCommand(path),
          runAs: runAsDeleteCommand(packageName, path),
        )
      : shellDeleteCommand(path);
  final output = await device.shell(command);
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
      ? await _privateCommand(
          device,
          rooted: shellCatCommand(remotePath),
          runAs: runAsCatCommand(packageName, remotePath),
        )
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

/// root 模式用 root 执行 [rooted]，否则用 [runAs]。
Future<String> _privateCommand(
  ConnectedDevice device, {
  required String rooted,
  required String runAs,
}) {
  if (!rootCanEditAppData(device.serial)) return Future<String>.value(runAs);
  return rootCommand(device, rooted, scope: SuScope.apps);
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
