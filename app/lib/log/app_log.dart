import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import '../capture/data/local_opener.dart';
import 'file_log_store.dart';
import 'log_paths.dart';

/// 应用日志。各处直接使用这个官方 [Logger]。
final Logger log = Logger('fire_adb');

/// 当前日志目录。安装成功后可直接使用，否则再按平台规则计算。
String? logDirectoryPath;

FileLogStore? _fileStore;
var _consoleAttached = false;

/// 把本应用和 adb_core 的根日志接到调试控制台，并写入日志目录。
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
    final store = await FileLogStore.openIn(Directory(path));
    Logger.root.onRecord.listen((record) {
      if (!_isAppRecord(record)) return;
      store.write(record);
    });
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

void _attachConsole() {
  if (_consoleAttached) return;
  _consoleAttached = true;
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    if (!_isAppRecord(record)) return;
    debugPrint(formatLogRecord(record));
  });
}

bool _isAppRecord(LogRecord record) {
  final name = record.loggerName;
  return name == 'fire_adb' ||
      name.startsWith('fire_adb.') ||
      name == 'adb_core' ||
      name.startsWith('adb_core.');
}
