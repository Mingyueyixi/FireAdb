import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 本地复制和校验的读写块。和 ADB sync 的单帧一样是 64KB，进度也按这一块回调。
const int kFileIoBufferSize = 64 * 1024;

/// 把设备上的一个文件拉到本地，并用 `md5sum` 与本地文件比对。
///
/// 应用导出和其他文件导出都走这里。调用方提供 [shell] 与 [pullTo]，
/// 这样取消时仍由持有连接的那一层关掉 shell 或 sync。
Future<ExportedRemoteFile> exportRemoteFile({
  required String remotePath,
  required File localFile,
  required Future<String> Function(String command) shell,
  required RemoteFilePull pullTo,
  void Function(int bytesDone, int bytesTotal)? onProgress,
  bool Function()? isCancelled,
  Exception Function()? cancelledException,
}) async {
  _ensureActive(isCancelled, cancelledException);
  await localFile.parent.create(recursive: true);
  final sink = localFile.openWrite();
  var received = 0;
  Object? pullError;
  try {
    received = await pullTo(remotePath, sink, onProgress);
    _ensureActive(isCancelled, cancelledException);
  } catch (error) {
    pullError = error;
    rethrow;
  } finally {
    await sink.flush();
    await sink.close();
    if (pullError != null) await _deleteQuietly(localFile);
  }

  try {
    _ensureActive(isCancelled, cancelledException);
    final remoteMd5 = await readRemoteMd5(shell, remotePath);
    _ensureActive(isCancelled, cancelledException);
    final localMd5 = await md5HexOfFile(localFile);
    if (remoteMd5 != localMd5) {
      throw RemoteFileChecksumException(
        'MD5 不一致：$remotePath（设备 $remoteMd5，本地 $localMd5）',
      );
    }
    return ExportedRemoteFile(
      file: localFile,
      remotePath: remotePath,
      bytes: received,
      md5: localMd5,
    );
  } catch (error) {
    await _deleteQuietly(localFile);
    rethrow;
  }
}

/// 执行 `md5sum` 并解析 32 位十六进制摘要。
Future<String> readRemoteMd5(
  Future<String> Function(String command) shell,
  String remotePath,
) async {
  final output = await shell('md5sum ${_quoteShellPath(remotePath)}');
  final digest = parseMd5Sum(output);
  if (digest == null) {
    final detail = output.trim();
    throw RemoteFileChecksumException(
      detail.isEmpty
          ? '无法读取 $remotePath 的 MD5'
          : '无法读取 $remotePath 的 MD5：$detail',
    );
  }
  return digest;
}

/// 解析 `md5sum` 输出。兼容 `hash  path` 与 `hash *path`。
String? parseMd5Sum(String output) {
  for (final raw in output.split(RegExp(r'\r?\n'))) {
    final match = RegExp(r'^([0-9a-fA-F]{32})\s').firstMatch(raw.trim());
    if (match != null) return match.group(1)!.toLowerCase();
  }
  return null;
}

/// 按块计算本地文件的 MD5，不把整个文件读进内存。
///
/// [attach] 把关闭句柄交给调用方。取消时关掉文件，当前这次读取会结束。
Future<String> md5HexOfFile(
  File file, {
  bool Function()? isCancelled,
  Exception Function()? cancelledException,
  void Function(Future<void> Function() close)? attach,
  void Function()? detach,
}) async {
  final input = await file.open();
  final digestSink = _DigestSink();
  final hash = md5.startChunkedConversion(digestSink);
  final buffer = Uint8List(kFileIoBufferSize);
  var closed = false;
  Future<void> closeFile() async {
    if (closed) return;
    closed = true;
    try {
      await input.close();
    } catch (_) {}
  }

  attach?.call(closeFile);
  try {
    while (true) {
      _ensureActive(isCancelled, cancelledException);
      final count = await input.readInto(buffer);
      if (count == 0) break;
      hash.add(Uint8List.sublistView(buffer, 0, count));
    }
  } catch (error) {
    if (isCancelled?.call() == true) {
      throw cancelledException?.call() ?? const RemoteFileExportCancelled();
    }
    rethrow;
  } finally {
    detach?.call();
    await closeFile();
  }
  hash.close();
  return digestSink.value.toString();
}

