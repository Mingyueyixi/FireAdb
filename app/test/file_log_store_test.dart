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

  test('文件名带日期和进程号', () async {
    final directory = await Directory.systemTemp.createTemp('fire-adb-logs');
    final started = DateTime(2026, 10, 13, 12, 0, 5);
    final store = await FileLogStore.openSession(
      directory,
      started,
      processId: 100,
    );
    addTearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });

    store.write(LogRecord(Level.INFO, 'hello log', 'fire_adb'));
    await store.flush();

    expect(store.file.path, endsWith('fire_adb-2026-10-13_12-00-05.p100.log'));
    expect(store.continued, isFalse);
    expect(
      await store.file.readAsString(),
      matches(
        RegExp(
          r'^\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} INFO fire_adb hello log',
        ),
      ),
    );
  });

  test('同进程续写，不同进程新建', () async {
    final directory = await Directory.systemTemp.createTemp('fire-adb-reuse');
    addTearDown(() => directory.delete(recursive: true));
    final first = await FileLogStore.openSession(
      directory,
      DateTime(2026, 10, 13, 12),
      processId: 100,
    );
    first.writeLine('first');
    await first.flush();
    await first.close();

    final same = await FileLogStore.openSession(
      directory,
      DateTime(2026, 10, 13, 13),
      processId: 100,
    );
    expect(same.continued, isTrue);
    expect(same.file.path, first.file.path);
    same.writeLine('second');
    await same.flush();
    await same.close();

    final other = await FileLogStore.openSession(
      directory,
      DateTime(2026, 10, 13, 14),
      processId: 200,
    );
    expect(other.continued, isFalse);
    expect(other.file.path, isNot(first.file.path));
    await other.close();

    expect(await File(first.file.path).readAsString(), contains('first'));
    expect(await File(first.file.path).readAsString(), contains('second'));
  });

  test('同一轮日志只通知一次，并丢掉超出的旧行', () async {
    final buffer = SessionLogBuffer(maxCharacters: 10);
    var notices = 0;
    buffer.addListener(() => notices++);
    buffer.add('12345');
    buffer.add('67890');
    buffer.add('abcde');
    expect(notices, 0);

    await Future<void>.value();

    expect(notices, 1);
    expect(buffer.truncated, isTrue);
    expect(buffer.lines, <String>['67890', 'abcde']);
  });

  test('缩小缓冲区后立刻丢掉旧行', () async {
    final buffer = SessionLogBuffer(maxCharacters: 20);
    buffer.add('1234567890');
    buffer.add('abcdefghij');
    buffer.setMaxCharacters(10);
    await Future<void>.value();
    expect(buffer.truncated, isTrue);
    expect(buffer.lines, <String>['abcdefghij']);
  });

  test('按文件名判断日志时间和进程号', () async {
    expect(
      logFileStarted('fire_adb-2026-10-01_08-30-00.p100.log'),
      DateTime(2026, 10, 1, 8, 30),
    );
    expect(logFileProcessId('fire_adb-2026-10-01_08-30-00.p100.log'), 100);
    expect(
      logFileStarted('fire_adb-2026-10-01_08-30-00.log'),
      DateTime(2026, 10, 1, 8, 30),
    );
    expect(logFileStarted('fire_adb-2026-10-01.log'), DateTime(2026, 10, 1));
    expect(logFileStarted('fire_adb-2026-02-31.log'), isNull);
    expect(logFileStarted('notes.txt'), isNull);

    final directory = await Directory.systemTemp.createTemp('fire-adb-prune');
    addTearDown(() => directory.delete(recursive: true));
    final now = DateTime(2026, 10, 13, 12);
    await File('${directory.path}/fire_adb-2026-10-01_08-00-00.p1.log')
        .writeAsString('old');
    await File('${directory.path}/fire_adb-2026-10-12_08-00-00.p2.log')
        .writeAsString('recent');
    await File('${directory.path}/fire_adb-2026-09-01.log')
        .writeAsString('daily');
    await File('${directory.path}/other.txt').writeAsString('keep');
    const current = 'fire_adb-2026-10-01_09-00-00.p3.log';
    await File('${directory.path}/$current').writeAsString('open');

    final removed = await deleteExpiredLogFiles(
      directory,
      retentionDays: 7,
      now: now,
      keepName: current,
    );

    expect(removed, 2);
    expect(File('${directory.path}/$current').existsSync(), isTrue);
    expect(
      File('${directory.path}/fire_adb-2026-10-12_08-00-00.p2.log').existsSync(),
      isTrue,
    );
    expect(File('${directory.path}/other.txt').existsSync(), isTrue);
  });
}
