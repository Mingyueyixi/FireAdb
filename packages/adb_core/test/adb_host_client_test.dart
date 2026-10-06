import 'dart:async';
import 'dart:convert';

import 'package:adb_core/adb_core.dart';
import 'package:test/test.dart';

import 'fake_adb_server.dart';

void main() {
  late FakeAdbServer server;
  late AdbHostClient client;

  setUp(() async {
    server = FakeAdbServer(
      devices: ['emulator-5554\tdevice', 'a1b2\tunauthorized'],
    );
    await server.start();
    client = AdbHostClient(host: '127.0.0.1', port: server.port!);
  });

  tearDown(() async {
    await server.close();
  });

  test('version 解析服务端版本', () async {
    final version = await client.version();
    expect(version.value, 0x39);
  });

  test('devices 解析 序列号+状态', () async {
    final devices = await client.devices();
    expect(devices, hasLength(2));
    expect(devices[0].serial, 'emulator-5554');
    expect(devices[0].state, 'device');
    expect(devices[0].isOnline, isTrue);
    expect(devices[1].serial, 'a1b2');
    expect(devices[1].state, 'unauthorized');
    expect(devices[1].isOnline, isFalse);
  });

  test('devices `-l` 真实 AOSP 长格式（%-22s 空格填充 + transport_id）', () async {
    server.devices.clear();
    // transport.cpp:append_transport：serial %-22s 左对齐，字段空格分隔。
    server.devices.add(
      'emulator-5556          device product:PD2309 model:V2366GA device:PD2309 transport_id:2',
    );
    server.devices.add(
      'emulator-0105     device /dev/bus/usb/001/002 product:crosshatch model:Pixel.2 device:walleye transport_id:3',
    );
    final devices = await client.devices(long: true);
    expect(devices, hasLength(2));
    expect(devices[0].serial, 'emulator-5556');
    expect(devices[0].state, 'device');
    expect(devices[0].product, 'PD2309');
    expect(devices[0].model, 'V2366GA');
    expect(devices[0].device, 'PD2309');
    expect(devices[0].transportId, '2');
    expect(devices[0].devPath, isNull);
    expect(devices[1].serial, 'emulator-0105');
    expect(devices[1].devPath, '/dev/bus/usb/001/002');
    expect(devices[1].state, 'device');
    expect(devices[1].product, 'crosshatch');
    expect(devices[1].model, 'Pixel.2');
    expect(devices[1].device, 'walleye');
    expect(devices[1].transportId, '3');
  });

  test('connect 返回服务端描述', () async {
    final result = await client.connectToDevice('192.168.1.5', 5555);
    expect(result, 'connected to 192.168.1.5:5555');
  });

  test('通过 host transport 打开设备 shell 服务', () async {
    final shell = await client.openShell('usb-device-1', 'getprop');
    expect(server.requests, contains('host:transport:usb-device-1'));
    expect(server.requests, contains('shell:getprop'));
    final output = await shell.readStream.transform(utf8.decoder).join();
    expect(output, 'fake shell output\n');
    await shell.close();
  });

  test('通过 host transport 打开设备 exec 服务', () async {
    final exec = await client.openDeviceService('usb-device-1', 'exec:screencap -p');
    expect(server.requests, contains('host:transport:usb-device-1'));
    expect(server.requests, contains('exec:screencap -p'));
    final output = await exec.readStream.transform(utf8.decoder).join();
    expect(output, 'fake exec output');
    await exec.close();
  });

  test('disconnect 全量断开', () async {
    final result = await client.disconnect();
    expect(result, contains('disconnected'));
  });

  test('killServer 关闭服务端', () async {
    await client.killServer();
    expect(server.requests, contains('host:kill'));
  });

  test('transport 绑定返回 id（tport:any）', () async {
    final id = await client.bindTransport();
    expect(id, 1);
  });

  test('transport 绑定按序列号（tport:serial）', () async {
    final id = await client.bindTransport(serial: 'emulator-5554');
    expect(id, 1);
    expect(server.requests, contains('host:tport:serial:emulator-5554'));
  });

  test('旧式 transport 绑定回退为 0', () async {
    final id = await client.bindTransportLegacy(serial: 'emulator-5554');
    expect(id, 0);
  });

  test('未知 host 服务抛 AdbHostError', () async {
    await expectLater(
      client.serialNo(serial: 'nope'),
      throwsA(isA<AdbHostError>()),
    );
  });

  test('host 前缀设备查询（get-serialno/get-state）', () async {
    expect(await client.serialNo(), 'fake12345');
    expect(await client.state(), 'device');
  });

  test('trackDevices 推送增量列表', () async {
    final events = <List<AdbDeviceInfo>>[];
    final sub = client.trackDevices().listen(events.add, onError: (e) {});
    // 等待首个事件（server 的初始列表）。
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(events, hasLength(1));
    expect(events[0], hasLength(2));

    server.trackUpdates.add('emulator-5554\tdevice\n');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(events, hasLength(2));
    expect(events[1], hasLength(1));

    await sub.cancel();
  });
}
