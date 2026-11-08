import 'file_entry.dart';

/// 设备上的一个文件或目录。直接实现 [FileEntry]，不套包装层。
class RemoteFile implements FileEntry {
  const RemoteFile({
    required this.name,
    required this.path,
    required this.mode,
    required this.size,
    required this.mtime,
    this.sizeKnown = true,
    this.opensAsDirectory = false,
  });

  @override
  final String name;
  @override
  final String path;
  @override
  final int mode;
  @override
  final int size;
  @override
  final int mtime;
  @override
  final bool sizeKnown;

  /// 链接指向目录时为 true。sync 的 LIST 只给出链接本身，不跟随目标。
  final bool opensAsDirectory;

  @override
  bool get isDirectory => mode & 0xf000 == 0x4000;

  @override
  bool get isLink => mode & 0xf000 == 0xa000;

  @override
  bool get canEnter => isDirectory || opensAsDirectory;

  /// 设备端经 root shell 可改权限，总是支持。
  @override
  bool get canChmod => true;

  RemoteFile copyWith({String? name, String? path, bool? opensAsDirectory}) {
    return RemoteFile(
      name: name ?? this.name,
      path: path ?? this.path,
      mode: mode,
      size: size,
      mtime: mtime,
      sizeKnown: sizeKnown,
      opensAsDirectory: opensAsDirectory ?? this.opensAsDirectory,
    );
  }
}

/// 一次导出里的单个远端文件。
class RemoteExportPiece {
  const RemoteExportPiece({
    required this.remotePath,
    required this.relativePath,
    required this.size,
    required this.directory,
  });

  final String remotePath;
  final String relativePath;
  final int size;
  final bool directory;
}
