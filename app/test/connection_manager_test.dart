import 'dart:convert';

import 'package:fire_adb/connection/connection_manager.dart';
import 'package:fire_adb/connection/model/device_profile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libadb/libadb.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('设备列表连接使用统一入口写入并恢复连接历史', () async {
    final manager = ConnectionManager();
    final hostClient = AdbHostClient();
    const info = AdbDeviceInfo('USB123456', 'device', model: 'Pixel_8');

    final connected = await manager.connectAdbDevice(
      info,
      hostClient: hostClient,
    );

    expect(manager.deviceOf(info.serial), same(connected));
    expect(manager.history, hasLength(1));
    expect(manager.history.single.adbSerial, info.serial);
    expect(manager.history.single.displayName, 'Pixel 8');

    final preferences = await SharedPreferences.getInstance();
    final stored = preferences.getStringList('connection_history')!;
    final decoded = jsonDecode(stored.single) as Map<String, dynamic>;
    expect(decoded['adbSerial'], info.serial);

    final restored = ConnectionManager();
    await restored.init();
    expect(restored.history, hasLength(1));
    expect(restored.history.single.adbSerial, info.serial);
    expect(restored.history.single.label, 'Pixel 8');
  });

  test('连接历史兼容旧版 host:port 存储格式', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'connection_history': <String>['192.0.2.10:5555', '[2001:db8::1]:5556'],
    });
    final manager = ConnectionManager();

    await manager.init();

    expect(manager.history, hasLength(2));
    expect(manager.history[0].host, '192.0.2.10');
    expect(manager.history[0].port, 5555);
    expect(manager.history[1].host, '2001:db8::1');
    expect(manager.history[1].port, 5556);
  });

  test('手动连接地址会保存并在下次读回', () async {
    final manager = ConnectionManager();
    await manager.rememberManualEndpoint('192.0.2.8', 6666);

    final restored = ConnectionManager();
    await restored.init();

    expect(restored.manualEndpoint(), ('192.0.2.8', 6666));
  });

  test('历史项同时带有设备名和连接地址', () {
    const network = DeviceProfile(
      serial: 'tcp-1',
      host: '192.0.2.10',
      port: 5555,
      label: 'Pixel 8',
    );
    const sameName = DeviceProfile(
      serial: 'usb-2',
      label: 'Pixel 8',
      adbSerial: 'USB999',
    );
    const ipv6 = DeviceProfile(
      serial: 'tcp-3',
      host: '2001:db8::1',
      port: 5556,
      label: 'Pixel 8',
    );

    expect(network.displayName, 'Pixel 8');
    expect(network.connectionAddress, '192.0.2.10:5555');
    expect(sameName.displayName, 'Pixel 8');
    expect(sameName.connectionAddress, 'USB999');
    expect(ipv6.connectionAddress, '[2001:db8::1]:5556');
  });

  test('序列号为空的手动连接仍会进入历史', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'connection_history': <String>[
        jsonEncode(<String, Object?>{
          'serial': '',
          'host': '192.0.2.10',
          'port': 5555,
          'label': 'Pixel 8',
        }),
      ],
    });
    final manager = ConnectionManager();

    await manager.init();

    expect(manager.history, hasLength(1));
    expect(manager.history.single.displayName, 'Pixel 8');
    expect(manager.history.single.connectionAddress, '192.0.2.10:5555');
    expect(manager.history.single.serial, '192.0.2.10:5555');
  });
}
