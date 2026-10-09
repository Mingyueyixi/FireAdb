import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/fire_adb_localizations_ext.dart';
import '../l10n/generated/fire_adb_localizations.dart';
import 'android_storage_access.dart';
import 'ui/file_dialogs.dart';

/// 主共享存储。选择器把它当作内部存储的根。
const String primaryStoragePath = '/storage/emulated/0';

/// 盘符列表。不是真实目录，上一级从 `C:/` 进入这里。
const String windowsDrivesPath = '::drives';

final _driveRoot = RegExp(r'^[A-Za-z]:$');

/// 去掉末尾斜杠，并把反斜杠换成 `/`。盘符根保留为 `C:/`。
String normalizeLocalPath(String path) {
  var value = path.trim().replaceAll(r'\', '/');
  if (value.length > 1 && value.endsWith('/')) {
    final stripped = value.substring(0, value.length - 1);
    if (_driveRoot.hasMatch(stripped)) return '$stripped/';
    value = stripped;
  }
  return value;
}

/// 路径最后一段。盘符根 `C:/` 的名字就是它自己。
String localEntryName(String path) {
  final normalized = normalizeLocalPath(path);
  final index = normalized.lastIndexOf('/');
  if (index < 0 || index >= normalized.length - 1) return normalized;
  return normalized.substring(index + 1);
}

/// 上一级目录。`/` 和盘符列表没有上级。盘符根的上一级是盘符列表。
/// `C:` 会收成 `C:/`，避免变成当前目录。
String? parentLocalPath(String path) {
  final current = normalizeLocalPath(path);
  if (current.isEmpty || current == '/' || current == windowsDrivesPath) {
    return null;
  }
  if (_driveRoot.hasMatch(current)) return windowsDrivesPath;
  if (current.endsWith('/') &&
      _driveRoot.hasMatch(current.substring(0, current.length - 1))) {
    return windowsDrivesPath;
  }
  final index = current.lastIndexOf('/');
  if (index < 0) return null;
  if (index == 0) return '/';
  final parent = current.substring(0, index);
  if (_driveRoot.hasMatch(parent)) return '$parent/';
  return parent;
}

/// 把子项接到正在浏览的目录上，不使用系统返回的联结目标路径。
String joinLocalChild(String directory, String name) {
  final parent = normalizeLocalPath(directory);
  if (parent.endsWith('/')) return '$parent$name';
  return '$parent/$name';
}

bool isWindowsDrivesPath(String path) =>
    normalizeLocalPath(path) == windowsDrivesPath;

/// 从 `fsutil fsinfo drives` 的输出里取出盘符根，例如 `C:/`。
List<String> parseWindowsDrives(String output) {
  final found = <String>{};
  for (final match in RegExp(r'([A-Za-z]):\\').allMatches(output)) {
    found.add('${match.group(1)!.toUpperCase()}:/');
  }
  final drives = found.toList()..sort();
  return drives;
}

/// 新建文件夹时拒绝空名、`.`、`..` 和路径分隔符。
bool isSafeLocalName(String name) {
  if (name.isEmpty || name == '.' || name == '..') return false;
  if (name.contains('/') || name.contains(r'\')) return false;
  return true;
}

/// 只整理分隔符。目录联结保持用户看到的路径，不跟到目标盘。
Future<String> canonicalizeLocalPath(String path) async {
  return normalizeLocalPath(path);
}

Future<bool> directoryExists(String path) async {
  try {
    return await Directory(path).exists();
  } catch (_) {
    return false;
  }
}

class LocalNode {
  const LocalNode({
    required this.name,
    required this.path,
    required this.directory,
  });

  final String name;
  final String path;
  final bool directory;
}

Future<List<String>> listWindowsDriveRoots() async {
  if (!Platform.isWindows) return const <String>[];
  final result = await Process.run('fsutil', <String>['fsinfo', 'drives']);
  if (result.exitCode != 0) {
    throw StateError('${result.stderr}'.trim());
  }
  return parseWindowsDrives('${result.stdout}');
}

Future<List<LocalNode>> listLocalNodes(String path) async {
  final directory = normalizeLocalPath(path);
  final nodes = <LocalNode>[];
  await for (final entity in Directory(directory).list(followLinks: false)) {
    final name = localEntryName(entity.path);
    if (name.isEmpty || name.startsWith('.')) continue;
    final entryPath = joinLocalChild(directory, name);
    if (entity is Directory) {
      nodes.add(LocalNode(name: name, path: entryPath, directory: true));
    } else if (entity is File) {
      nodes.add(LocalNode(name: name, path: entryPath, directory: false));
    } else if (entity is Link) {
      final kind = await FileSystemEntity.type(entryPath, followLinks: true);
      if (kind == FileSystemEntityType.notFound) continue;
      nodes.add(
        LocalNode(
          name: name,
          path: entryPath,
          directory: kind == FileSystemEntityType.directory,
        ),
      );
    }
  }
  nodes.sort((a, b) {
    if (a.directory != b.directory) return a.directory ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return nodes;
}

/// 用本机目录列表选择一个文件夹。桌面和 Android 共用这一套，不打开系统选择器。
Future<String?> showLocalDirectoryPicker(
  BuildContext context, {
  String? initialDirectory,
  String? prompt,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _LocalBrowser(
      title: prompt ?? context.l10n.localPickerChooseFolder,
      initialDirectory: initialDirectory,
      pickFiles: false,
      onPickDirectory: (path) => Navigator.pop(context, path),
    ),
  );
}

/// 用本机目录列表选择一个文件夹。取消或未授权时返回 null。
Future<String?> pickAndroidDirectory(
  BuildContext context, {
  String? initialDirectory,
  String? prompt,
}) async {
  if (!await ensureAllFilesAccess(context) || !context.mounted) return null;
  return showLocalDirectoryPicker(
    context,
    initialDirectory: initialDirectory,
    prompt: prompt,
  );
}

/// 用本机目录列表选择文件。取消或未授权时返回空列表。
Future<List<String>> pickAndroidFiles(BuildContext context) async {
  if (!await ensureAllFilesAccess(context) || !context.mounted) {
    return const <String>[];
  }
  final picked = await showDialog<List<String>>(
    context: context,
    builder: (context) => _LocalBrowser(
      title: context.l10n.localPickerChooseFiles,
      initialDirectory: '/sdcard',
      pickFiles: true,
      onPickFiles: (paths) => Navigator.pop(context, paths),
    ),
  );
  return picked ?? const <String>[];
}

class _LocalBrowser extends StatefulWidget {
  const _LocalBrowser({
    required this.title,
    required this.pickFiles,
    this.initialDirectory,
    this.onPickDirectory,
    this.onPickFiles,
  });

  final String title;
  final String? initialDirectory;
  final bool pickFiles;
  final ValueChanged<String>? onPickDirectory;
  final ValueChanged<List<String>>? onPickFiles;

  @override
  State<_LocalBrowser> createState() => _LocalBrowserState();
}

class _LocalBrowserState extends State<_LocalBrowser> {
  late final TextEditingController _pathController;
  String? _directory;
  List<LocalNode> _entries = const <LocalNode>[];
  final Set<String> _selected = <String>{};
  var _loading = true;
  var _unreadable = false;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _pathController = TextEditingController(
      text: widget.initialDirectory ?? '',
    );
    unawaited(_loadInitial());
  }

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  Future<void> _loadInitial() async {
    try {
      final start = await _startingDirectory();
      if (!mounted) return;
      await _open(start);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _unreadable = true;
      });
    }
  }

  /// 有指定目录就打开它。Android 否则打开 `/sdcard`，桌面否则打开用户目录。
  Future<String> _startingDirectory() async {
    final requested = widget.initialDirectory?.trim();
    if (requested != null && requested.isNotEmpty) {
      final path = await canonicalizeLocalPath(requested);
      if (await directoryExists(path)) return path;
    }
    if (!Platform.isAndroid) {
      final home = _desktopHome();
      if (home != null && await directoryExists(home)) {
        return canonicalizeLocalPath(home);
      }
      return normalizeLocalPath(Directory.current.path);
    }
    if (await directoryExists('/sdcard')) {
      return canonicalizeLocalPath('/sdcard');
    }
    return primaryStoragePath;
  }

  String? _desktopHome() {
    for (final key in const <String>['HOME', 'USERPROFILE']) {
      final value = Platform.environment[key]?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  Future<void> _open(String path) async {
    if (isWindowsDrivesPath(path)) {
      await _openDrives();
      return;
    }
    final normalized = normalizeLocalPath(path);
    _pathController.value = TextEditingValue(
      text: normalized,
      selection: TextSelection.collapsed(offset: normalized.length),
    );
    setState(() {
      _loading = true;
      _unreadable = false;
      _notice = null;
      _selected.clear();
    });
    try {
      final entries = await listLocalNodes(path);
      if (!mounted) return;
      setState(() {
        _directory = normalizeLocalPath(path);
        _entries = entries;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _directory = normalizeLocalPath(path);
        _entries = const <LocalNode>[];
        _loading = false;
        _unreadable = true;
      });
    }
  }

  bool get _canGoUp {
    if (_loading) return false;
    final directory = _directory;
    if (directory == null) return false;
    return parentLocalPath(directory) != null;
  }

  bool get _canPop {
    final directory = _directory;
    if (directory == null || _loading) return true;
    return parentLocalPath(directory) == null;
  }

  void _goUp() {
    final directory = _directory;
    if (directory == null) return;
    final parent = parentLocalPath(directory);
    if (parent == null) return;
    unawaited(_open(parent));
  }

  Future<void> _openDrives() async {
    final label = context.l10n.localPickerStorage;
    _pathController.value = TextEditingValue(
      text: label,
      selection: TextSelection.collapsed(offset: label.length),
    );
    setState(() {
      _loading = true;
      _unreadable = false;
      _notice = null;
      _selected.clear();
    });
    try {
      final roots = await listWindowsDriveRoots();
      if (!mounted) return;
      setState(() {
        _directory = windowsDrivesPath;
        _entries = <LocalNode>[
          for (final root in roots)
            LocalNode(name: root, path: root, directory: true),
        ];
        _loading = false;
        _unreadable = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _directory = windowsDrivesPath;
        _entries = const <LocalNode>[];
        _loading = false;
        _unreadable = true;
      });
    }
  }

  Future<void> _jumpToEditedPath() async {
    final raw = _pathController.text.trim();
    if (raw == context.l10n.localPickerStorage || isWindowsDrivesPath(raw)) {
      await _open(windowsDrivesPath);
      return;
    }
    var text = normalizeLocalPath(raw);
    if (_driveRoot.hasMatch(text)) text = '$text/';
    if (text.isEmpty) return;
    if (await directoryExists(text)) {
      await _open(text);
      return;
    }
    var isFile = false;
    try {
      isFile = await File(text).exists();
    } catch (_) {}
    if (!mounted) return;
    if (isFile) {
      final parent = parentLocalPath(text);
      if (parent != null) {
        await _open(parent);
        if (widget.pickFiles && mounted) {
          setState(() => _selected.add(text));
        }
        return;
      }
    }
    await _open(text);
  }

  Future<void> _createFolder() async {
    final directory = _directory;
    if (directory == null || isWindowsDrivesPath(directory) || !mounted) {
      return;
    }
    final l10n = context.l10n;
    final name = await askRemoteName(
      context,
      title: l10n.localPickerNewFolder,
      action: l10n.filesCreate,
    );
    if (name == null || !mounted) return;
    if (!isSafeLocalName(name)) {
      setState(() => _notice = l10n.localPickerInvalidName);
      return;
    }
    try {
      final separator = directory.endsWith('/') ? '' : '/';
      final created = Directory('$directory$separator$name');
      await created.create();
      await _open(created.path);
    } catch (_) {
      if (!mounted) return;
      setState(() => _unreadable = true);
    }
  }

  void _toggleFile(String path, bool selected) {
    setState(() {
      if (selected) {
        _selected.add(path);
      } else {
        _selected.remove(path);
      }
    });
  }

  void _confirm() {
    final directory = _directory;
    if (directory == null || isWindowsDrivesPath(directory)) return;
    if (widget.pickFiles) {
      if (_selected.isEmpty) return;
      widget.onPickFiles?.call(_selected.toList());
      return;
    }
    widget.onPickDirectory?.call(directory);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final directory = _directory;
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 120).clamp(240.0, 640.0).toDouble();
    final height = (size.height * 0.45).clamp(220.0, 420.0).toDouble();
    final browsingDrives =
        directory != null && isWindowsDrivesPath(directory);
    final canConfirm =
        directory != null &&
        !_loading &&
        !browsingDrives &&
        (widget.pickFiles ? _selected.isNotEmpty : true);
    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goUp();
      },
      child: AlertDialog(
        title: Text(widget.title),
        content: SizedBox(
          width: width,
          height: height,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  IconButton(
                    tooltip: l10n.localPickerUp,
                    onPressed: _canGoUp ? _goUp : null,
                    icon: const Icon(Icons.arrow_upward),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _pathController,
                      textInputAction: TextInputAction.go,
                      onSubmitted: (_) => unawaited(_jumpToEditedPath()),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 8,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.localPickerGo,
                    onPressed: () => unawaited(_jumpToEditedPath()),
                    icon: const Icon(Icons.arrow_forward),
                  ),
                  if (!widget.pickFiles &&
                      directory != null &&
                      !isWindowsDrivesPath(directory))
                    IconButton(
                      tooltip: l10n.localPickerNewFolder,
                      onPressed: _loading
                          ? null
                          : () => unawaited(_createFolder()),
                      icon: const Icon(Icons.create_new_folder_outlined),
                    ),
                ],
              ),
              if (_notice != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _notice!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const Divider(height: 1),
              Expanded(child: _buildBody(l10n)),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: canConfirm ? _confirm : null,
            child: Text(
              widget.pickFiles
                  ? l10n.localPickerUseFiles(_selected.length)
                  : l10n.localPickerUseFolder,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(FireAdbLocalizations l10n) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_unreadable || _directory == null) {
      return Center(child: Text(l10n.localPickerUnreadable));
    }
    if (_entries.isEmpty) {
      return Center(child: Text(l10n.localPickerEmpty));
    }
    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final entry = _entries[index];
        if (entry.directory) {
          return ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(entry.name),
            onTap: () => unawaited(_open(entry.path)),
          );
        }
        if (!widget.pickFiles) {
          return ListTile(
            leading: const Icon(Icons.insert_drive_file_outlined),
            title: Text(entry.name),
          );
        }
        final selected = _selected.contains(entry.path);
        return ListTile(
          leading: const Icon(Icons.insert_drive_file_outlined),
          title: Text(entry.name),
          trailing: Checkbox(
            value: selected,
            onChanged: (value) => _toggleFile(entry.path, value == true),
          ),
          onTap: () => _toggleFile(entry.path, !selected),
        );
      },
    );
  }
}
