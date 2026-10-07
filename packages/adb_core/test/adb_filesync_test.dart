import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:adb_core/adb_core.dart';
import 'package:test/test.dart';

import 'fake_adbd.dart';

void main() {
  late MemoryPair pair;
  late AdbRsaKeyPair key;
  late FakeAdbd device;
  late AdbConnection conn;
  late AdbSyncClient sync;

  Future<void> setup({Map<String, Uint8List>? syncFiles}) async {
    pair = MemoryPair.create();
    device = FakeAdbd(
      verifyKey: null,
      syncFiles:
          syncFiles ??
          {'/sdcard/hello.txt': Uint8List.fromList(utf8.encode('hello adb\n'))},
    );
    device.serve(pair.device);
    conn = AdbConnection(
      pair.host,
      signers: [key],
      authTimeout: const Duration(seconds: 5),
    );
    await conn.connect();
  }

  setUp(() {
    key = AdbRsaKeyPair.generate();
  });

  tearDown(() async {
    await sync.quit();
    await conn.close();
    await device.done;
  });

  test('stat 已有文件返回 mode/size', () async {
    await setup();
    final stream = await conn.open('sync:');
    sync = AdbSyncClient(stream);
    final st = await sync.stat('/sdcard/hello.txt');
    expect(st.isDirectory, isFalse);
    expect(st.size, 'hello adb\n'.length);
  });

  test('stat 缺失文件 mode=0', () async {
    await setup();
    final stream = await conn.open('sync:');
    sync = AdbSyncClient(stream);
    final st = await sync.stat('/sdcard/missing.bin');
    expect(st.mode, 0);
  });

  test('list 目录含文件与子目录', () async {
    await setup(
      syncFiles: {
        '/sdcard/a.txt': Uint8List.fromList([1, 2]),
        '/sdcard/b.log': Uint8List.fromList([3]),
        '/sdcard/sub/c.txt': Uint8List.fromList([4, 5, 6]),
      },
    );
    final stream = await conn.open('sync:');
    sync = AdbSyncClient(stream);
    final entries = await sync.list('/sdcard');
    expect(entries.map((e) => e.name), ['a.txt', 'b.log', 'sub']);
    final sub = entries.firstWhere((e) => e.name == 'sub');
    expect(sub.isDirectory, isTrue);
    expect(entries.firstWhere((e) => e.name == 'a.txt').size, 2);
  });

  test('list 根目录', () async {
    await setup(
      syncFiles: {
        '/sdcard/a.txt': Uint8List.fromList([1]),
      },
    );
    final stream = await conn.open('sync:');
    sync = AdbSyncClient(stream);
    final entries = await sync.list('/');
    expect(entries.map((e) => e.name), contains('sdcard'));
  });

  test('pullTo 按帧写入 sink', () async {
    await setup();
    final stream = await conn.open('sync:');
    sync = AdbSyncClient(stream);
    final sink = _ListSink();
    final size = await sync.pullTo('/sdcard/hello.txt', sink);
    expect(size, 'hello adb\n'.length);
    expect(utf8.decode(sink.bytes), 'hello adb\n');
  });

  test('pull 小文件内容一致', () async {
    await setup();
    final stream = await conn.open('sync:');
    sync = AdbSyncClient(stream);
    final data = await sync.pull('/sdcard/hello.txt');
    expect(utf8.decode(data), 'hello adb\n');
  });

  test('pull 大文件跨分片内容一致', () async {
    final big = Uint8List(200 * 1024);
    for (var i = 0; i < big.length; i++) {
      big[i] = (i * 31 + 7) & 0xff;
    }
    await setup(syncFiles: {'/sdcard/big.bin': big});
    final stream = await conn.open('sync:');
    sync = AdbSyncClient(stream);
    final data = await sync.pull('/sdcard/big.bin');
    expect(data, big);
  });

  test('pull 缺失文件抛 AdbSyncError', () async {
    await setup();
    final stream = await conn.open('sync:');
    sync = AdbSyncClient(stream);
    await expectLater(
      sync.pull('/sdcard/nope.txt'),
      throwsA(isA<AdbSyncError>()),
    );
  });

  test('pushFrom 按小块推送后内容一致', () async {
    await setup();
    final stream = await conn.open('sync:');
    sync = AdbSyncClient(stream);
    final content = Uint8List.fromList(utf8.encode('abcdef'));
    var offset = 0;
    await sync.pushFrom(
      () async {
        if (offset >= content.length) return null;
        final next = offset + 2 > content.length ? content.length : offset + 2;
        final chunk = Uint8List.sublistView(content, offset, next);
        offset = next;
        return chunk;
      },
      '/sdcard/chunked.bin',
      totalBytes: content.length,
    );
    final data = await sync.pull('/sdcard/chunked.bin');
    expect(data, content);
  });

  test('push 后 stat 与 pull 一致', () async {
    await setup();
    final stream = await conn.open('sync:');
    sync = AdbSyncClient(stream);
    final content = Uint8List.fromList(utf8.encode('pushed content'));
    await sync.push(content, '/sdcard/from-push.bin');
    final st = await sync.stat('/sdcard/from-push.bin');
    expect(st.size, content.length);
    final data = await sync.pull('/sdcard/from-push.bin');
    expect(data, content);
  });

  test('quit 正常关闭流', () async {
    await setup();
    final stream = await conn.open('sync:');
    sync = AdbSyncClient(stream);
    await sync.quit();
    expect(stream.isClosed, isTrue);
  });
}

class _ListSink implements StreamSink<List<int>> {
  final bytes = <int>[];

  @override
  void add(List<int> event) => bytes.addAll(event);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => close();
}
