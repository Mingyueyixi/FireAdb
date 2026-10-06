import 'dart:convert';

import 'package:adb_core/adb_core.dart';
import 'package:fire_adb/connection/connection_manager.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
