import 'dart:convert';
import 'dart:typed_data';

import 'package:adb_core/adb_core.dart';
import 'package:test/test.dart';

import 'fake_adbd.dart';

void main() {
  test('shell:xxx 返回一次性输出', () async {
    final pair = MemoryPair.create();
    final key = AdbRsaKeyPair.generate();
    final device = FakeAdbd(verifyKey: key)
      ..serviceHandler = (dest) async => dest == 'shell:id'
          ? 'uid=2000(shell) gid=2000(shell)\n'
          : null;
    device.serve(pair.device);

    final conn = AdbConnection(pair.host, signers: [key],
        authTimeout: const Duration(seconds: 5));
    await conn.connect();
    final d = AdbDevice(conn);

    expect(await d.shell('id'), contains('uid=2000'));
    expect(d.serial, 'fake12345');
    await conn.close();
    await device.done;
  });

  test('getProperties 解析 getprop 输出', () async {
    final pair = MemoryPair.create();
    final key = AdbRsaKeyPair.generate();
    final device = FakeAdbd(verifyKey: key)
      ..serviceHandler = (dest) async => dest == 'shell:getprop'
          ? '[ro.product.model]: [Pixel 7]\n[ro.build.version.release]: [13]\n'
          : null;
    device.serve(pair.device);

    final conn = AdbConnection(pair.host, signers: [key],
        authTimeout: const Duration(seconds: 5));
    await conn.connect();
    final d = AdbDevice(conn);

    final props = await d.getProperties();
    expect(props['ro.product.model'], 'Pixel 7');
    expect(props['ro.build.version.release'], '13');
    await conn.close();
    await device.done;
  });

  test('execOut 返回精确字节（screencap）', () async {
    final png = Uint8List.fromList(
        [0x89, 0x50, 0x4E, 0x47, ...utf8.encode(' fake-image-bytes')]);
    final pair = MemoryPair.create();
    final key = AdbRsaKeyPair.generate();
    final device = FakeAdbd(verifyKey: key)
      ..serviceHandler = (dest) async => dest == 'exec:screencap -p'
          ? String.fromCharCodes(png)
          : null;
    device.serve(pair.device);

    final conn = AdbConnection(pair.host, signers: [key],
        authTimeout: const Duration(seconds: 5));
    await conn.connect();
    final d = AdbDevice(conn);

    expect(await d.screencapPng(), png);
    await conn.close();
    await device.done;
  });

  test('pushBytes→pull 往返与 stat', () async {
    final pair = MemoryPair.create();
    final key = AdbRsaKeyPair.generate();
    final device = FakeAdbd(verifyKey: key);
    device.serve(pair.device);

    final conn = AdbConnection(pair.host, signers: [key],
        authTimeout: const Duration(seconds: 5));
    await conn.connect();
    final d = AdbDevice(conn);

    final content = Uint8List.fromList(utf8.encode('device payload'));
    await d.pushBytes(content, '/sdcard/x.bin');
    expect((await d.stat('/sdcard/x.bin')).size, content.length);
    expect(await d.pull('/sdcard/x.bin'), content);

    // 隐式目录可列。
    final entries = await d.list('/sdcard');
    expect(entries.map((e) => e.name), contains('x.bin'));

    await conn.close();
    await device.done;
  });

  test('install 推送+pm install+清理', () async {
    final pair = MemoryPair.create();
    final key = AdbRsaKeyPair.generate();
    final device = FakeAdbd(verifyKey: key);
    device.serve(pair.device);

    final conn = AdbConnection(pair.host, signers: [key],
        authTimeout: const Duration(seconds: 5));
    await conn.connect();
    final d = AdbDevice(conn);

    final apk = Uint8List.fromList(utf8.encode('fake-apk'));
    // shell（pm install / rm）单次服务返回空即可；push 走 sync 内存盘。
    device.serviceHandler = (dest) async =>
        dest.startsWith('shell:pm install') ? 'Success\n' : '';
    final result = await d.install(apk, fileName: 'my.apk');
    expect(result, contains('Success'));
    // 设备 sync 盘子上仍能看到安装包（进程尚未清盘）。
    expect(device.syncContent('/data/local/tmp/my.apk'), apk);
    await conn.close();
    await device.done;
  });

  test('uninstall 与 reboot 命令构造', () async {
    final pair = MemoryPair.create();
    final key = AdbRsaKeyPair.generate();
    final calls = <String>[];
    final device = FakeAdbd(verifyKey: key);
    device.serviceHandler = (dest) async {
      calls.add(dest);
      return '';
    };
    device.serve(pair.device);

    final conn = AdbConnection(pair.host, signers: [key],
        authTimeout: const Duration(seconds: 5));
    await conn.connect();
    final d = AdbDevice(conn);

    await d.uninstall('com.example.app');
    await d.uninstall('com.example.app', keepData: true);
    await d.reboot();
    await d.reboot(destination: 'bootloader');
    expect(calls, contains('shell:pm uninstall "com.example.app"'));
    expect(calls, contains('shell:pm uninstall -k "com.example.app"'));
    expect(calls, contains('reboot'));
    expect(calls, contains('reboot:bootloader'));
    await conn.close();
    await device.done;
  });
}