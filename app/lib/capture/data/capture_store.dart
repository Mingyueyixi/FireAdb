import 'dart:io';

import 'capture_paths.dart';

class CaptureFile {
  const CaptureFile({
    required this.path,
    required this.name,
    required this.size,
    required this.modified,
  });

  final String path;
  final String name;
  final int size;
  final DateTime modified;
}

/// 应用目录里的截图和录像。
class CaptureStore {
  CaptureStore(this.directory);

  final Directory directory;

  static CaptureStore? tryOpen([Map<String, String>? environment]) {
    final path = captureDirectoryPath(environment ?? Platform.environment);
    if (path == null) return null;
    return CaptureStore(Directory(path));
  }

  Future<void> ensure() => directory.create(recursive: true);

  Future<File> write(String name, List<int> bytes) async {
    if (!isSafeCaptureName(name)) {
      throw ArgumentError.value(name, 'name', 'unsafe file name');
    }
    await ensure();
    final file = File(_childPath(name));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<List<CaptureFile>> list({required String extension}) async {
    if (!await directory.exists()) return const <CaptureFile>[];
    final suffix = '.${extension.toLowerCase()}';
    final files = <CaptureFile>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = baseName(entity.path);
      if (!name.toLowerCase().endsWith(suffix)) continue;
      final stat = await entity.stat();
      if (stat.type != FileSystemEntityType.file) continue;
      files.add(
        CaptureFile(
          path: entity.path,
          name: name,
          size: stat.size,
          modified: stat.modified,
        ),
      );
    }
    files.sort((a, b) => b.modified.compareTo(a.modified));
    return files;
  }

  Future<void> deleteFile(CaptureFile file) async {
    if (!isSafeCaptureName(file.name)) {
      throw ArgumentError.value(file.name, 'name', 'unsafe file name');
    }
    final target = File(file.path);
    if (baseName(target.path) != file.name ||
        !isInsideDirectory(directory.path, target.path)) {
      throw StateError('refuse to delete outside the app directory');
    }
    if (await target.exists()) await target.delete();
  }

  String _childPath(String name) {
    final separator = Platform.pathSeparator;
    final root = directory.path.endsWith(separator)
        ? directory.path.substring(0, directory.path.length - 1)
        : directory.path;
    return '$root$separator$name';
  }
}

String baseName(String path) {
  final normalized = path.replaceAll(r'\', '/');
  final slash = normalized.lastIndexOf('/');
  if (slash < 0 || slash == normalized.length - 1) return path;
  return normalized.substring(slash + 1);
}

bool isInsideDirectory(String root, String target) {
  return isInsideDirectoryPath(
    _normalizedAbsolute(root),
    _normalizedAbsolute(target),
    separator: Platform.pathSeparator,
    ignoreCase: Platform.isWindows,
  );
}

String _normalizedAbsolute(String path) {
  return File(path).absolute.uri.normalizePath().toFilePath();
}
