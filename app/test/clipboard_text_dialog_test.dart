import 'package:fireadb/clipboard/ui/clipboard_text_dialog.dart';
import 'package:fireadb/l10n/generated/fireadb_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('发送文本后关闭动画不再使用已销毁的输入控制器', (tester) async {
    String? result = 'unset';
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: FireAdbLocalizations.localizationsDelegates,
        supportedLocales: FireAdbLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await promptClipboardText(
                    context,
                    title: '发送文本到设备',
                    preset: 'hello',
                  );
                },
                child: const Text('打开'),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsOneWidget);

    await tester.tap(find.text('发送'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(result, 'hello');
    expect(find.byType(TextFormField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('内容为空时不关闭对话框', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: FireAdbLocalizations.localizationsDelegates,
        supportedLocales: FireAdbLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () => promptClipboardText(context, title: '发送文本'),
                child: const Text('打开'),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '发送'));
    await tester.pump();

    expect(find.text('内容为空'), findsOneWidget);
    expect(find.byType(TextFormField), findsOneWidget);
  });
}
