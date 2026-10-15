import 'dart:convert';

import 'package:fire_adb/files/data/source/remote_file_commands.dart';
import 'package:fire_adb/files/local_file_picker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('路径拼接和上级目录', () {
    expect(normalizeRemotePath('sdcard'), '/sdcard');
    expect(normalizeRemotePath('/sdcard/'), '/sdcard');
    expect(parentRemotePath('/sdcard/Download'), '/sdcard');
    expect(parentRemotePath('/'), '/');
    expect(joinRemotePath('/sdcard', 'a.txt'), '/sdcard/a.txt');
    expect(joinRemotePath('/', 'sdcard'), '/sdcard');
    expect(isSafeRemoteName('..'), isFalse);
    expect(isSafeRemoteName('a/b'), isFalse);
  });

  test('权限和 chmod', () {
    expect(formatPermission(0x81a4), '644 rw-r--r--');
    expect(normalizeChmod('644'), '644');
    expect(normalizeChmod('0755'), '0755');
    expect(normalizeChmod('999'), isNull);
    expect(chmodCommand(<String>['/sdcard/a'], '644'), "chmod 644 '/sdcard/a'");
  });

  test('搜索命令转义和结果解析', () {
    final command = searchCommand('/sdcard', 'a*b');
    expect(command, contains(r'\*'));
    expect(command, contains('---FIRE-ADB---'));
    final parsed = parseSearchOutput('''
/sdcard/Docs
---FIRE-ADB---
Permission denied
/sdcard/a.txt
''');
    expect(parsed.map((file) => file.path), ['/sdcard/Docs', '/sdcard/a.txt']);
    expect(parsed.first.isDirectory, isTrue);
    expect(parsed.last.isDirectory, isFalse);
    final withLink = parseSearchOutput('''
/sdcard/Docs
---FIRE-ADB---
/sdcard/a.txt
---FIRE-ADB---
/sdcard
''');
    expect(withLink.last.isLink, isTrue);
    expect(withLink.last.canEnter, isFalse);
  });

  test('目录链接探测和本机路径解码', () {
    expect(
      directoryProbeCommand(<String>['/sdcard']),
      contains("[ -d '/sdcard' ]"),
    );
    expect(parseDirectoryProbe('/sdcard\nnoise\n/storage/emulated/0'), <String>{
      '/sdcard',
      '/storage/emulated/0',
    });
    final encoded = base64.encode(utf8.encode(r'C:\下载\a.txt'));
    expect(decodePickedPaths('$encoded\nnot-base64'), <String>[r'C:\下载\a.txt']);
    final utf16 = <int>[];
    for (final unit in encoded.codeUnits) {
      utf16.add(unit);
      utf16.add(0);
    }
    expect(decodeProcessText(utf16).trim(), encoded);
  });

  test('root 下列目录解析 toybox ls', () {
    final files = parseRootList('''
total 8
drwxr-xr-x 2 root root 4096 2026-10-14 11:20 data
-rw-r--r-- 1 root root 12 2026-10-14 11:20:03 note.txt
lrwxrwxrwx 1 root root 7 2026-10-14 11:20 link -> /system
../skip
''', '/data/data/com.example');
    expect(files.map((file) => file.name), ['data', 'note.txt', 'link']);
    expect(files[0].isDirectory, isTrue);
    expect(files[0].path, '/data/data/com.example/data');
    expect(files[1].size, 12);
    expect(files[1].isDirectory, isFalse);
    expect(files[2].isLink, isTrue);
    expect(files[1].mtime, isNot(0));
    expect(rootListFailure(''), isNull);
    expect(rootListFailure('total 0'), isNull);
    expect(rootListFailure('su: not found'), 'su: not found');
  });

  test('空文件和文本判断', () {
    expect(looksLikeBinary(<int>[0x68, 0x69]), isFalse);
    expect(looksLikeBinary(<int>[0x68, 0x00]), isTrue);
    expect(looksLikeBinary(<int>[0xff, 0xfe]), isTrue);
  });
}
