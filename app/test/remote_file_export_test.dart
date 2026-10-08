import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fire_adb/files/remote_file_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('本机复制不经过 ADB，并按字节回报进度', () async {
    final dir = await Directory.systemTemp.createTemp('local-copy');
    addTearDown(() => dir.delete(recursive: true));
    final source = File('${dir.path}${Platform.pathSeparator}source.bin');
    final destination = File('${dir.path}${Platform.pathSeparator}dest.bin');
    final bytes = List<int>.generate(1000, (index) => index % 256);
    await source.writeAsBytes(bytes);
    final progress = <int>[];

    final copied = await copyLocalFile(
      source: source,
      destination: destination,
      onProgress: (done, total) => progress.add(done),
    );

    expect(copied.bytes, bytes.length);
    expect(await destination.readAsBytes(), bytes);
    expect(progress, isNotEmpty);
    expect(progress.last, bytes.length);
  });

  test('复制过程中取消会停掉并删除目标文件', () async {
    final dir = await Directory.systemTemp.createTemp('local-copy-cancel');
    addTearDown(() => dir.delete(recursive: true));
    final source = File('${dir.path}${Platform.pathSeparator}source.bin');
    final destination = File('${dir.path}${Platform.pathSeparator}dest.bin');
    await source.writeAsBytes(List<int>.filled(kFileIoBufferSize * 3, 7));
    var cancel = false;
    final handle = LocalCopyHandle();

    await expectLater(
      copyLocalFile(
        source: source,
        destination: destination,
        copyHandle: handle,
        onProgress: (done, total) {
          cancel = true;
          unawaited(handle.close());
        },
        isCancelled: () => cancel,
        cancelledException: () => const RemoteFileExportCancelled(),
      ),
      throwsA(isA<RemoteFileExportCancelled>()),
    );
    expect(await destination.exists(), isFalse);
  });

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

  test('同名文件按 Windows 方式改名，目录只改第一段', () async {
    final dir = await Directory.systemTemp.createTemp('export-names');
    addTearDown(() => dir.delete(recursive: true));
    final sep = Platform.pathSeparator;
    await File('${dir.path}${sep}app.apk').writeAsBytes(const [1]);
    await File('${dir.path}${sep}app (2).apk').writeAsBytes(const [2]);
    await Directory('${dir.path}${sep}Photos').create();
    final names = ExportDestination(dir.path);

    expect(
      await names.pathFor('app.apk'),
      '${dir.path}${sep}app (3).apk',
    );
    expect(await names.pathFor('Photos'), '${dir.path}${sep}Photos (2)');
    expect(
      await names.pathFor('Photos/a.jpg'),
      '${dir.path}${sep}Photos (2)${sep}a.jpg',
    );
    expect(await names.pathFor('readme'), '${dir.path}${sep}readme');
    expect(await names.pathFor('readme'), '${dir.path}${sep}readme (2)');
  });

  test('取消只删除新文件，原来的同名文件还在', () async {
    final dir = await Directory.systemTemp.createTemp('export-keep');
    addTearDown(() => dir.delete(recursive: true));
    final sep = Platform.pathSeparator;
    final source = File('${dir.path}${sep}source.bin');
    final original = File('${dir.path}${sep}app.apk');
    await source.writeAsBytes(List<int>.filled(kFileIoBufferSize * 3, 7));
    await original.writeAsBytes(const [1, 2, 3, 4]);
    final destination = File(
      await ExportDestination(dir.path).pathFor('app.apk'),
    );

    var cancel = false;
    final handle = LocalCopyHandle();
    await expectLater(
      copyLocalFile(
        source: source,
        destination: destination,
        copyHandle: handle,
        onProgress: (done, total) {
          cancel = true;
          unawaited(handle.close());
        },
        isCancelled: () => cancel,
        cancelledException: () => const RemoteFileExportCancelled(),
      ),
      throwsA(isA<RemoteFileExportCancelled>()),
    );
    expect(await original.readAsBytes(), const [1, 2, 3, 4]);
    expect(await destination.exists(), isFalse);
  });
}
