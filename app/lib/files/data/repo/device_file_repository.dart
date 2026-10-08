import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libadb/libadb.dart';

import '../../../connection/model/connected_device.dart';
import '../../../files/remote_file_export.dart';
import '../bean/remote_file.dart';
import '../source/remote_file_commands.dart';

class FileOperationCancelled implements Exception {
  const FileOperationCancelled();

  @override
  String toString() => '操作已取消';
}

/// 通过 ADB sync 浏览设备文件，通过 shell 做删除、改名和权限修改。
class DeviceFileRepository {
  DeviceFileRepository(this._device);

  final ConnectedDevice _device;
  ConnectedShell? _shellSession;
  ConnectedSync? _syncSession;
  var _cancelled = false;

  static const _shellTimeout = Duration(seconds: 30);
  static const _slowShellTimeout = Duration(seconds: 120);

  Future<void> abort() async {
    _cancelled = true;
    final shell = _shellSession;
    final sync = _syncSession;
    _shellSession = null;
    _syncSession = null;
    try {
      await shell?.close();
    } catch (_) {}
    try {
      await sync?.close();
    } catch (_) {}
  }

  Future<List<RemoteFile>> list(String directory) async {
    final sync = await _openSync();
    final List<RemoteFile> files;
    try {
      final entries = await sync.client.list(normalizeRemotePath(directory));
      await _quit(sync);
      files = <RemoteFile>[
        for (final entry in entries)
          if (isSafeRemoteName(entry.name))
            RemoteFile(
              name: entry.name,
              path: joinRemotePath(directory, entry.name),
              mode: entry.mode,
              size: entry.size,
              mtime: entry.mtime,
            ),
      ];
    } catch (_) {
      if (_cancelled) throw const FileOperationCancelled();
      rethrow;
    } finally {
      await _closeSync(sync);
    }
    return _markDirectoryLinks(files);
  }

  Future<List<RemoteFile>> search(String directory, String keyword) async {
    final output = await _shell(
      searchCommand(directory, keyword),
      timeout: _slowShellTimeout,
    );
    return _markDirectoryLinks(parseSearchOutput(output));
  }

  Future<List<RemoteFile>> _markDirectoryLinks(List<RemoteFile> files) async {
    final links = files.where((file) => file.isLink).map((file) => file.path);
    final directories = await _directoryTargets(links);
    final marked = directories.isEmpty
        ? files
        : <RemoteFile>[
            for (final file in files)
              if (directories.contains(file.path))
                file.copyWith(opensAsDirectory: true)
              else
                file,
          ];
    marked.sort(compareRemoteFiles);
    return marked;
  }

  Future<Set<String>> _directoryTargets(Iterable<String> paths) async {
    final list = paths.toList();
    final directories = <String>{};
    const chunkSize = 40;
    for (var offset = 0; offset < list.length; offset += chunkSize) {
      final end = offset + chunkSize > list.length
          ? list.length
          : offset + chunkSize;
      final output = await _shell(
        directoryProbeCommand(list.sublist(offset, end)),
      );
      directories.addAll(parseDirectoryProbe(output));
    }
    return directories;
  }

  Future<void> remove(Iterable<String> paths) async {
    final list = paths.toList();
    if (list.isEmpty) return;
    ensureCommandSuccess(await _shell(deleteCommand(list)));
  }

  Future<void> rename(String from, String to) async {
    ensureCommandSuccess(await _shell(renameCommand(from, to)));
  }

  Future<void> copyTo(Iterable<String> sources, String destination) async {
    final list = sources.toList();
    if (list.isEmpty) return;
    ensureCommandSuccess(await _shell(copyCommand(list, destination)));
  }

  Future<void> moveTo(Iterable<String> sources, String destination) async {
    final list = sources.toList();
    if (list.isEmpty) return;
    ensureCommandSuccess(await _shell(moveCommand(list, destination)));
  }

  Future<void> chmod(Iterable<String> paths, String mode) async {
    final list = paths.toList();
    if (list.isEmpty) return;
    ensureCommandSuccess(await _shell(chmodCommand(list, mode)));
  }

  Future<void> createDirectory(String path) async {
    ensureCommandSuccess(await _shell(mkdirCommand(path)));
  }

  Future<void> createFile(String path) async {
    ensureCommandSuccess(await _shell(touchCommand(path)));
  }

  Future<Uint8List> readBytes(String path, {required int maxBytes}) async {
    final stat = await _stat(path);
    if (stat.mode == 0) throw StateError('文件不存在');
    if (stat.isDirectory) throw StateError('不能把目录当文本打开');
    if (stat.size > maxBytes) {
      throw StateError('文件超过 ${formatFileSize(maxBytes)}');
    }
    final sync = await _openSync();
    try {
      final bytes = await sync.client.pull(path);
      await _quit(sync);
      return bytes;
    } finally {
      await _closeSync(sync);
    }
  }

  Future<void> writeBytes(
    String path,
    List<int> bytes, {
    int mode = 0x81a4,
  }) async {
    final sync = await _openSync();
    try {
      await sync.client.push(bytes, path, mode: mode);
      await _quit(sync);
    } finally {
      await _closeSync(sync);
    }
  }

  Future<void> uploadFile(
    File file,
    String remotePath, {
    void Function(int bytesDone, int bytesTotal)? onProgress,
    bool Function()? isCancelled,
  }) async {
    _ensureActive(isCancelled);
    final length = await file.length();
    final sync = await _openSync();
    RandomAccessFile? reader;
    try {
      reader = await file.open();
      await sync.client.pushFrom(
        () async {
          _ensureActive(isCancelled);
          final chunk = await reader!.read(64 * 1024);
          if (chunk.isEmpty) return null;
          return chunk;
        },
        remotePath,
        totalBytes: length,
        onProgress: onProgress,
      );
      _ensureActive(isCancelled);
      await _quit(sync);
    } catch (_) {
      if (_cancelled || isCancelled?.call() == true) {
        throw const FileOperationCancelled();
      }
      rethrow;
    } finally {
      await reader?.close();
      await _closeSync(sync);
    }
  }

