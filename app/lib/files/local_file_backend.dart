import 'dart:io';
import 'dart:typed_data';

import 'android_local_picker.dart';
import 'file_backend.dart';
import 'file_entry.dart';
import 'local_file.dart';

/// 本机文件系统后端。dart:io 直达，无权限、无连接概念；
/// 路径规则沿用本机选择器的约定（`/` 分隔、盘符根 `C:/`）。
class LocalFileBackend extends FileBackend {
  LocalFileBackend(this.initialPath);

  @override
  final String initialPath;

  @override
  bool get supportsChmod => !Platform.isWindows;

  @override
  bool get supportsTransfer => false;

  @override
  String normalize(String path) => normalizeLocalPath(path);

  @override
  String parent(String path) => parentLocalPath(path) ?? path;

  @override
  String join(String directory, String name) {
    if (!isSafeName(name)) {
      throw ArgumentError.value(name, 'name', '非法文件名');
    }
    return joinLocalChild(directory, name);
  }

  @override
  String nameOf(String path) => localEntryName(path);

  @override
  bool isSafeName(String name) => isSafeLocalName(name);

  @override
  String fence(String? root, String next) {
    final target = normalize(next);
    if (root == null) return target;
    final limit = normalize(root);
    return target == limit || target.startsWith('$limit/') ? target : limit;
  }

  @override
  Future<List<FileEntry>> list(String directory) async {
    final entries = <FileEntry>[];
    await for (final entity
        in Directory(normalize(directory)).list(followLinks: false)) {
      if (localEntryName(entity.path).isEmpty) continue;
      entries.add(LocalFile(entity));
    }
    _sort(entries);
    return entries;
  }

  @override
  Future<List<FileEntry>> search(String directory, String keyword) async {
    final query = keyword.trim().toLowerCase();
    if (query.isEmpty) return list(directory);
    final matches = <FileEntry>[];
    try {
      await for (final entity in Directory(
        normalize(directory),
      ).list(recursive: true, followLinks: false)) {
        final name = localEntryName(entity.path);
        if (!name.toLowerCase().contains(query)) continue;
        matches.add(LocalFile(entity));
        if (matches.length >= 200) break;
      }
    } on FileSystemException {
      // 无权进入的子目录直接跳过，已找到的结果仍然可用。
    }
    _sort(matches);
    return matches;
  }

  @override
  Future<Uint8List> readBytes(String path, {required int maxBytes}) async {
    final file = File(path);
    if (await file.length() > maxBytes) {
      throw StateError('文件超过 $maxBytes 字节');
    }
    return file.readAsBytes();
  }

  @override
  Future<void> writeBytes(
    String path,
    List<int> bytes, {
    int mode = 0x81a4,
  }) async {
    await File(path).writeAsBytes(bytes, flush: true);
    await _applyMode(path, mode);
  }

  @override
  Future<void> remove(Iterable<String> paths) async {
    for (final path in paths) {
      final entity = _entityAt(path);
      if (entity == null) continue;
      if (entity is Directory) {
        await entity.delete(recursive: true);
      } else {
        await entity.delete();
      }
    }
  }

  @override
  Future<void> rename(String from, String to) async {
    final entity = _entityAt(from);
    if (entity == null) throw StateError('源不存在：$from');
    await entity.rename(to);
  }

  @override
  Future<void> createFile(String path) async {
    await File(path).create();
    await _applyMode(path, 0x81a4);
  }

  @override
  Future<void> createDirectory(String path) async {
    await Directory(path).create();
  }

  @override
  Future<void> chmod(Iterable<String> paths, String mode) async {
    final bits = int.parse(mode, radix: 8) & 0x1ff;
    for (final path in paths) {
      await _applyMode(path, bits);
    }
  }

  @override
  Future<void> copyTo(Iterable<String> sources, String destination) async {
    for (final source in sources) {
      await _copyEntity(source, join(destination, nameOf(source)));
    }
  }

  @override
  Future<void> moveTo(Iterable<String> sources, String destination) async {
    for (final source in sources) {
      final target = join(destination, nameOf(source));
      try {
        await rename(source, target);
      } on FileSystemException {
        // 跨卷移动：退化成复制 + 删除。
        await _copyEntity(source, target);
        await remove(<String>[source]);
      }
    }
  }

  FileSystemEntity? _entityAt(String path) {
    return switch (FileSystemEntity.typeSync(path, followLinks: false)) {
      FileSystemEntityType.directory => Directory(path),
      FileSystemEntityType.link => Link(path),
      FileSystemEntityType.file => File(path),
      _ => null,
    };
  }

  void _sort(List<FileEntry> entries) {
    entries.sort((a, b) {
      if (a.canEnter != b.canEnter) return a.canEnter ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  Future<void> _applyMode(String path, int mode) async {
    if (Platform.isWindows) return;
    final bits = mode & 0x1ff;
    if (bits == 0) return;
    try {
      await Process.run('chmod', <String>[
        bits.toRadixString(8).padLeft(3, '0'),
        path,
      ]);
    } on ProcessException {
      // 环境里没有 chmod（极少见），跳过权限设置。
    }
  }

  Future<void> _copyEntity(String source, String target) async {
    final entity = _entityAt(source);
    if (entity == null) return;
    if (entity is Directory) {
      await Directory(target).create(recursive: true);
      await for (final child in entity.list(followLinks: false)) {
        await _copyEntity(child.path, join(target, localEntryName(child.path)));
      }
    } else if (entity is Link) {
      final targetPath = await entity.target();
      await Link(target).create(targetPath);
    } else if (entity is File) {
      await entity.copy(target);
    }
  }
}

