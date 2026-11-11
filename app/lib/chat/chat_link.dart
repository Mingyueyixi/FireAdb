import 'dart:async';
import 'dart:typed_data';

import '../appservice/protocol/fire_app_message.dart';
import '../connection/model/connected_device.dart';
import '../log/app_log.dart';
import 'chat_codec.dart';
import 'chat_message.dart';

const String chatSocketService = 'localabstract:fireadb.chat';
const String _chatServiceComponent = 'com.fire.adb/.ChatSocketService';

typedef ChatIncoming = Future<void> Function(
  String serial,
  ChatMessage message,
  Uint8List? fileBytes,
);

/// 连到一台设备上 FireAdb 的聊天套接字。
/// 应用已在前台时直接连套接字；进程不在时用前台服务拉起。
/// 普通 startService 会被系统拒绝：app is in background uid null。
class ChatLink {
  ChatLink(this.device, this.onMessage);

  final ConnectedDevice device;
  final ChatIncoming onMessage;

  ConnectedShell? _shell;
  StreamSubscription<List<int>>? _subscription;
  final _reader = FireDataResponseReader();
  final _waiters = <int, Completer<void>>{};
  var _nextId = 1;
  var _writes = Future<void>.value();
  var _opening = Future<void>.value();
  ChatMessage? _pendingMeta;
  var _closed = false;

  Future<void> open() {
    if (_closed) return Future<void>.error(StateError('群聊连接已关闭'));
    if (_shell != null) return Future<void>.value();
    final done = Completer<void>();
    _opening = _opening.catchError((Object _) {}).then((_) async {
      if (_closed || _shell != null) {
        if (!done.isCompleted) done.complete();
        return;
      }
      try {
        var shell = await _tryConnect();
        if (shell == null && !_closed) {
          await _startService();
          shell = await _tryConnect(attempts: 10);
        }
        if (_closed || shell == null) {
          await shell?.close();
          if (!done.isCompleted) {
            if (shell == null && !_closed) {
              done.completeError(StateError('打不开设备上的聊天通道'));
            } else {
              done.complete();
            }
          }
          return;
        }
        _shell = shell;
        _subscription = shell.readStream.listen(
          _onBytes,
          onError: (Object error, StackTrace stack) {
            log.warning('群聊连接中断 ${device.serial}', error, stack);
            unawaited(close());
          },
          onDone: () {
            unawaited(close());
          },
        );
        if (!done.isCompleted) done.complete();
      } catch (error, stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      }
    });
    return done.future;
  }

  Future<void> send(ChatMessage message, Uint8List? fileBytes) async {
    await open();
    final id = _nextId++;
    final waiter = Completer<void>();
    _waiters[id] = waiter;
    final frames = encodeChatFrames(
      requestId: id,
      message: message,
      fileBytes: fileBytes,
    );
    try {
      await _write(frames);
      await waiter.future.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      _waiters.remove(id);
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closed && _shell == null) return;
    _closed = true;
    final shell = _shell;
    _shell = null;
    await _subscription?.cancel();
    _subscription = null;
    for (final waiter in _waiters.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(StateError('群聊连接已关闭'));
      }
    }
    _waiters.clear();
    if (shell != null) await shell.close();
  }

  Future<void> _startService() async {
    final foreground = await device.shell(
      'am start-foreground-service --user 0 -n $_chatServiceComponent',
    );
    if (!_serviceStartFailed(foreground)) return;
    final unknown =
        foreground.contains('unknown command') ||
        foreground.contains('Unknown command');
    if (!unknown) throw StateError(foreground.trim());
    final legacy = await device.shell(
      'am startservice --user 0 -n $_chatServiceComponent',
    );
    if (_serviceStartFailed(legacy)) throw StateError(legacy.trim());
  }

  bool _serviceStartFailed(String output) => output.contains('Error:');

  /// 套接字还没人听时返回 null。多次尝试仍失败则抛出。
  Future<ConnectedShell?> _tryConnect({int attempts = 1}) async {
    Object? last;
    for (var attempt = 0; attempt < attempts; attempt++) {
      if (_closed) return null;
      try {
        return await device.openService(chatSocketService);
      } catch (error) {
        last = error;
        if (attempt + 1 < attempts) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
    }
    if (attempts == 1) return null;
    throw StateError('打不开设备上的聊天通道: $last');
  }

  Future<void> _write(Uint8List bytes) {
    final shell = _shell;
    if (shell == null) return Future<void>.error(StateError('群聊连接已关闭'));
    final done = _writes.then((_) => shell.write(bytes));
    _writes = done.catchError((_) {});
    return done;
  }

  void _onBytes(List<int> chunk) {
    List<FireDataResponse> frames;
    try {
      frames = _reader.add(chunk);
    } catch (error, stack) {
      log.warning('群聊消息无法解析 ${device.serial}', error, stack);
      unawaited(close());
      return;
    }
    for (final frame in frames) {
      unawaited(_take(frame));
    }
  }

  Future<void> _take(FireDataResponse frame) async {
    if (frame.name == 'chat.ok') {
      final waiter = _waiters.remove(frame.id);
      if (waiter != null && !waiter.isCompleted) waiter.complete();
      return;
    }
    if (frame.name == 'chat.deliver') {
      try {
        _pendingMeta = ChatMessage.fromJson(frame.json);
      } catch (error, stack) {
        log.warning('群聊正文无效 ${device.serial}', error, stack);
        _pendingMeta = null;
        await _ack(frame.id);
        return;
      }
      final message = _pendingMeta!;
      if (message.isText || message.size <= 0) {
        _pendingMeta = null;
        await _ack(frame.id);
        await onMessage(device.serial, message, null);
      }
      return;
    }
    if (frame.name == 'chat.bytes') {
      final message = _pendingMeta;
      _pendingMeta = null;
      await _ack(frame.id);
      if (message != null) {
        await onMessage(device.serial, message, frame.body);
      }
    }
  }

  Future<void> _ack(int id) async {
    try {
      await _write(encodeChatOk(id));
    } catch (error, stack) {
      log.warning('群聊确认写失败 ${device.serial}', error, stack);
    }
  }
}