  Future<List<RemoteExportPiece>> planExport(List<RemoteFile> selected) async {
    final sync = await _openSync();
    final pieces = <RemoteExportPiece>[];
    try {
      for (final file in selected) {
        _ensureActive(null);
        await _collect(sync.client, file, file.name, pieces);
      }
      await _quit(sync);
      return pieces;
    } catch (_) {
      if (_cancelled) throw const FileOperationCancelled();
      rethrow;
    } finally {
      await _closeSync(sync);
    }
  }

  Future<void> exportPieces(
    List<RemoteExportPiece> pieces,
    String directory, {
    void Function(int bytesDone, int bytesTotal)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final bytesTotal = pieces.fold<int>(
      0,
      (sum, piece) => sum + (piece.directory ? 0 : piece.size),
    );
    final destDir = Directory(directory);
    await destDir.create(recursive: true);
    var sent = 0;
    for (final piece in pieces) {
      _ensureActive(isCancelled);
      final localPath =
          '${destDir.path}${Platform.pathSeparator}${_localRelative(piece.relativePath)}';
      if (piece.directory) {
        await Directory(localPath).create(recursive: true);
        continue;
      }
      final local = File(localPath);
      await exportRemoteFile(
        remotePath: piece.remotePath,
        localFile: local,
        shell: (command) => _shell(command),
        pullTo: (remote, sink, progress) =>
            _pullTo(remote, sink, onProgress: progress),
        onProgress: (done, _) {
          final current = sent + done;
          onProgress?.call(
            current > bytesTotal ? bytesTotal : current,
            bytesTotal,
          );
        },
        isCancelled: () => _cancelled || (isCancelled?.call() ?? false),
        cancelledException: () => const FileOperationCancelled(),
      );
      sent += piece.size > 0 ? piece.size : 0;
      if (sent > bytesTotal) sent = bytesTotal;
      onProgress?.call(sent, bytesTotal);
    }
  }

  Future<void> _collect(
    AdbSyncClient client,
    RemoteFile file,
    String relative,
    List<RemoteExportPiece> pieces,
  ) async {
    _ensureActive(null);
    if (!file.canEnter) {
      final stat = file.sizeKnown ? null : await client.stat(file.path);
      pieces.add(
        RemoteExportPiece(
          remotePath: file.path,
          relativePath: relative,
          size: stat?.size ?? file.size,
          directory: false,
        ),
      );
      return;
    }
    pieces.add(
      RemoteExportPiece(
        remotePath: file.path,
        relativePath: relative,
        size: 0,
        directory: true,
      ),
    );
    final entries = await client.list(file.path);
    for (final entry in entries) {
      if (entry.name == '.' || entry.name == '..') continue;
      if (!isSafeRemoteName(entry.name)) continue;
      await _collect(
        client,
        RemoteFile(
          name: entry.name,
          path: joinRemotePath(file.path, entry.name),
          mode: entry.mode,
          size: entry.size,
          mtime: entry.mtime,
        ),
        '$relative/${entry.name}',
        pieces,
      );
    }
  }

  Future<AdbFileStat> _stat(String path) async {
    final sync = await _openSync();
    try {
      final stat = await sync.client.stat(path);
      await _quit(sync);
      return stat;
    } finally {
      await _closeSync(sync);
    }
  }

  Future<int> _pullTo(
    String path,
    IOSink sink, {
    void Function(int done, int total)? onProgress,
  }) async {
    final sync = await _openSync();
    try {
      _ensureActive(null);
      final received = await sync.client.pullTo(
        path,
        sink,
        onProgress: onProgress,
      );
      _ensureActive(null);
      await _quit(sync);
      return received;
    } catch (_) {
      if (_cancelled) throw const FileOperationCancelled();
      rethrow;
    } finally {
      await _closeSync(sync);
    }
  }

  Future<ConnectedSync> _openSync() async {
    _ensureActive(null);
    final sync = await _device.openSync();
    _syncSession = sync;
    return sync;
  }

  Future<void> _quit(ConnectedSync sync) async {
    try {
      await sync.client.quit();
    } catch (_) {}
  }

  Future<void> _closeSync(ConnectedSync sync) async {
    if (identical(_syncSession, sync)) _syncSession = null;
    await sync.close();
  }

  Future<String> _shell(String command, {Duration? timeout}) async {
    final shell = await _device.openShell(command);
    _shellSession = shell;
    try {
      _ensureActive(null);
      final bytes = await shell.readStream
          .expand((chunk) => chunk)
          .toList()
          .timeout(timeout ?? _shellTimeout);
      _ensureActive(null);
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      if (_cancelled) throw const FileOperationCancelled();
      rethrow;
    } finally {
      if (identical(_shellSession, shell)) _shellSession = null;
      await shell.close();
    }
  }

  void _ensureActive(bool Function()? isCancelled) {
    if (_cancelled || isCancelled?.call() == true) {
      throw const FileOperationCancelled();
    }
  }

  String _localRelative(String relative) {
    final parts = relative.split('/');
    if (parts.isEmpty || parts.any((part) => !isSafeRemoteName(part))) {
      throw StateError('非法导出路径：$relative');
    }
    return parts.join(Platform.pathSeparator);
  }
}
