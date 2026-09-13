import 'dart:io';
import 'dart:typed_data';

import 'package:adb_core/adb_core.dart';

String _home() {
  final env = Platform.environment;
  if (Platform.isWindows && env['USERPROFILE'] != null) {
    return env['USERPROFILE']!;
  }
  return env['HOME'] ?? '.';
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Future<void> main(List<String> args) async {
  print('=== 1/5 连接本机 adb server (127.0.0.1:5037) ===');
  final host = AdbHostClient();
  try {
    final v = await host.version();
    print('adb server 版本: ${v.value}');
  } on SocketException catch (e) {
    print('无法连接 adb server：$e');
    print('请先运行 `adb start-server`（或打开模拟器，它会自动拉起服务端）。');
    return;
  }

  final devices = await host.devices(long: true);
  print('发现的设备:');
  for (final d in devices) {
    print('  ${d.serial}\t${d.state}${d.devPath == null ? '' : '\t${d.devPath}'}');
  }

  final emus = devices.where((d) => d.serial.startsWith('emulator-')).toList();
  if (emus.isEmpty) {
    print('没有发现模拟器（emulator-*）。请确认模拟器已启动并完成启动动画。');
    return;
  }
  final target = emus.firstWhere((d) => d.isOnline, orElse: () => emus.first);
  print('目标: ${target.serial} (${target.state})');

  print('--- 通过 server 查询设备元信息 ---');
  print('serialNo:   ${await host.serialNo(serial: target.serial)}');
  print('state:      ${await host.state(serial: target.serial)}');

  if (!target.isOnline) {
    print('设备未在线（offline/unauthorized），等待后重试...');
  }

  print('');
  print('=== 2/5 计算模拟器 adb 端口 + 加载/生成密钥 ===');
  final digits = target.serial.replaceAll('emulator-', '');
  final adbPort = int.parse(digits) + 1; // emulator-5554 → 5555
  final keyPath =
      '${_home()}${Platform.pathSeparator}.config${Platform.pathSeparator}'
      'fire_adb${Platform.pathSeparator}adbkey.pem';
  final key = loadOrCreateAdbKey(keyPath);
  print('adb 端口: $adbPort, 密钥: $keyPath');

  print('');
  print('=== 3/5 直连 $adbPort（跳过 5037 服务端） ===');
  AdbDevice? dev;
  for (var i = 0; i < 20; i++) {
    try {
      dev = await adbConnectTcp('127.0.0.1',
          port: adbPort,
          signers: [key],
          authTimeout: const Duration(seconds: 6),
          connectTimeout: const Duration(seconds: 5));
      print('连接成功（第 ${i + 1} 次尝试）');
      break;
    } on AdbDeviceAuthError {
      if (i == 0 || i == 6) {
        print('尚未授权：请在模拟器屏幕上点击“允许 USB 调试”（Always allow）...');
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    } catch (e) {
      print('尝试 ${i + 1} 失败: $e');
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }
  if (dev == null) {
    print('! 直连失败。请检查 5555 端口未被占用、模拟器已完全启动。');
    return;
  }

  print('');
  print('=== 4/5 设备信息与基础命令 ===');
  final d = dev;
  print('banner : ${d.banner}');
  print('serial : ${d.serial}');
  print('model  : ${(await d.shell('getprop ro.product.model')).trim()}');
  print('android: ${(await d.shell('getprop ro.build.version.release')).trim()}');
  print('abiver : ${(await d.shell('getprop ro.product.cpu.abi')).trim()}');
  print('echo   : ${(await d.shell('echo hello-from-dart-adb')).trim()}');

  print('');
  print('=== 5/5 截图 + sync 传输 + track-devices ===');
  final png = await d.screencapPng();
  final shot = File('emulator-screen.png');
  await shot.writeAsBytes(png);
  print('截图已保存: ${shot.path} (${png.length} 字节)');

  final payload = Uint8List.fromList(
      List<int>.generate(150000, (i) => (i * 7 + 13) & 0xff));
  await d.pushBytes(payload, '/data/local/tmp/toolbox-test.bin');
  final back = await d.pull('/data/local/tmp/toolbox-test.bin');
  print('push→pull 往返: ${payload.length} 字节, 一致=${_sameBytes(payload, back)}');
  final st = await d.stat('/data/local/tmp/toolbox-test.bin');
  print('stat size: ${st.size}');

  final listing = await host.trackDevices().first.timeout(const Duration(seconds: 5));
  print('track-devices 首事件: $listing');

  await dev.close();
  print('');
  print('完成 ✓');
}