/// 一次本地读写。取消时关掉正在读或写的文件，不等当前这一块自己结束。
class LocalCopyHandle {
  Future<void> Function()? _close;

  void attach(Future<void> Function() close) {
    _close = close;
  }

  void detach() {
    _close = null;
  }

  Future<void> close() async {
    final close = _close;
    _close = null;
    if (close == null) return;
    try {
      await close();
    } catch (_) {}
  }
}

/// 本机路径之间复制，并按已写入字节回报进度。源和目标都在这块磁盘上，不经过 ADB。
Future<ExportedRemoteFile> copyLocalFile({
  required File source,
  required File destination,
  void Function(int bytesDone, int bytesTotal)? onProgress,
  bool Function()? isCancelled,
  Exception Function()? cancelledException,
  LocalCopyHandle? copyHandle,
}) async {
  _ensureActive(isCancelled, cancelledException);
  final total = await source.length();
  if (_sameLocalPath(source.path, destination.path)) {
    onProgress?.call(total, total);
    final digest = await md5HexOfFile(
      source,
      isCancelled: isCancelled,
      cancelledException: cancelledException,
      attach: copyHandle?.attach,
      detach: copyHandle?.detach,
    );
    return ExportedRemoteFile(
      file: destination,
      remotePath: source.path,
      bytes: total,
      md5: digest,
    );
  }
  await destination.parent.create(recursive: true);
  final input = await source.open();
  RandomAccessFile? output;
  final digestSink = _DigestSink();
  final hash = md5.startChunkedConversion(digestSink);
  final buffer = Uint8List(kFileIoBufferSize);
  var copied = 0;
  var closed = false;
  Future<void> closeFiles() async {
    if (closed) return;
    closed = true;
    try {
      await input.close();
    } catch (_) {}
    try {
      await output?.close();
    } catch (_) {}
  }

  Object? failure;
  try {
    output = await destination.open(mode: FileMode.write);
    copyHandle?.attach(closeFiles);
    while (true) {
      _ensureActive(isCancelled, cancelledException);
      final count = await input.readInto(buffer);
      if (count == 0) break;
      hash.add(Uint8List.sublistView(buffer, 0, count));
      await output.writeFrom(buffer, 0, count);
      copied += count;
      final done = total > 0 && copied > total ? total : copied;
      onProgress?.call(done, total);
    }
    _ensureActive(isCancelled, cancelledException);
  } catch (error) {
    failure = isCancelled?.call() == true
        ? (cancelledException?.call() ?? const RemoteFileExportCancelled())
        : error;
    throw failure;
  } finally {
    copyHandle?.detach();
    await closeFiles();
    if (failure != null) await _deleteQuietly(destination);
  }
  hash.close();
  try {
    _ensureActive(isCancelled, cancelledException);
    final sourceMd5 = digestSink.value.toString();
    final destinationMd5 = await md5HexOfFile(
      destination,
      isCancelled: isCancelled,
      cancelledException: cancelledException,
      attach: copyHandle?.attach,
      detach: copyHandle?.detach,
    );
    if (sourceMd5 != destinationMd5) {
      throw RemoteFileChecksumException(
        'MD5 不一致：${source.path}（来源 $sourceMd5，目标 $destinationMd5）',
      );
    }
    onProgress?.call(total, total);
    return ExportedRemoteFile(
      file: destination,
      remotePath: source.path,
      bytes: copied,
      md5: destinationMd5,
    );
  } catch (error) {
    await _deleteQuietly(destination);
    rethrow;
  }
}

