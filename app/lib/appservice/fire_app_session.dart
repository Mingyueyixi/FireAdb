import 'dart:async';

import '../connection/model/connected_device.dart';
import '../link/device_link.dart';
import 'protocol/fire_app_message.dart';

/// 请求号为 0、且不是 `session.ready` 的推送。剪贴板从这里认领自己的事件。
typedef FireAppPush = void Function(String serial, FireDataResponse response);

final _sessions = <String, FireAppSession>{};

FireAppSession fireAppSession(ConnectedDevice device) =>
    _sessions.putIfAbsent(device.serial, () => FireAppSession(device.serial));

Future<void> releaseFireAppService(String serial) async {
  final session = _sessions.remove(serial);
  if (session == null) return;
  await session.dispose();
}

/// 一台设备上的反向连接。只负责把请求送出去、把响应和推送收回来。
///
/// 服务进程停在反向端口上，连接一直留着。设备断开时才关掉电脑这边的门口。
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
  final _responses = <FireDataResponse>[];
  Completer<void>? _wait;
  var _epoch = 0;
  var _waitGen = 0;
  var _nextRequestId = 1;
  var _linkReady = false;

  int get epoch => _epoch;

  int get pendingBytes => 0;

  /// 刷新列表时递增，让还在排队的单条查询失效。
  void advanceEpoch() => _epoch++;

  int nextId() => _nextRequestId++;

  Future<void> dispose() async {
    _epoch++;
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

  /// 服务那条连接断了。下一次就绪要重新等 `session.ready`。
  void markLinkDown() {
    _linkReady = false;
    _responses.clear();
    _cancelWait(StateError('应用信息服务已断开'));
  }

  /// 反向连接上的一帧。hello 已由 [DeviceLink] 核对过。
  void ingest(FireDataResponse message) {
    if (message.name == 'session.ready') {
      if (_linkReady) return;
    } else if (message.id == 0 && message.name != 'session.error') {
      onPush?.call(serial, message);
      for (final push in _pushes) {
        push(serial, message);
      }
      return;
    }
    _responses.add(message);
    final pending = _wait;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  Future<({int jarMs, int readyMs})> ensureReady(ConnectedDevice device) async {
    if (_linkReady && DeviceLink.serviceReady(device.serial)) {
      return (jarMs: 0, readyMs: 0);
    }
    final clock = Stopwatch()..start();
    await DeviceLink.open(device);
    final jarMs = clock.elapsedMilliseconds;
    if (_linkReady && DeviceLink.serviceReady(device.serial)) {
      return (jarMs: jarMs, readyMs: 0);
    }
    clock.reset();
    try {
      final ready = await nextWithin(const Duration(seconds: 30));
      if (ready.name == 'session.error') {
        throw StateError(ready.errorText('应用信息服务启动失败'));
      }
      if (ready.name != 'session.ready' || ready.text != '1') {
        throw StateError('应用信息服务没有就绪');
      }
      _linkReady = true;
      return (jarMs: jarMs, readyMs: clock.elapsedMilliseconds);
    } catch (error) {
      _linkReady = false;
      rethrow;
    }
  }

  Future<void> send(FireDataRequest request) {
    return DeviceLink.writeService(serial, request.bytes);
  }

  Future<FireDataResponse> reply(int id, Duration timeout) async {
    final message = await nextWithin(timeout);
    if (message.name == 'session.error') {
      throw StateError(message.errorText('应用信息服务失败'));
    }
    if (message.id != id) throw StateError('应用信息服务响应无效');
    return message;
  }

  /// 等到下一帧。超时只取消这次等待，帧还留在队列里，不会被丢掉。
  Future<FireDataResponse> nextWithin(Duration limit) {
    final ticket = _waitGen;
    final timer = Timer(limit, () {
      if (ticket != _waitGen) return;
      _cancelWait(TimeoutException('应用信息服务超时', limit));
    });
    return next(ticket).whenComplete(timer.cancel);
  }

  Future<FireDataResponse> next([int? ticket]) async {
    final generation = ticket ?? _waitGen;
    while (_responses.isEmpty) {
      final pending = Completer<void>();
      _wait = pending;
      if (_responses.isNotEmpty && !pending.isCompleted) pending.complete();
      try {
        await pending.future;
      } finally {
        if (identical(_wait, pending)) _wait = null;
      }
      if (generation != _waitGen) {
        throw TimeoutException('应用信息服务超时');
      }
    }
    if (generation != _waitGen) {
      throw TimeoutException('应用信息服务超时');
    }
    return _responses.removeAt(0);
  }

  void _cancelWait(Object error) {
    _waitGen++;
    final pending = _wait;
    _wait = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(error);
    }
  }

  /// 设备断开时关掉电脑这边的门口。不向反向端口发退出。
  Future<void> drop() async {
    _linkReady = false;
    _responses.clear();
    _cancelWait(StateError('应用信息服务已结束'));
    await DeviceLink.close(serial);
  }
}
