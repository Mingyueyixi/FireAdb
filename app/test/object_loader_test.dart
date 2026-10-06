import 'dart:async';

import 'package:fire_adb/common/object_loader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('同一个 key 只加载一次，结果留在缓存里', () async {
    var calls = 0;
    final loader = ObjectLoader<String, int>(
      load: (key) async {
        calls++;
        return key.length;
      },
    );
    loader.ensure('ab');
    loader.ensure('ab');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, 1);
    expect(loader['ab'], 2);
    expect(loader.contains('ab'), isTrue);
    loader.dispose();
  });

  test('这一批对象都加载完后只通知一次', () async {
    final gates = <String, Completer<int>>{};
    var notifications = 0;
    final loader = ObjectLoader<String, int>(
      load: (key) {
        final gate = Completer<int>();
        gates[key] = gate;
        return gate.future;
      },
      onUpdated: () => notifications++,
    );
    loader.ensure('a');
    loader.ensure('b');
    await Future<void>.delayed(Duration.zero);
    gates['a']!.complete(1);
    await Future<void>.delayed(Duration.zero);
    expect(notifications, 0);
    expect(loader['a'], 1);
    gates['b']!.complete(2);
    await Future<void>.delayed(Duration.zero);
    expect(notifications, 1);
    expect(loader['a'], 1);
    expect(loader['b'], 2);
    loader.dispose();
  });

  test('清空后丢弃还在路上的结果', () async {
    final gate = Completer<int>();
    var notifications = 0;
    final loader = ObjectLoader<String, int>(
      load: (_) => gate.future,
      onUpdated: () => notifications++,
    );
    loader.ensure('a');
    await Future<void>.delayed(Duration.zero);
    loader.clear();
    gate.complete(1);
    await Future<void>.delayed(Duration.zero);
    expect(loader['a'], isNull);
    expect(notifications, 0);
    loader.dispose();
  });
}
