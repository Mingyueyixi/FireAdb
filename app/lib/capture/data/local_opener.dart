import 'dart:io';

import 'package:flutter/services.dart';

class LocalOpenRequest {
  const LocalOpenRequest(
    this.executable,
    this.arguments, {
    this.ignoreExitCode = false,
  });

  final String executable;
  final List<String> arguments;
  final bool ignoreExitCode;
}

LocalOpenRequest? localOpenRequest(
  String path, {
  required bool openFile,
  required String operatingSystem,
}) {
  // Android 没有 xdg-open。打开动作走系统查看器，不进这个命令。
  if (operatingSystem == 'android') return null;
  if (operatingSystem == 'windows') {
    if (openFile) {
      return LocalOpenRequest('cmd.exe', <String>['/c', 'start', '', path]);
    }
    // explorer 打开成功时也会返回 1。
    return LocalOpenRequest('explorer.exe', <String>[
      path,
    ], ignoreExitCode: true);
  }
  if (operatingSystem == 'macos') {
    return LocalOpenRequest('open', <String>[path]);
  }
  return LocalOpenRequest('xdg-open', <String>[path]);
}

const MethodChannel _storageChannel = MethodChannel('fireadb/storage');

/// 应用外部文件目录。调用后系统会建好 `Android/data/<包名>/files`。
Future<String> androidExternalFilesDirectory() async {
  final path = await _storageChannel.invokeMethod<String>(
    'externalFilesDirectory',
  );
  if (path == null || path.isEmpty) {
    throw StateError('没有可写入的日志目录');
  }
  return path;
}

Future<void> openLocalPath(String path, {required bool openFile}) async {
  if (Platform.isAndroid) {
    if (!openFile) {
      throw StateError('无法在系统文件管理器中打开指定目录');
    }
    final opened = await _storageChannel.invokeMethod<bool>('openPath', {
      'path': path,
      'openFile': openFile,
    });
    if (opened == true) return;
    throw StateError('无法打开');
  }
  final request = localOpenRequest(
    path,
    openFile: openFile,
    operatingSystem: Platform.operatingSystem,
  );
  if (request == null) {
    throw StateError('无法打开');
  }
  final result = await Process.run(request.executable, request.arguments);
  if (request.ignoreExitCode || result.exitCode == 0) return;
  final error = result.stderr.toString().trim();
  throw ProcessException(
    request.executable,
    request.arguments,
    error.isEmpty ? 'exit ${result.exitCode}' : error,
    result.exitCode,
  );
}
