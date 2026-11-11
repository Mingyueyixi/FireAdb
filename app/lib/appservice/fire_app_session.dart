import 'dart:async';

import '../connection/model/connected_device.dart';
import '../log/app_log.dart';
import 'fire_app_launch.dart';
import 'protocol/fire_app_message.dart';

/// 请求号为 0、且不是 `session.ready` 的推送。剪贴板从这里认领自己的事件。
typedef FireAppPush = void Function(String serial, FireDataResponse response);

final _sessions = <String, FireAppSession>{};

FireAppSession fireAppSession(ConnectedDevice device) =>
    _sessions.putIfAbsent(device.serial, () => FireAppSession(device.serial));

/// 设备断开时由连接层调用：关掉长活 exec，避免下次同 serial 复用死流。
void releaseChatHold(String serial) {
  _sessions[serial]?.releaseChat();
}

Future<void> releaseFireAppService(String serial) async {
  final session = _sessions.remove(serial);
  if (session == null) return;
  await session.dispose();
}

/// 一台设备上的长寿进程。只负责把请求送出去、把响应收回来。
///
/// 应用目录和剪贴板各自组自己的 [FireDataRequest]，不共用一套命令实现。
class FireAppSession {
  FireAppSession(this.serial);

  final String serial;

  /// 主动推送。剪贴板占用 [onPush]，其他功能用 [addPush]，避免互相覆盖。
  static FireAppPush? onPush;
  static final List<FireAppPush> _pushes = <FireAppPush>[];

  static void addPush(FireAppPush push) {
    if (_pushes.contains(push)) return;
    _pushes.add(push);
  }

  Future<void> _chain = Future<void>.value();
  ConnectedShell? _shell;
  StreamSubscription<List<int>>? _subscription;
  FireDataResponseReader? _reader;
  final _responses = <FireDataResponse>[];
  Completer<void>? _wait;
  var _epoch = 0;
  var _generation = 0;
  var _listenEpoch = 0;
  var _nextRequestId = 1;
  Timer? _idle;

  /// 监听开启时进程常驻，空闲不退出。
  var watching = false;

  /// 聊天需要这条进程留着，好让成员来拉。和剪贴板监听互不影响。
  var chatHold = false;

  int get epoch => _epoch;

  int get pendingBytes => _reader?.pendingBytes ?? 0;

  /// 刷新列表时递增，让还在排队的单条查询失效。
  void advanceEpoch() => _epoch++;

  int nextId() => _nextRequestId++;

  Future<void> dispose() async {
    _epoch++;
    watching = false;
    chatHold = false;
    cancelIdle();
    await run(drop);
  }

  /// 同一台设备上的请求串行执行，避免两条响应缠在一起。
  Future<T> run<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _chain = _chain.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      }
    });
    return completer.future;
  }

  /// 取消空闲退出。必须在 [run] 入队之前调用，否则 20 秒退出可能插进复用的进程。
  void cancelIdle() {
    _generation++;
    _idle?.cancel();
    _idle = null;
  }

  void holdChat() {
    chatHold = true;
    cancelIdle();
  }

  void releaseChat() {
    chatHold = false;
    scheduleIdle();
  }

  void scheduleIdle() {
    _idle?.cancel();
    if (watching || chatHold) return;
    final generation = _generation;
    _idle = Timer(const Duration(seconds: 20), () {
      unawaited(
        run(() async {
          if (generation != _generation) return;
          await _quit();
        }),
      );
    });
  }

  Future<({int jarMs, int readyMs})> ensureReady(ConnectedDevice device) async {
    if (_shell != null) return (jarMs: 0, readyMs: 0);
    final clock = Stopwatch()..start();
    await ensureFireAppService(device);
    final jarMs = clock.elapsedMilliseconds;
    clock.reset();
    final shell = await device.openExec(
      fireAppServiceCommand(fireAppServiceRemotePath),
    );
    _shell = shell;
    _listen(shell);
    try {
      final ready = await next().timeout(const Duration(seconds: 30));
      if (ready.name == 'session.error') {
        throw StateError(ready.errorText('应用信息服务启动失败'));
      }
      if (ready.name != 'session.ready' || ready.text != '1') {
        throw StateError('应用信息服务没有就绪');
      }
      return (jarMs: jarMs, readyMs: clock.elapsedMilliseconds);
    } catch (error) {
      await drop();
      rethrow;
    }
  }

  Future<void> send(FireDataRequest request) {
    final shell = _shell;
    if (shell == null) throw StateError('应用信息服务没有就绪');
    return _write(shell, request);
  }

  Future<FireDataResponse> reply(int id, Duration timeout) async {
    final message = await next().timeout(timeout);
    if (message.name == 'session.error') {
      throw StateError(message.errorText('应用信息服务失败'));
    }
    if (message.id != id) throw StateError('应用信息服务响应无效');
    return message;
  }

  Future<FireDataResponse> next() async {
    while (_responses.isEmpty) {
      final pending = Completer<void>();
      _wait = pending;
      if (_responses.isNotEmpty && !pending.isCompleted) pending.complete();
      try {
        await pending.future;
      } finally {
        if (identical(_wait, pending)) _wait = null;
      }
    }
    return _responses.removeAt(0);
  }

  /// 丢掉当前进程。调用方可以接着再开一次。
  Future<void> drop() async {
    _listenEpoch++;
    final subscription = _subscription;
    final shell = _shell;
    _subscription = null;
    _shell = null;
    _reader = null;
    _responses.clear();
    final pending = _wait;
    _wait = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('应用信息服务已结束'));
    }
    await subscription?.cancel();
    if (shell == null) return;
    try {
      await _write(
        shell,
        FireDataRequest.none(name: 'session.quit', id: nextId()),
      ).timeout(const Duration(milliseconds: 300));
    } catch (_) {}
    try {
      await shell.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  Future<void> _quit() async {
    final shell = _shell;
    if (shell == null) return;
    try {
      await _write(
        shell,
        FireDataRequest.none(name: 'session.quit', id: nextId()),
      ).timeout(const Duration(seconds: 2));
    } catch (_) {}
    await drop();
  }

  Future<void> _write(ConnectedShell shell, FireDataRequest request) {
    log.info('请求 ${request.display}');
    return shell.write(request.bytes);
  }

  void _listen(ConnectedShell shell) {
    final epoch = ++_listenEpoch;
    _reader = FireDataResponseReader();
    _responses.clear();
    _subscription = shell.readStream.listen(
      (chunk) {
        if (epoch != _listenEpoch) return;
        final reader = _reader;
        if (reader == null) return;
        try {
          final parsed = reader.add(chunk);
          for (final message in parsed) {
            log.info('响应 ${message.display}');
            if (message.id == 0 &&
                message.name != 'session.ready' &&
                message.name != 'session.error') {
              onPush?.call(serial, message);
              for (final push in _pushes) {
                push(serial, message);
              }
              continue;
            }
            _responses.add(message);
          }
        } catch (error, stackTrace) {
          final pending = _wait;
          if (pending != null && !pending.isCompleted) {
            pending.completeError(error, stackTrace);
          }
          return;
        }
        final pending = _wait;
        if (pending != null && !pending.isCompleted) pending.complete();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (epoch != _listenEpoch) return;
        final pending = _wait;
        if (pending != null && !pending.isCompleted) {
          pending.completeError(error, stackTrace);
        }
      },
      onDone: () {
        if (epoch != _listenEpoch) return;
        final pending = _wait;
        if (pending != null && !pending.isCompleted) {
          pending.completeError(StateError('应用信息服务已结束'));
        }
      },
    );
  }
}
