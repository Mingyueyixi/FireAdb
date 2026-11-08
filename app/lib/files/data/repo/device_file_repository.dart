import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:get/get.dart';
import 'package:libadb/libadb.dart';

import '../../../apps/data/source/run_as_files.dart';
import '../../../connection/local_adb_target.dart';
import '../../../connection/model/connected_device.dart';
import '../../../files/remote_file_export.dart';
import '../../../shell/root_shell.dart';
import '../../remote_file.dart';
import '../source/remote_file_commands.dart';

class FileOperationCancelled implements Exception {
  const FileOperationCancelled();

  @override
  String toString() => '操作已取消';
}

/// 浏览和修改设备文件。普通路径走 sync，文件 su 走 root shell。
/// 应用私有目录在 adb root 时仍走 sync；只有应用 su 时走应用 root；
/// 都没有时用 `run-as`。调用方只看到列目录、读字节、写字节和删除。
class DeviceFileRepository {
  DeviceFileRepository(this._device, {this.host, this.adbSerial});

  final ConnectedDevice _device;
  final String? host;
  final String? adbSerial;
  ConnectedShell? _shellSession;
  ConnectedSync? _syncSession;
  final LocalCopyHandle _localCopy = LocalCopyHandle();
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
      await _localCopy.close();
    } catch (_) {}
    try {
      await shell?.close();
    } catch (_) {}
    try {
      await sync?.close();
    } catch (_) {}
  }

  Future<List<RemoteFile>> list(String directory) async {
    if (commandUsesSu(_device, SuScope.files) || _usesIdentity(directory)) {
      final output = await _exec(rootListCommand(directory), directory);
      final files = parseRootList(output, directory);
      final failure = rootListFailure(output);
      if (failure != null && files.isEmpty) throw StateError(failure);
      return _markDirectoryLinks(files, directory);
    }
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
    return _markDirectoryLinks(files, directory);
  }

  Future<List<RemoteFile>> search(String directory, String keyword) async {
    final output = await _exec(
      searchCommand(directory, keyword),
      directory,
      timeout: _slowShellTimeout,
    );
    return _markDirectoryLinks(parseSearchOutput(output), directory);
  }

  Future<List<RemoteFile>> _markDirectoryLinks(
    List<RemoteFile> files,
    String scope,
  ) async {
    final links = files.where((file) => file.isLink).map((file) => file.path);
    final directories = await _directoryTargets(links, scope);
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

  Future<Set<String>> _directoryTargets(
    Iterable<String> paths,
    String scope,
  ) async {
    final list = paths.toList();
    final directories = <String>{};
    const chunkSize = 40;
    for (var offset = 0; offset < list.length; offset += chunkSize) {
      final end = offset + chunkSize > list.length
          ? list.length
          : offset + chunkSize;
      final output = await _exec(
        directoryProbeCommand(list.sublist(offset, end)),
        scope,
      );
      directories.addAll(parseDirectoryProbe(output));
    }
    return directories;
  }

  Future<void> remove(Iterable<String> paths) async {
    final list = paths.toList();
    if (list.isEmpty) return;
    ensureCommandSuccess(await _exec(deleteCommand(list), list.first));
  }

  Future<void> rename(String from, String to) async {
    ensureCommandSuccess(await _exec(renameCommand(from, to), from));
  }

  Future<void> copyTo(Iterable<String> sources, String destination) async {
    final list = sources.toList();
    if (list.isEmpty) return;
    ensureCommandSuccess(
      await _exec(copyCommand(list, destination), list.first),
    );
  }

  Future<void> moveTo(Iterable<String> sources, String destination) async {
    final list = sources.toList();
    if (list.isEmpty) return;
    ensureCommandSuccess(
      await _exec(moveCommand(list, destination), list.first),
    );
  }

  Future<void> chmod(Iterable<String> paths, String mode) async {
    final list = paths.toList();
    if (list.isEmpty) return;
    ensureCommandSuccess(await _exec(chmodCommand(list, mode), list.first));
  }

  Future<void> createDirectory(String path) async {
    ensureCommandSuccess(await _exec(mkdirCommand(path), path));
  }

  Future<void> createFile(String path) async {
    ensureCommandSuccess(await _exec(touchCommand(path), path));
  }

  Future<Uint8List> readBytes(String path, {required int maxBytes}) async {
    if (_usesIdentity(path)) return _readViaShell(path, maxBytes: maxBytes);
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
    if (_usesIdentity(path)) {
      await _writeViaShell(path, bytes);
      return;
    }
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
    if (_usesIdentity(remotePath)) {
      await _uploadViaShell(
        file,
        remotePath,
        length: length,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
      return;
    }
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
    final pieces = <RemoteExportPiece>[];
    final identity = <RemoteFile>[];
    final synced = <RemoteFile>[];
    for (final file in selected) {
      if (_usesIdentity(file.path)) {
        identity.add(file);
      } else {
        synced.add(file);
      }
    }
    for (final file in identity) {
      _ensureActive(null);
      await _collectListed(file, file.name, pieces);
    }
    if (synced.isEmpty) return pieces;
    final sync = await _openSync();
    try {
      for (final file in synced) {
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
    await Directory(directory).create(recursive: true);
    final names = ExportDestination(directory);
    final copyLocally = shouldCopyLocally(
      runningOnAndroid: Platform.isAndroid,
      host: host,
      serial: _device.serial,
      adbSerial: adbSerial,
    );
    var sent = 0;
    for (final piece in pieces) {
      _ensureActive(isCancelled);
      final localPath = await names.pathFor(piece.relativePath);
      if (piece.directory) {
        await Directory(localPath).create(recursive: true);
        continue;
      }
      final local = File(localPath);
      if (copyLocally) {
        final copied = await copyLocalFile(
          source: File(piece.remotePath),
          destination: local,
          onProgress: (done, _) {
            final current = sent + done;
            onProgress?.call(
              current > bytesTotal ? bytesTotal : current,
              bytesTotal,
            );
          },
          isCancelled: () => _cancelled || (isCancelled?.call() ?? false),
          cancelledException: () => const FileOperationCancelled(),
          copyHandle: _localCopy,
        );
        sent += piece.size > 0 ? piece.size : copied.bytes;
        if (sent > bytesTotal) sent = bytesTotal;
        onProgress?.call(sent, bytesTotal);
        continue;
      }
      await exportRemoteFile(
        remotePath: piece.remotePath,
        localFile: local,
        shell: (command) => _exec(command, piece.remotePath),
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
    if (_usesIdentity(path)) return _pullViaShell(path, sink, onProgress);
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

  /// sync 不是该路径的身份时，读写必须走 shell。adb root 后 sync 本身就是 root。
  bool _usesIdentity(String path) {
    if (!isPrivateAppDataPath(path)) return false;
    if (!Get.isRegistered<DeviceRootStore>()) return true;
    return !Get.find<DeviceRootStore>().isAdbRootActive(_device.serial);
  }

  Future<String> _wrap(String command, String path) async {
    if (commandUsesSu(_device, SuScope.files) || !_usesIdentity(path)) {
      return rootCommand(_device, command, scope: SuScope.files);
    }
    if (rootCanEditAppData(_device.serial)) {
      return rootCommand(_device, command, scope: SuScope.apps);
    }
    final packageName = packageOfPrivatePath(path);
    if (packageName == null) {
      return rootCommand(_device, command, scope: SuScope.files);
    }
    return 'run-as ${quoteRemotePath(packageName)} sh -c ${quoteRemotePath(command)}';
  }

  Future<Uint8List> _readViaShell(String path, {required int maxBytes}) async {
    final output = await _exec('ls -ld ${quoteRemotePath(path)}', path);
    final files = parseRootList(output, parentRemotePath(path));
    final failure = rootListFailure(output);
    if (failure != null && files.isEmpty) throw StateError(failure);
    if (files.isEmpty) throw StateError('文件不存在');
    final file = files.first;
    if (file.isDirectory) throw StateError('不能把目录当文本打开');
    if (file.sizeKnown && file.size > maxBytes) {
      throw StateError('文件超过 ${formatFileSize(maxBytes)}');
    }
    final bytes = await _device.execOut(
      await _wrap('cat ${quoteRemotePath(path)}', path),
    );
    if (bytes.length > maxBytes) {
      throw StateError('文件超过 ${formatFileSize(maxBytes)}');
    }
    return bytes;
  }

  Future<void> _writeViaShell(String path, List<int> bytes) async {
    final shell = await _device.openShell(
      await _wrap('cat > ${quoteRemotePath(path)}', path),
    );
    _shellSession = shell;
    try {
      _ensureActive(null);
      if (bytes.isNotEmpty) await shell.write(bytes);
      _ensureActive(null);
    } catch (_) {
      if (_cancelled) throw const FileOperationCancelled();
      rethrow;
    } finally {
      if (identical(_shellSession, shell)) _shellSession = null;
      await shell.close();
    }
  }

  Future<void> _uploadViaShell(
    File file,
    String remotePath, {
    required int length,
    void Function(int bytesDone, int bytesTotal)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final shell = await _device.openShell(
      await _wrap('cat > ${quoteRemotePath(remotePath)}', remotePath),
    );
    _shellSession = shell;
    RandomAccessFile? reader;
    try {
      reader = await file.open();
      var done = 0;
      onProgress?.call(0, length);
      while (true) {
        _ensureActive(isCancelled);
        final chunk = await reader.read(kFileIoBufferSize);
        if (chunk.isEmpty) break;
        await shell.write(chunk);
        done += chunk.length;
        onProgress?.call(done, length);
      }
    } catch (_) {
      if (_cancelled || isCancelled?.call() == true) {
        throw const FileOperationCancelled();
      }
      rethrow;
    } finally {
      await reader?.close();
      if (identical(_shellSession, shell)) _shellSession = null;
      await shell.close();
    }
  }

  Future<int> _pullViaShell(
    String path,
    IOSink sink,
    void Function(int done, int total)? onProgress,
  ) async {
    final shell = await _device.openShell(
      await _wrap('cat ${quoteRemotePath(path)}', path),
    );
    _shellSession = shell;
    try {
      var received = 0;
      await for (final chunk in shell.readStream) {
        _ensureActive(null);
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, 0);
      }
      return received;
    } catch (_) {
      if (_cancelled) throw const FileOperationCancelled();
      rethrow;
    } finally {
      if (identical(_shellSession, shell)) _shellSession = null;
      await shell.close();
    }
  }

  Future<void> _collectListed(
    RemoteFile file,
    String relative,
    List<RemoteExportPiece> pieces,
  ) async {
    _ensureActive(null);
    if (!file.canEnter) {
      pieces.add(
        RemoteExportPiece(
          remotePath: file.path,
          relativePath: relative,
          size: file.size,
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
    final children = await list(file.path);
    for (final child in children) {
      await _collectListed(child, '$relative/${child.name}', pieces);
    }
  }

  Future<String> _exec(String command, String path, {Duration? timeout}) {
    return _rawShell(() => _wrap(command, path), timeout: timeout);
  }

  Future<String> _rawShell(
    Future<String> Function() command, {
    Duration? timeout,
  }) async {
    final shell = await _device.openShell(await command());
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
}
