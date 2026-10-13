import 'dart:async';
import 'dart:io';

import 'package:fire_adb/connection/connection_manager.dart';
import 'package:fire_adb/home/device_scanner.dart';
import 'package:fire_adb/home/home_controller.dart';
import 'package:fire_adb/settings/app_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:libadb/libadb.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('mDNS 结果先回调，普通列表也不等采集窗口', () async {
    final order = <String>[];
    final gate = Completer<void>();
    final scanner = DeviceScanner(
      queryAdb: (publish) async {
        publish(
          ListedDeviceScan(
            adbDevices: const <AdbDeviceInfo>[
              AdbDeviceInfo('emulator-5554', 'device'),
            ],
          ),
        );
        order.add('adb');
      },
      queryUsb: (publish) async {
        publish(const ListedDeviceScan(usbDevices: <UsbAdbDevice>[]));
      },
      discoverMdns: (onUpdate, {isCancelled}) async {
        onUpdate(<MdnsService>[_service]);
        order.add('mdns-returned');
        await gate.future;
        return MdnsDiscoverResult(services: <MdnsService>[_service]);
      },
    );

    DeviceScanRound? round;
    final done = scanner.run(
      includeMdns: true,
      onListed: (scan) {
        if (scan.adbDevices != null) order.add('listed');
      },
      onMdns: (services) {
        order.add('mdns:${services.single.port}');
      },
      onRoundComplete: (value) {
        round = value;
        order.add('round');
      },
    );
    await Future<void>.delayed(Duration.zero);

    expect(order, <String>['listed', 'adb', 'mdns:6666', 'mdns-returned']);
    expect(round, isNull);

    gate.complete();
    await done;
    expect(order.last, 'round');
    expect(round!.includedMdns, isTrue);
    expect(round!.timedOut, isFalse);
    expect(round!.services.single.port, 6666);
  });

  test('采集时间到不算扫描结果，进行中的 mDNS 不会再开一轮', () async {
    final gate = Completer<void>();
    var mdnsStarts = 0;
    final scanner = DeviceScanner(
      queryAdb: (publish) async {},
      queryUsb: (publish) async {},
      discoverMdns: (onUpdate, {isCancelled}) async {
        mdnsStarts++;
        await gate.future;
        return const MdnsDiscoverResult(timedOut: true);
      },
    );

    var mdnsUpdates = 0;
    final first = scanner.run(
      includeMdns: true,
      includeUsb: false,
      onMdns: (_) => mdnsUpdates++,
      onRoundComplete: (round) {
        expect(round.timedOut, isTrue);
        expect(round.services, isEmpty);
      },
    );
    final second = scanner.run(
      includeMdns: true,
      includeAdb: false,
      includeUsb: false,
      onRoundComplete: (round) => expect(round.includedMdns, isFalse),
    );
    await second;
    expect(mdnsStarts, 1);
    expect(mdnsUpdates, 0);

    gate.complete();
    await first;
  });

  testWidgets('设备列表在 mDNS 窗口结束前就收到结果', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = AppSettingsStore();
    await settings.load();
    await settings.setAutoRefreshDevices(false);
    Get.put<ConnectionManager>(ConnectionManager(), permanent: true);
    Get.put<AppSettingsStore>(settings, permanent: true);
    final gate = Completer<List<MdnsService>>();
    var holdDiscovery = false;
    final home = HomeController(
      hostClient: _FakeAdbHostClient(const <AdbDeviceInfo>[
        AdbDeviceInfo('emulator-5554', 'device'),
      ]),
      listUsbDevices: () async => const <UsbAdbDevice>[],
      usbSupported: false,
      discoverServices: (onUpdate) {
        if (!holdDiscovery) return Future.value(const <MdnsService>[]);
        onUpdate?.call(<MdnsService>[_service]);
        return gate.future;
      },
    );
    Get.put<HomeController>(home);
    try {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump();
      expect(home.scanning.value, isFalse);

      holdDiscovery = true;
      final done = home.refreshDeviceList();
      await tester.pump();

      expect(home.adbDevices.single.serial, 'emulator-5554');
      expect(home.discovered.single.port, 6666);
      expect(home.scanning.value, isTrue);
      expect(home.loadingAdbDevices.value, isTrue);

      gate.complete(<MdnsService>[_service]);
      await tester.pump(const Duration(milliseconds: 900));
      await done;

      expect(home.scanning.value, isFalse);
      expect(home.loadingAdbDevices.value, isFalse);
      expect(home.discovered.single.port, 6666);
      expect(home.adbDevices.single.serial, 'emulator-5554');
    } finally {
      if (!gate.isCompleted) gate.complete(<MdnsService>[_service]);
      await Get.delete<HomeController>(force: true);
      await tester.pump(const Duration(seconds: 1));
      Get.reset();
    }
  });
}

final MdnsService _service = MdnsService(
  instanceName: 'adb-phone',
  serviceType: adbServiceTypeTransport,
  port: 6666,
  address: InternetAddress('192.0.2.45'),
);

class _FakeAdbHostClient extends AdbHostClient {
  _FakeAdbHostClient(this._devices);

  final List<AdbDeviceInfo> _devices;

  @override
  Future<List<AdbDeviceInfo>> devices({bool long = false}) async => _devices;
}
