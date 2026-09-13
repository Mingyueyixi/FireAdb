import 'package:fire_adb/main.dart';
import 'package:fire_adb/services/connection_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('连接中心首页正常渲染', (WidgetTester tester) async {
    await tester.pumpWidget(FireAdbApp(manager: ConnectionManager()));

    expect(find.text('FireAdb'), findsOneWidget);
    expect(find.text('手动连接'), findsOneWidget);
    expect(find.text('设备发现（mDNS）'), findsOneWidget);
    expect(find.text('已连接设备（0）'), findsOneWidget);
    expect(find.text('历史连接'), findsOneWidget);
  });
}