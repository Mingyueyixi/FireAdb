import 'package:fire_adb/apps/data/source/run_as_files.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('run-as 列出 debug 应用目录', () {
    expect(
      runAsListCommand('com.example.app', '/data/data/com.example.app'),
      "run-as 'com.example.app' ls -la '/data/data/com.example.app'",
    );
    final entries = parseRunAsList('''
total 16
drwx------ 4 u0_a1 u0_a1 4096 2024-05-01 10:11 .
drwxrwx--x 9 system system 4096 2024-05-01 10:11 ..
drwx------ 2 u0_a1 u0_a1 4096 2024-05-01 10:11 cache
-rw------- 1 u0_a1 u0_a1 18 2024-05-01 10:12 note.txt
lrwxrwxrwx 1 u0_a1 u0_a1 10 2024-05-01 10:12 link -> /tmp
''', '/data/data/com.example.app');
    expect(entries.map((entry) => entry.name), <String>[
      'cache',
      'link',
      'note.txt',
    ]);
    expect(entries.first.directory, isTrue);
    expect(entries[1].link, isTrue);
    expect(entries[1].path, '/data/data/com.example.app/link');
    expect(entries.last.size, 18);
  });

  test('不能越过应用目录，包名不合法时拒绝', () {
    expect(
      isWithinAppRoot(
        '/data/data/com.example.app',
        '/data/data/com.example.app/cache',
      ),
      isTrue,
    );
    expect(
      isWithinAppRoot('/data/data/com.example.app', '/data/data/com.other'),
      isFalse,
    );
    expect(
      isWithinAppRoot(
        '/data/data/com.example.app',
        '/data/data/com.example.app/../com.other',
      ),
      isFalse,
    );
    expect(
      () => runAsCatCommand('not a package', '/data/data/x'),
      throwsArgumentError,
    );
  });

  test('SD 卡目录用 shell 读取，并准备备用路径', () {
    expect(isPrivateAppDataPath('/data/user/0/com.example.app'), isTrue);
    expect(
      isPrivateAppDataPath('/sdcard/Android/data/com.example.app'),
      isFalse,
    );
    expect(
      shellListCommand('/sdcard/Android/data/com.example.app'),
      "ls -la '/sdcard/Android/data/com.example.app'",
    );
    expect(
      externalDirectoryCandidates(
        '/storage/emulated/0/Android/data/com.example.app',
      ),
      contains('/data/media/0/Android/data/com.example.app'),
    );
    expect(
      isRemotePermissionDenied(
        StateError(
          'ls: /sdcard/Android/data/com.example.app: Permission denied',
        ),
      ),
      isTrue,
    );
    expect(localEntryName('a:b'), 'a_b');
  });

  test('run-as 失败时把错误抛出来', () {
    expect(
      () => parseRunAsList(
        'run-as: package not debuggable: com.example.app',
        '/data/data/com.example.app',
      ),
      throwsStateError,
    );
  });
}
