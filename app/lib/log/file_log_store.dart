import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';

/// 一次启动对应一个文件：`logs/fire_adb-yyyy-MM-dd_HH-mm-ss.log`。
class FileLogStore {
  FileLogStore._(this.directory, this._file, this._sink);

  final Directory directory;
  final File _file;
  final IOSink _sink;
  Future<void>? _flushing;

  File get file => _file;

  static Future<FileLogStore> openSession(
    Directory directory,
    DateTime started,
  ) async {
    await directory.create(recursive: false);
    final file = File(
      '${directory.path}${Platform.pathSeparator}${sessionLogFileName(started)}',
    );
    return FileLogStore._(
      directory,
      file,
      file.openWrite(mode: FileMode.append),
    );
  }

  void write(LogRecord record) => writeLine(formatLogRecord(record));

  void writeLine(String line) {
    try {
      _sink.writeln(line);
      flush();
    } catch (_) {
      // 写文件失败时仍保留控制台和内存中的日志。
    }
  }

  Future<void> flush() {
    if (_flushing != null) return _flushing!;
    _flushing = _sink
        .flush()
        .then<void>((_) {}, onError: (Object _) {})
        .whenComplete(() => _flushing = null);
    return _flushing!;
  }

  Future<void> close() async {
    await _flushing;
    await _sink.close();
  }
}

String sessionLogFileName(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return 'fire_adb-${time.year}-${two(time.month)}-${two(time.day)}'
      '_${two(time.hour)}-${two(time.minute)}-${two(time.second)}.log';
}

/// 从 `fire_adb-yyyy-MM-dd_HH-mm-ss.log` 或旧的按日文件名读出开始时间。
DateTime? logFileStarted(String name) {
  final session = RegExp(
    r'^fire_adb-(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})\.log$',
  ).firstMatch(name);
  if (session != null) {
    return _dateFromMatch(session, withClock: true);
  }
  final daily = RegExp(r'^fire_adb-(\d{4})-(\d{2})-(\d{2})\.log$')
      .firstMatch(name);
  if (daily == null) return null;
  return _dateFromMatch(daily, withClock: false);
}

DateTime? _dateFromMatch(RegExpMatch match, {required bool withClock}) {
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final hour = withClock ? int.parse(match.group(4)!) : 0;
  final minute = withClock ? int.parse(match.group(5)!) : 0;
  final second = withClock ? int.parse(match.group(6)!) : 0;
  final time = DateTime(year, month, day, hour, minute, second);
  if (time.year != year || time.month != month || time.day != day) return null;
  if (withClock &&
      (time.hour != hour || time.minute != minute || time.second != second)) {
    return null;
  }
  return time;
}

/// 删掉早于 [retentionDays] 的日志。正在写入的 [keepName] 保留。
Future<int> deleteExpiredLogFiles(
  Directory directory, {
  required int retentionDays,
  required DateTime now,
  String? keepName,
}) async {
  if (!await directory.exists()) return 0;
  final cutoff = now.subtract(Duration(days: retentionDays));
  var removed = 0;
  await for (final entity in directory.list()) {
    if (entity is! File) continue;
    final name = _fileName(entity);
    if (name == keepName) continue;
    final started = logFileStarted(name);
    if (started == null || !started.isBefore(cutoff)) continue;
    if (await _deleteLogFile(entity)) removed++;
  }
  return removed;
}

/// 删掉目录里全部日志文件。
Future<int> deleteAllLogFiles(Directory directory) async {
  if (!await directory.exists()) return 0;
  var removed = 0;
  await for (final entity in directory.list()) {
    if (entity is! File) continue;
    if (logFileStarted(_fileName(entity)) == null) continue;
    if (await _deleteLogFile(entity)) removed++;
  }
  return removed;
}

Future<bool> _deleteLogFile(File file) async {
  try {
    await file.delete();
    return true;
  } on FileSystemException {
    return false;
  }
}

String _fileName(File file) {
  final separator = Platform.pathSeparator;
  final index = file.path.lastIndexOf(separator);
  return index < 0 ? file.path : file.path.substring(index + 1);
}

String formatLogTime(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  final milli = time.millisecond.toString().padLeft(3, '0');
  return '${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}:${two(time.second)}.$milli';
}

String formatLogRecord(LogRecord record) {
  final buffer = StringBuffer(
    '${formatLogTime(record.time)} ${record.level.name} '
    '${record.loggerName} ${record.message}',
  );
  if (record.error != null) buffer.write('\n${record.error}');
  if (record.stackTrace != null) buffer.write('\n${record.stackTrace}');
  return buffer.toString();
}

/// 当前这次启动的日志。页面直接看这里，不读文件。
class SessionLogBuffer {
  SessionLogBuffer({this.maxCharacters = 256 * 1024});

  int maxCharacters;
  final List<String> lines = <String>[];
  var truncated = false;
  var _characters = 0;
  final List<void Function()> _listeners = <void Function()>[];
  var _notifyScheduled = false;

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void add(String line) {
    lines.add(line);
    _characters += line.length;
    if (_trim()) truncated = true;
    _scheduleNotify();
  }

  void setMaxCharacters(int value) {
    if (value < 1 || value == maxCharacters) return;
    maxCharacters = value;
    if (_trim()) truncated = true;
    _scheduleNotify();
  }

  void clear() {
    lines.clear();
    _characters = 0;
    truncated = false;
    _scheduleNotify();
  }

  bool _trim() {
    var removed = false;
    while (_characters > maxCharacters && lines.length > 1) {
      _characters -= lines.removeAt(0).length;
      removed = true;
    }
    return removed;
  }

  void _scheduleNotify() {
    if (_notifyScheduled || _listeners.isEmpty) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      final listeners = List<void Function()>.of(_listeners);
      for (final listener in listeners) {
        listener();
      }
    });
  }
}
