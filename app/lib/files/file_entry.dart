/// 一个文件系统条目的行数据契约（对标 AOSP DocumentsFile 的属性面）。
/// 元数据由 list 一次取齐，属性访问零额外开销（区别于 DocumentsFile
/// 的逐属性跨进程查询）。两个实现：本机 [LocalFile]（包住 dart:io 目录项）
/// 与设备 `RemoteFile`（数据 bean 直接实现，无包装层）。
///
/// 操作不放在条目上：节点操作需要绑定具体后端执行，那会迫使数据 bean
/// 携带后端引用。所有操作（批量优先）都在 [FileBackend] 上。
abstract interface class FileEntry {
  String get name;
  String get path;

  /// 常规文件 0x8000、目录 0x4000、链接 0xa000，与 POSIX st_mode 对齐。
  int get mode;
  bool get isDirectory;
  bool get isLink;

  /// 可以作为目录进入。设备上指向目录的链接也为 true。
  bool get canEnter;
  int get size;
  bool get sizeKnown;

  /// epoch 秒；未知为 0。
  int get mtime;

  /// 权限位是否可修改（本机 Windows 为 false）。
  bool get canChmod;
}
