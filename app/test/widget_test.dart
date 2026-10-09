import 'dart:convert';

import 'package:fire_adb/app_feedback.dart';
import 'package:fire_adb/app_locale_controller.dart';
import 'package:fire_adb/connection/connection_manager.dart';
import 'package:fire_adb/home/home_controller.dart';
import 'package:fire_adb/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:libadb/libadb.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('连接中心首页正常渲染', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    Get.put<ConnectionManager>(ConnectionManager(), permanent: true);
    Get.put<AppLocaleController>(AppLocaleController(), permanent: true);
    final hostClient = _FakeAdbHostClient(const <AdbDeviceInfo>[
      AdbDeviceInfo(
        'R5CT123456A',
        'device',
        model: 'Pixel_8',
        devPath: '/dev/bus/usb/001/002',
      ),
      AdbDeviceInfo('127.0.0.1:5557', 'device', model: 'Network_Device'),
    ]);
    Get.put<HomeController>(
      HomeController(
        hostClient: hostClient,
        listUsbDevices: () async => const <UsbAdbDevice>[],
      ),
    );
    await tester.pumpWidget(const FireAdbApp());
    await tester.pump();

    expect(find.text('FireAdb'), findsOneWidget);
    expect(find.text('设备（2）'), findsOneWidget);
    expect(find.text('Pixel 8'), findsOneWidget);
    expect(
      find.text('R5CT123456A · /dev/bus/usb/001/002 · ADB 在线'),
      findsOneWidget,
    );
    expect(find.text('Network Device'), findsOneWidget);
    expect(find.text('USB 连接暂不可用'), findsNothing);
    expect(find.widgetWithText(TextButton, '连接'), findsNWidgets(2));
    expect(find.text('手动连接'), findsOneWidget);
    expect(find.text('设备发现（mDNS）'), findsOneWidget);
    expect(find.text('历史连接'), findsOneWidget);
    expect(hostClient.deviceListRequests, 1);

    final scaffoldContext = tester.element(find.byType(Scaffold).first);
    showAppMessage(
      ScaffoldMessenger.of(scaffoldContext),
      Theme.of(scaffoldContext),
      title: '连接失败',
      message: '测试错误',
      isError: true,
    );
    await tester.pump();
    expect(find.text('连接失败'), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
    final theme = Theme.of(tester.element(find.byType(Scaffold).first));
    final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snackBar.backgroundColor, theme.colorScheme.surfaceContainerHigh);
    Get.closeCurrentSnackbar();
    await tester.pump(const Duration(seconds: 1));

    final initialRequestCount = hostClient.deviceListRequests;
    await tester.pump(HomeController.adbDeviceRefreshInterval);
    await tester.pump();
    expect(hostClient.deviceListRequests, greaterThan(initialRequestCount));

    await tester.pumpWidget(const SizedBox());
    Get.delete<HomeController>(force: true);
    final requestsAfterControllerClose = hostClient.deviceListRequests;
    await tester.pump(HomeController.adbDeviceRefreshInterval * 2);
    expect(hostClient.deviceListRequests, requestsAfterControllerClose);
    Get.reset();
  });

  testWidgets('语言可以在中文和英文之间切换并保存', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    Get.put<ConnectionManager>(ConnectionManager(), permanent: true);
    final localeController = AppLocaleController();
    await localeController.load();
    expect(localeController.locale.value.languageCode, 'zh');
    Get.put<AppLocaleController>(localeController, permanent: true);
    final homeController = HomeController(
      hostClient: _FakeAdbHostClient(const <AdbDeviceInfo>[]),
      listUsbDevices: () async => const <UsbAdbDevice>[],
    );
    Get.put<HomeController>(homeController);
    try {
      await tester.pumpWidget(const FireAdbApp());
      await tester.pump();
      expect(find.text('手动连接'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('语言'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();
      expect(localeController.locale.value.languageCode, 'en');
      expect(find.text('Manual connection'), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getString('appLocale'),
        'en',
      );
      final restoredController = AppLocaleController();
      await restoredController.load();
      expect(restoredController.locale.value.languageCode, 'en');

      await tester.tap(find.text('Language'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('中文'));
      await tester.pumpAndSettle();
      expect(find.text('手动连接'), findsOneWidget);
    } finally {
      homeController.onClose();
      Get.reset();
    }
  });

  testWidgets('历史连接显示设备名和地址，手动连接地址会填回输入框', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'connection_history': <String>[
        jsonEncode(<String, Object?>{
          'serial': 'tcp-1',
          'host': '192.0.2.10',
          'port': 5555,
          'label': 'Pixel 8',
        }),
        jsonEncode(<String, Object?>{
          'serial': 'usb-2',
          'label': 'Pixel 8',
          'adbSerial': 'USB999',
        }),
      ],
      'manual_connection_host': '192.0.2.10',
      'manual_connection_port': 6666,
    });
    final manager = ConnectionManager();
    await manager.init();
    Get.put<ConnectionManager>(manager, permanent: true);
    Get.put<AppLocaleController>(AppLocaleController(), permanent: true);
    final homeController = HomeController(
      hostClient: _FakeAdbHostClient(const <AdbDeviceInfo>[]),
      listUsbDevices: () async => const <UsbAdbDevice>[],
    );
    Get.put<HomeController>(homeController);
    try {
      await tester.pumpWidget(const FireAdbApp());
      await tester.pump();

      expect(find.text('Pixel 8'), findsNWidgets(2));
      expect(find.text('192.0.2.10:5555'), findsOneWidget);
      expect(find.text('USB999'), findsOneWidget);
      expect(homeController.hostController.text, '192.0.2.10');
      expect(homeController.portController.text, '6666');
    } finally {
      homeController.onClose();
      Get.reset();
    }
  });
}

class _FakeAdbHostClient extends AdbHostClient {
  _FakeAdbHostClient(this._devices);

  final List<AdbDeviceInfo> _devices;
  int deviceListRequests = 0;

  @override
  Future<List<AdbDeviceInfo>> devices({bool long = false}) async {
    deviceListRequests++;
    return _devices;
  }
}
