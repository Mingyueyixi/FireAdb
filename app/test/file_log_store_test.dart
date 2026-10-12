import 'dart:io';

import 'package:fire_adb/log/file_log_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

void main() {
  test('日志时间省略年份，毫秒保留三位', () {
    expect(
      formatLogTime(DateTime(2026, 10, 13, 0, 7, 2, 719)),
      '10-13 00:07:02.719',
    );
  });

  test('日志写入应用目录下按日期命名的文件', () async {
    final directory = await Directory.systemTemp.createTemp('fire-adb-logs');
    final store = await FileLogStore.openIn(directory);
    addTearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });

    final now = DateTime.now();
    store.write(LogRecord(Level.INFO, 'hello log', 'fire_adb'));
    await store.flush();

    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    final text = await store.file.readAsString();
    expect(store.file.path, endsWith('fire_adb-${now.year}-$month-$day.log'));
    expect(
      text,
      matches(
        RegExp(
          r'^\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} INFO fire_adb hello log',
        ),
      ),
    );
  });
}
