import 'dart:typed_data';

import 'file_entry.dart';

/// 后端不可用（设备未连接等）。
class DeviceNotConnectedException implements Exception {
  const DeviceNotConnectedException();
}

/// 文件系统后端。[FileEntry] 是节点句柄，这里归属一次批量操作与路径语义。
/// 设备后端包装 ADB sync + root shell（[RemoteFileBackend]），
/// 本机后端基于 dart:io（[LocalFileBackend]）。控制器与 UI 只经由此层，
/// 不直接接触 File 对象或 shell 命令。
abstract class FileBackend {
  // ── 浏览 ──
  Future<List<FileEntry>> list(String directory);
  Future<List<FileEntry>> search(String directory, String keyword);

  // ── 数据与操作（签名保持批量：设备端一次 shell 往返）──
  Future<Uint8List> readBytes(String path, {required int maxBytes});
  Future<void> writeBytes(String path, List<int> bytes, {int mode = 0x81a4});
  Future<void> remove(Iterable<String> paths);
  Future<void> rename(String from, String to);
  Future<void> createFile(String path);
  Future<void> createDirectory(String path);
  Future<void> chmod(Iterable<String> paths, String mode);
  Future<void> copyTo(Iterable<String> sources, String destination);
  Future<void> moveTo(Iterable<String> sources, String destination);

  /// 取消进行中的操作。本机后端是即时完成的无状态调用，空实现。
  Future<void> abort() async {}

  // ── 路径语义（各后端规则不同，一律经由此层）──
  String get initialPath;
  String normalize(String path);
  String parent(String path);
  String join(String directory, String name);
  String nameOf(String path);
  bool isSafeName(String name);

  /// 浏览栅栏：[next] 越出 [root] 时回到 root。root 为空表示不限制。
  String fence(String? root, String next);

  // ── 能力 ──
  bool get supportsChmod;
  bool get supportsTransfer;
}
