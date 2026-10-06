import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fire_adb/files/remote_file_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parseMd5Sum 接受文本模式和二进制模式', () {
    const digest = 'd41d8cd98f00b204e9800998ecf8427e';
    expect(parseMd5Sum('$digest  /sdcard/a.apk\n'), digest);
    expect(parseMd5Sum('${digest.toUpperCase()} */sdcard/a.apk'), digest);
    expect(parseMd5Sum('md5sum: not found'), isNull);
  });

  test('校验一致时保留文件', () async {
    final dir = await Directory.systemTemp.createTemp('remote-export');
    final local = File('${dir.path}${Platform.pathSeparator}a.bin');
    final bytes = <int>[1, 2, 3, 4];
    final digest = md5.convert(bytes).toString();
    addTearDown(() => dir.delete(recursive: true));

    final exported = await exportRemoteFile(
      remotePath: '/sdcard/my app.bin',
      localFile: local,
      shell: (command) async {
        expect(command, "md5sum '/sdcard/my app.bin'");
        return '$digest  /sdcard/my app.bin\n';
      },
      pullTo: (remote, sink, onProgress) async {
        expect(remote, '/sdcard/my app.bin');
        sink.add(bytes);
        onProgress?.call(bytes.length, bytes.length);
        return bytes.length;
      },
    );

    expect(exported.md5, digest);
    expect(exported.bytes, bytes.length);
    expect(await local.readAsBytes(), bytes);
  });

  test('校验不一致时删除本地文件', () async {
    final dir = await Directory.systemTemp.createTemp('remote-export');
    final local = File('${dir.path}${Platform.pathSeparator}a.bin');
    addTearDown(() => dir.delete(recursive: true));

    await expectLater(
      exportRemoteFile(
        remotePath: '/sdcard/a.bin',
        localFile: local,
        shell: (_) async => 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  /sdcard/a.bin\n',
        pullTo: (remote, sink, onProgress) async {
          sink.add(const <int>[9]);
          return 1;
        },
      ),
      throwsA(isA<RemoteFileChecksumException>()),
    );
    expect(await local.exists(), isFalse);
  });

  test('md5sum 没有摘要时删除本地文件', () async {
    final dir = await Directory.systemTemp.createTemp('remote-export');
    final local = File('${dir.path}${Platform.pathSeparator}a.bin');
    addTearDown(() => dir.delete(recursive: true));

    await expectLater(
      exportRemoteFile(
        remotePath: '/sdcard/a.bin',
        localFile: local,
        shell: (_) async => 'md5sum: not found\n',
        pullTo: (remote, sink, onProgress) async {
          sink.add(const <int>[9]);
          return 1;
        },
      ),
      throwsA(
        isA<RemoteFileChecksumException>().having(
          (error) => error.toString(),
          'message',
          contains('not found'),
        ),
      ),
    );
    expect(await local.exists(), isFalse);
  });

  test('取消时删除未校验完的文件', () async {
    final dir = await Directory.systemTemp.createTemp('remote-export');
    final local = File('${dir.path}${Platform.pathSeparator}a.bin');
    var cancelled = false;
    addTearDown(() => dir.delete(recursive: true));

    await expectLater(
      exportRemoteFile(
        remotePath: '/sdcard/a.bin',
        localFile: local,
        shell: (_) async => 'unused',
        pullTo: (remote, sink, onProgress) async {
          sink.add(const <int>[1, 2]);
          cancelled = true;
          return 2;
        },
        isCancelled: () => cancelled,
        cancelledException: () => const RemoteFileExportCancelled(),
      ),
      throwsA(isA<RemoteFileExportCancelled>()),
    );
    expect(await local.exists(), isFalse);
  });
}
