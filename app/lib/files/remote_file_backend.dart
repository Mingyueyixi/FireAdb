import 'dart:io';
import 'dart:typed_data';

import 'package:get/get.dart';

import '../apps/data/source/run_as_files.dart';
import '../connection/connection_manager.dart';
import 'data/repo/device_file_repository.dart';
import 'data/source/remote_file_commands.dart';
import 'file_backend.dart';
import 'file_entry.dart';
import 'remote_file.dart';

/// 浏览栅栏：[nextPath] 越出 [root] 时回到 root。root 为空表示不限制。
String fencedRemotePath(String? root, String nextPath) {
  final target = normalizeRemotePath(nextPath);
  if (root == null) return target;
  final fence = normalizeRemotePath(root);
  return isWithinAppRoot(fence, target) ? target : fence;
}

/// ADB 设备文件系统后端。包装 [DeviceFileRepository]：
/// 每次操作新建一个仓库实例（内部自管 sync/root shell 连接），与原控制器行为一致。
class RemoteFileBackend extends FileBackend {
  RemoteFileBackend(this.serial, {this.host, this.adbSerial});

  final String serial;
  final String? host;
  final String? adbSerial;

  /// 最近一次创建的仓库。传输类操作进行中时由 [abort] 取消。
  DeviceFileRepository? _active;

  DeviceFileRepository? _repository() {
    final manager = Get.find<ConnectionManager>();
    final device = manager.deviceOf(serial);
    if (device == null) return null;
    final profile = manager.profileOf(serial);
    return DeviceFileRepository(
      device,
      host: profile?.host,
      adbSerial: profile?.adbSerial,
    );
  }

  DeviceFileRepository _require() {
    final repo = _repository();
    if (repo == null) throw const DeviceNotConnectedException();
    _active = repo;
    return repo;
  }

  /// 导出到主机/上传是远端独有的跨机传输，控制器在做能力判断后使用。
  Future<List<RemoteExportPiece>> planExport(List<FileEntry> files) {
    return _require().planExport(<RemoteFile>[
      for (final file in files) file as RemoteFile,
    ]);
  }

  Future<void> exportPieces(
    List<RemoteExportPiece> pieces,
    String directory, {
    required bool Function() isCancelled,
    required void Function(int bytesDone, int bytesTotal) onProgress,
  }) => _require().exportPieces(
    pieces,
    directory,
    isCancelled: isCancelled,
    onProgress: onProgress,
  );

  Future<void> uploadFile(
    File file,
    String remotePath, {
    required bool Function() isCancelled,
    required void Function(int bytesDone, int bytesTotal) onProgress,
  }) => _require().uploadFile(
    file,
    remotePath,
    isCancelled: isCancelled,
    onProgress: onProgress,
  );

  @override
  String get initialPath => remoteStoragePath;

  @override
  bool get supportsChmod => true;

  @override
  bool get supportsTransfer => true;

  @override
  String normalize(String path) => normalizeRemotePath(path);

  @override
  String parent(String path) => parentRemotePath(path);

  @override
  String join(String directory, String name) => joinRemotePath(directory, name);

  @override
  String nameOf(String path) => remoteBaseName(path);

  @override
  bool isSafeName(String name) => isSafeRemoteName(name);

  @override
  String fence(String? root, String next) => fencedRemotePath(root, next);

  @override
  Future<List<FileEntry>> list(String directory) =>
      _require().list(directory);

  @override
  Future<List<FileEntry>> search(String directory, String keyword) =>
      _require().search(directory, keyword);

  @override
  Future<Uint8List> readBytes(String path, {required int maxBytes}) =>
      _require().readBytes(path, maxBytes: maxBytes);

  @override
  Future<void> writeBytes(
    String path,
    List<int> bytes, {
    int mode = 0x81a4,
  }) => _require().writeBytes(path, bytes, mode: mode);

  @override
  Future<void> remove(Iterable<String> paths) => _require().remove(paths);

  @override
  Future<void> rename(String from, String to) => _require().rename(from, to);

  @override
  Future<void> createFile(String path) => _require().createFile(path);

  @override
  Future<void> createDirectory(String path) =>
      _require().createDirectory(path);

  @override
  Future<void> chmod(Iterable<String> paths, String mode) =>
      _require().chmod(paths, mode);

  @override
  Future<void> copyTo(Iterable<String> sources, String destination) =>
      _require().copyTo(sources, destination);

  @override
  Future<void> moveTo(Iterable<String> sources, String destination) =>
      _require().moveTo(sources, destination);

  @override
  Future<void> abort() async {
    final repo = _active;
    _active = null;
    try {
      await repo?.abort();
    } catch (_) {}
  }
}
