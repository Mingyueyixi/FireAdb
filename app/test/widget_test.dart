import 'package:fire_adb/connection/connection_manager.dart';
import 'package:fire_adb/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

void main() {
  testWidgets('连接中心首页正常渲染', (WidgetTester tester) async {
    Get.put<ConnectionManager>(ConnectionManager(), permanent: true);
    await tester.pumpWidget(const FireAdbApp());
    await tester.pumpAndSettle();

    expect(find.text('FireAdb'), findsOneWidget);
    expect(find.text('手动连接'), findsOneWidget);
    expect(find.text('设备发现（mDNS）'), findsOneWidget);
    expect(find.text('已连接设备（0）'), findsOneWidget);
    expect(find.text('历史连接'), findsOneWidget);

    Get.reset();
  });
}
