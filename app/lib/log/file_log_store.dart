import 'dart:io';

import 'package:logging/logging.dart';

/// 把日志追加到应用目录下的 `logs/fire_adb-yyyy-MM-dd.log`。
class FileLogStore {
  FileLogStore._(this.directory, this._file, this._sink, this._day);

  final Directory directory;
  File _file;
  IOSink _sink;
  DateTime _day;
  Future<void>? _flushing;

  File get file => _file;

  static Future<FileLogStore> openIn(Directory directory) async {
    await directory.create(recursive: false);
    final now = DateTime.now();
    final file = File(_pathFor(directory, now));
    return FileLogStore._(
      directory,
      file,
      file.openWrite(mode: FileMode.append),
      DateTime(now.year, now.month, now.day),
    );
  }

  void write(LogRecord record) {
    try {
      final day = DateTime(
        record.time.year,
        record.time.month,
        record.time.day,
      );
      if (day != _day) _rotate(record.time);
      _sink.writeln(formatLogRecord(record));
      flush();
    } catch (_) {
      // 写文件失败时仍保留控制台输出。
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

  void _rotate(DateTime time) {
    final previous = _sink;
    final pending = _flushing;
    _flushing = null;
    _day = DateTime(time.year, time.month, time.day);
    _file = File(_pathFor(directory, time));
    _sink = _file.openWrite(mode: FileMode.append);
    if (pending != null) {
      pending.then((_) => previous.close()).ignore();
    } else {
      previous.flush().then((_) => previous.close()).ignore();
    }
  }

  static String _pathFor(Directory directory, DateTime time) {
    final month = time.month.toString().padLeft(2, '0');
    final day = time.day.toString().padLeft(2, '0');
    return '${directory.path}${Platform.pathSeparator}'
        'fire_adb-${time.year}-$month-$day.log';
  }
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
