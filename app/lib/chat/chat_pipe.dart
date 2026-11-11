import 'dart:async';

import '../appservice/protocol/fire_app_message.dart';
import '../connection/model/connected_device.dart';
import '../log/app_log.dart';

/// 手机应用监听的本机端口。adb `tcp:` 能连上，抽象套接字会被 SELinux 拒绝。
const int chatDevicePort = 28165;

/// 桌面到一台手机聊天端口的直连。帧格式与应用信息服务相同。
class ChatPipe {
  ChatPipe(this.device, this.onFrame);

  final ConnectedDevice device;
  final void Function(FireDataResponse frame) onFrame;

  FireDataResponseReader _reader = FireDataResponseReader();
  final _pending = <int, Completer<FireDataResponse>>{};
  ConnectedShell? _shell;
  StreamSubscription<List<int>>? _subscription;
  Future<void> _writeChain = Future<void>.value();
  var _nextId = 1;
  var _started = false;
  var _closed = false;
  var _loggedFailure = false;

  void start() {
    if (_started) return;
    _started = true;
    unawaited(_loop());
  }

  Future<void> close() async {
    _closed = true;
    await _drop(StateError('聊天通道已断开'));
  }

  Future<FireDataResponse> exchange(
    FireDataRequest Function(int id) build,
  ) async {
    final shell = _shell;
    if (shell == null) throw StateError('聊天通道还没接上');
    final id = _nextId++;
    final waiter = Completer<FireDataResponse>();
    _pending[id] = waiter;
    try {
      await _write(shell, build(id).bytes);
      final reply = await waiter.future.timeout(const Duration(seconds: 20));
      if (reply.name == 'session.error') {
        throw StateError(reply.errorText('聊天没有送达'));
      }
      return reply;
    } catch (error) {
      final current = _pending[id];
      if (identical(current, waiter)) _pending.remove(id);
      if (error is TimeoutException) {
        throw StateError('聊天通道没有回应');
      }
      rethrow;
    }
  }

  Future<void> _loop() async {
    while (!_closed) {
      try {
        final shell = await device
            .openService('tcp:$chatDevicePort')
            .timeout(const Duration(seconds: 5));
        if (_closed) {
          await shell.close();
          return;
        }
        _shell = shell;
        _reader = FireDataResponseReader();
        _loggedFailure = false;
        log.info('已连上聊天端口 ${device.serial}');
        await _read(shell);
      } catch (error, stack) {
        if (!_loggedFailure) {
          _loggedFailure = true;
          log.warning('还没连上聊天端口 ${device.serial}', error, stack);
        }
      } finally {
        if (!_closed) await _drop(StateError('聊天通道断开'));
      }
      if (_closed) return;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  Future<void> _read(ConnectedShell shell) {
    final done = Completer<void>();
    _readDone = done;
    _subscription = shell.readStream.listen(
      (chunk) {
        final List<FireDataResponse> frames;
        try {
          frames = _reader.add(chunk);
        } catch (error, stack) {
          log.warning('聊天帧无效', error, stack);
          if (!done.isCompleted) done.complete();
          return;
        }
        for (final frame in frames) {
          if (frame.id != 0) {
            final waiter = _pending.remove(frame.id);
            if (waiter != null && !waiter.isCompleted) waiter.complete(frame);
            continue;
          }
          onFrame(frame);
        }
      },
      onError: (Object error, StackTrace stack) {
        log.warning('聊天端口断开 ${device.serial}', error, stack);
        if (!done.isCompleted) done.complete();
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    return done.future;
  }

  Future<void> _write(ConnectedShell shell, List<int> bytes) {
    final done = Completer<void>();
    _writeChain = _writeChain.catchError((Object _) {}).then((_) async {
      try {
        await shell.write(bytes);
        if (!done.isCompleted) done.complete();
      } catch (error, stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      }
    });
    return done.future;
  }

  Completer<void>? _readDone;

  Future<void> _drop(Object error) async {
    final done = _readDone;
    _readDone = null;
    final subscription = _subscription;
    final shell = _shell;
    _subscription = null;
    _shell = null;
    _reader = FireDataResponseReader();
    final waiting = _pending.values.toList();
    _pending.clear();
    for (final waiter in waiting) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
    if (done != null && !done.isCompleted) done.complete();
    await subscription?.cancel();
    if (shell == null) return;
    try {
      await shell.close();
    } catch (_) {}
  }
}
