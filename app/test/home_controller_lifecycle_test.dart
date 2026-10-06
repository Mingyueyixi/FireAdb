import 'package:adb_core/adb_core.dart';
import 'package:fire_adb/app_locale_controller.dart';
import 'package:fire_adb/connection/connection_manager.dart';
import 'package:fire_adb/home/home_controller.dart';
import 'package:fire_adb/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('主页输入控制器在路由切换和窗口缩放后仍有效', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    Get.put<ConnectionManager>(ConnectionManager(), permanent: true);
    Get.put<AppLocaleController>(AppLocaleController(), permanent: true);
    final controller = HomeController(hostClient: _FakeAdbHostClient());
    Get.put<HomeController>(controller, permanent: true);
    try {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 800);
      await tester.pumpWidget(const FireAdbApp());
      await tester.pump();

      Get.toNamed<void>('/workspace', arguments: 'test-device');
      await tester.pumpAndSettle();
      Get.back<void>();
      await tester.pumpAndSettle();

      tester.view.physicalSize = const Size(900, 800);
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(1000, 800);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '192.0.2.1');
      expect(controller.hostController.text, '192.0.2.1');
      expect(tester.takeException(), isNull);
    } finally {
      controller.onClose();
      await tester.pumpWidget(const SizedBox.shrink());
      Get.reset();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });
}

class _FakeAdbHostClient extends AdbHostClient {
  @override
  Future<List<AdbDeviceInfo>> devices({bool long = false}) async =>
      const <AdbDeviceInfo>[];
}
