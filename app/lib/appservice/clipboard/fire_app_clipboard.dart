import '../../connection/model/connected_device.dart';
import '../fire_app_session.dart';
import '../protocol/fire_app_message.dart';

/// 读取设备当前剪贴板文本。shell uid 在 ClipboardService
/// 里有测试豁免，走真实 ClipboardManager API。
Future<String> getFireAppClip(ConnectedDevice device) {
  return _exchange(device, (session, id) async {
    await session.send(FireDataRequest.none(name: 'clipboard.get', id: id));
    final message = await session.reply(id, const Duration(seconds: 10));
    if (message.name != 'clipboard.data') {
      throw StateError('剪贴板响应无效');
    }
    return '${message.json['text'] ?? ''}';
  });
}

/// 把文本写入设备剪贴板。
Future<void> setFireAppClip(ConnectedDevice device, String text) {
  return _exchange(device, (session, id) async {
    await session.send(
      FireDataRequest.json(
        name: 'clipboard.set',
        id: id,
        body: <String, String>{'text': text},
      ),
    );
    final message = await session.reply(id, const Duration(seconds: 10));
    if (message.name != 'clipboard.ok') {
      throw StateError('剪贴板写入响应无效');
    }
  });
}

/// 读取设备剪贴板历史，新的在前。
/// 设备侧随复制或写入累积并落盘，最多 20 条。
Future<List<String>> getFireAppClipHistory(ConnectedDevice device) {
  return _exchange(device, (session, id) async {
    await session.send(
      FireDataRequest.none(name: 'clipboard.history', id: id),
    );
    final message = await session.reply(id, const Duration(seconds: 10));
    if (message.name != 'clipboard.history') {
      throw StateError('设备剪贴板历史响应无效');
    }
    final items = message.json['items'];
    if (items is! List) return const <String>[];
    return <String>[for (final item in items) '$item'];
  });
}

/// 开关设备剪贴板变化监听。变化经
/// [setFireAppClipListener] 推送。开启后进程常驻，空闲时不退出。
Future<void> watchFireAppClip(ConnectedDevice device, bool on) {
  _bindPush();
  return _exchange(device, (session, id) async {
    await session.send(
      FireDataRequest.json(
        name: 'clipboard.watch',
        id: id,
        body: <String, bool>{'on': on},
      ),
    );
    final message = await session.reply(id, const Duration(seconds: 10));
    if (message.name != 'clipboard.ok') {
      throw StateError('剪贴板监听响应无效');
    }
    session.watching = on;
  });
}

/// WATCH 开启后，设备剪贴板变化从这里推送（serial, 文本）。
typedef FireAppClipListener = void Function(String serial, String text);

FireAppClipListener? _clipListener;

void setFireAppClipListener(FireAppClipListener? listener) {
  _clipListener = listener;
  _bindPush();
}

Future<T> _exchange<T>(
  ConnectedDevice device,
  Future<T> Function(FireAppSession session, int id) action,
) {
  final session = fireAppSession(device);
  session.cancelIdle();
  return session.run(() async {
    try {
      await session.ensureReady(device);
      return await action(session, session.nextId());
    } finally {
      session.scheduleIdle();
    }
  });
}

void _bindPush() {
  FireAppSession.onPush = (serial, response) {
    if (response.name != 'clipboard.event') return;
    final listener = _clipListener;
    if (listener == null) return;
    listener(serial, '${response.json['text'] ?? ''}');
  };
}
