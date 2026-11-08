import 'dart:io';

import 'android_local_picker.dart';
import 'file_entry.dart';

/// [FileEntry] 的本机实现：代理模式，包住 dart:io 的目录项。
/// 构造后做一次快照（lstat 判类型 + stat 取大小/时间/权限）并缓存，
/// 之后属性读取零 IO——与设备后端“list 一次取齐”的语义对齐
/// （ADB 无法对单个条目补查属性，惰性代理会造成两端行为不对称）。
class LocalFile implements FileEntry {
  LocalFile(this.entity);

  /// list 时拿到的 dart:io 目录项（不跟随链接）。
  final FileSystemEntity entity;

  @override
  late final String path = normalizeLocalPath(entity.path);

  @override
  late final String name = localEntryName(entity.path);

  /// lstat 类型：常规文件 0x8000、目录 0x4000、链接 0xa000。
  late final int typeBits = switch (
    FileSystemEntity.typeSync(entity.path, followLinks: false)
  ) {
    FileSystemEntityType.directory => 0x4000,
    FileSystemEntityType.link => 0xa000,
    _ => 0x8000,
  };

  /// 跟随链接后的 stat。断链等读取失败时为 null。
  late final FileStat? stat = () {
    try {
      return entity.statSync();
    } catch (_) {
      return null;
    }
  }();

  @override
  bool get isDirectory => typeBits == 0x4000;

  @override
  bool get isLink => typeBits == 0xa000;

  @override
  bool get canEnter => isDirectory;

  @override
  int get size => stat?.size ?? 0;

  @override
  bool get sizeKnown => stat != null && stat!.size >= 0;

  @override
  int get mtime =>
      stat == null || stat!.modified.year <= 1971
          ? 0
          : stat!.modified.millisecondsSinceEpoch ~/ 1000;

  @override
  int get mode => typeBits | (stat?.mode ?? 0) & 0x1ff;

  @override
  bool get canChmod => !Platform.isWindows;
}
