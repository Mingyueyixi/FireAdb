import 'dart:io';

import 'package:crypto/crypto.dart';

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

/// 按流计算本地文件的 MD5，不把整个文件读进内存。
Future<String> md5HexOfFile(File file) async {
  final digest = await md5.bind(file.openRead()).first;
  return digest.toString();
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

Future<void> _deleteQuietly(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {}
}

String _quoteShellPath(String value) => "'${value.replaceAll("'", r"'\''")}'";