bool _sameLocalPath(String left, String right) {
  return _normalizeLocalPath(left) == _normalizeLocalPath(right);
}

String _normalizeLocalPath(String path) {
  var value = path.trim().replaceAll(r'\', '/');
  if (value.length > 1 && value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

typedef RemoteFilePull = Future<int> Function(
  String remotePath,
  IOSink sink,
  void Function(int bytesDone, int bytesTotal)? onProgress,
);

class ExportedRemoteFile {
  const ExportedRemoteFile({
    required this.file,
    required this.remotePath,
    required this.bytes,
    required this.md5,
  });

  final File file;
  final String remotePath;
  final int bytes;
  final String md5;
}

class _DigestSink implements Sink<Digest> {
  Digest? _value;

  Digest get value {
    final digest = _value;
    if (digest == null) {
      throw StateError('摘要尚未完成');
    }
    return digest;
  }

  @override
  void add(Digest data) {
    _value = data;
  }

  @override
  void close() {}
}

class RemoteFileChecksumException implements Exception {
  RemoteFileChecksumException(this.message);

  final String message;

  @override
  String toString() => message;
}

class RemoteFileExportCancelled implements Exception {
  const RemoteFileExportCancelled();

  @override
  String toString() => '导出已取消';
}

void _ensureActive(
  bool Function()? isCancelled,
  Exception Function()? cancelledException,
) {
  if (isCancelled?.call() != true) return;
  throw cancelledException?.call() ?? const RemoteFileExportCancelled();
}

/// 在导出目录里分配不会盖住已有文件的路径。
///
/// 同名时按 `name (2).ext`、`name (3).ext` 递增。目录导出只改第一段，
/// 里面的相对路径保持不变，避免写进已经存在的那个目录。
class ExportDestination {
  ExportDestination(this.directory);

  final String directory;
  final Set<String> _takenRoots = {};
  String? _sourceRoot;
  String? _destRoot;

  Future<String> pathFor(String relative) async {
    final parts = relative.split('/');
    if (parts.isEmpty ||
        parts.any(
          (part) =>
              part.isEmpty ||
              part == '.' ||
              part == '..' ||
              part.contains('\u0000'),
        )) {
      throw ArgumentError.value(relative, 'relative', '非法导出路径');
    }
    if (parts.length == 1) {
      _sourceRoot = parts.single;
      _destRoot = await availableName(parts.single);
      _takenRoots.add(_destRoot!);
      parts[0] = _destRoot!;
    } else if (parts.first == _sourceRoot && _destRoot != null) {
      parts[0] = _destRoot!;
    } else {
      final sourceRoot = parts.first;
      final destRoot = await availableName(sourceRoot);
      _takenRoots.add(destRoot);
      _sourceRoot = sourceRoot;
      _destRoot = destRoot;
      parts[0] = destRoot;
    }
    return [directory, ...parts].join(Platform.pathSeparator);
  }

  Future<String> availableName(String name) async {
    final chosen = await _candidate(name);
    _takenRoots.add(chosen);
    return chosen;
  }

  Future<String> _candidate(String name) async {
    if (await _isFree(name)) return name;
    final dot = name.lastIndexOf('.');
    final hasExtension = dot > 0;
    final stem = hasExtension ? name.substring(0, dot) : name;
    final extension = hasExtension ? name.substring(dot) : '';
    for (var index = 2; index < 10000; index++) {
      final candidate = '$stem ($index)$extension';
      if (await _isFree(candidate)) return candidate;
    }
    throw StateError('无法为 $name 分配不重复的名字');
  }

  Future<bool> _isFree(String name) async {
    if (_takenRoots.contains(name)) return false;
    final path = [directory, name].join(Platform.pathSeparator);
    final type = await FileSystemEntity.type(path);
    return type == FileSystemEntityType.notFound;
  }
}

Future<void> _deleteQuietly(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {}
}

String _quoteShellPath(String value) => "'${value.replaceAll("'", r"'\''")}'";
