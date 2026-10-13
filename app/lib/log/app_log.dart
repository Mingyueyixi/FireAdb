import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import '../capture/data/local_opener.dart';
import '../files/android_storage_access.dart';
import 'file_log_store.dart';
import 'log_paths.dart';

/// 应用日志。各处直接使用这个官方 [Logger]。
final Logger log = Logger('fire_adb');

/// 当前这次启动已经产生的日志，供日志页实时显示。
final SessionLogBuffer sessionLog = SessionLogBuffer();

/// 当前日志目录。安装成功后可直接使用，否则再按平台规则计算。
String? logDirectoryPath;

FileLogStore? _fileStore;
var _consoleAttached = false;

/// 把本应用和 adb_core 的根日志接到调试控制台、内存和日志文件。
Future<FileLogStore?> installAppLogger() async {
  _attachConsole();
  return attachFileLogStore();
}

/// 目录刚变得可写时再接上文件。已经接上则直接返回。
Future<FileLogStore?> attachFileLogStore() async {
  final existing = _fileStore;
  if (existing != null) return existing;
  _attachConsole();
  try {
    final path = await ensureLogDirectory(create: true);
    if (path == null) {
      throw StateError('没有可写入的日志目录');
    }
    logDirectoryPath = path;
    final store = await FileLogStore.openSession(
      Directory(path),
      DateTime.now(),
    );
    _fileStore = store;
    log.info('日志文件：${store.file.path}');
    return store;
  } catch (error, stackTrace) {
    log.severe('打开日志文件失败', error, stackTrace);
    return null;
  }
}

Future<String?> resolveLogDirectory() async {
  final known = logDirectoryPath;
  if (known != null) return known;
  try {
    final path = await ensureLogDirectory(create: Platform.isAndroid);
    logDirectoryPath = path;
    return path;
  } on MissingPluginException {
    return null;
  } catch (error, stackTrace) {
    log.severe('解析日志目录失败', error, stackTrace);
    return null;
  }
}

Future<String?> ensureLogDirectory({required bool create}) async {
  if (Platform.isAndroid) {
    final root = await androidExternalFilesDirectory();
    final logs = Directory('$root/$kLogFolderName');
    if (create) await logs.create(recursive: false);
    return logs.path;
  }
  final path = logDirectoryPathFor(
    operatingSystem: Platform.operatingSystem,
    environment: Platform.environment,
  );
  if (path == null) return null;
  if (create) await Directory(path).create(recursive: true);
  return path;
}

/// 按设置里的保存天数，在启动时删掉过期日志。当前正在写的文件保留。
Future<void> pruneExpiredLogs(int retentionDays) async {
  final path = logDirectoryPath ?? await resolveLogDirectory();
  if (path == null) return;
  final removed = await deleteExpiredLogFiles(
    Directory(path),
    retentionDays: retentionDays,
    now: DateTime.now(),
    keepName: _fileStore == null ? null : _fileName(_fileStore!.file),
  );
  if (removed > 0) log.info('已删除 $removed 个过期日志');
}

/// 删掉目录里的日志文件，并重新打开本次启动的写入文件。页面上的内容不动。
Future<void> deleteSavedLogs() async {
  final path = await ensureLogDirectory(create: true);
  if (path == null) {
    throw StateError('没有可写入的日志目录');
  }
  final current = _fileStore;
  _fileStore = null;
  if (current != null) await current.close();
  await deleteAllLogFiles(Directory(path));
  logDirectoryPath = path;
  _fileStore = await FileLogStore.openSession(Directory(path), DateTime.now());
  log.info('日志文件已清理');
}

/// 打开日志目录。安卓上先确认文件访问权限。
Future<String?> openSavedLogDirectory(BuildContext context) async {
  if (Platform.isAndroid) {
    final granted = await ensureAllFilesAccess(context);
    if (!granted || !context.mounted) return null;
  }
  final directory = await ensureLogDirectory(create: true);
  if (directory == null) return null;
  logDirectoryPath = directory;
  await attachFileLogStore();
  await openSystemDirectory(directory);
  return directory;
}

String _fileName(File file) {
  final separator = Platform.pathSeparator;
  final index = file.path.lastIndexOf(separator);
  return index < 0 ? file.path : file.path.substring(index + 1);
}

void _attachConsole() {
  if (_consoleAttached) return;
  _consoleAttached = true;
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    if (!_isAppRecord(record)) return;
    final line = formatLogRecord(record);
    debugPrint(line);
    sessionLog.add(line);
    _fileStore?.writeLine(line);
  });
}

bool _isAppRecord(LogRecord record) {
  final name = record.loggerName;
  return name == 'fire_adb' ||
      name.startsWith('fire_adb.') ||
      name == 'adb_core' ||
      name.startsWith('adb_core.');
}
