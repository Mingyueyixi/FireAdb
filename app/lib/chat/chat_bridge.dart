import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../appservice/protocol/fire_app_message.dart';
import '../link/device_link.dart';
import '../log/app_log.dart';

/// 安卓应用作为客户端，连 FireAppService 写下的本机端口。桌面端没有这条通道。
class ChatBridge {
  static const _storage = MethodChannel('fireadb/storage');

  static const _minGap = Duration(seconds: 3);
  static const _maxGap = Duration(seconds: 30);

  Socket? _socket;
  var _started = false;
  var _linked = false;
  Duration _gap = _minGap;
  final Map<int, Completer<FireDataResponse>> _pending =
      <int, Completer<FireDataResponse>>{};
  var _nextId = 1;
  String _selfId = '';
  void Function(Uint8List bytes)? _onBytes;
  void Function(bool linked)? _onLink;

  bool get available => Platform.isAndroid;

  bool get linked => _linked;

  void listen(
    void Function(Uint8List bytes) onBytes, {
    void Function(bool linked)? onLink,
  }) {
    _onBytes = onBytes;
    _onLink = onLink;
  }

  void _setLinked(bool value) {
    if (_linked == value) return;
    _linked = value;
    _onLink?.call(value);
  }

  Future<void> start(String selfId) async {
    _selfId = selfId;
    if (!available || _started) return;
    _started = true;
    unawaited(_loop());
  }

  /// 等对端用同一个序号回一帧。序号撞上本机正在等的请求时，由调用方先收走。
  bool take(FireDataResponse frame) {
    if (frame.id == 0) return false;
    final waiter = _pending.remove(frame.id);
    if (waiter == null || waiter.isCompleted) return false;
    waiter.complete(frame);
    return true;
  }

  Future<FireDataResponse> exchange(String name, Map<String, Object?> body) async {
    final socket = _socket;
    if (!_linked || socket == null) throw StateError('聊天通道还没接上');
    final id = _nextId++;
    final waiter = Completer<FireDataResponse>();
    _pending[id] = waiter;
    try {
      socket.add(FireDataRequest.json(name: name, id: id, body: body).bytes);
      await socket.flush();
      final reply = await waiter.future.timeout(const Duration(seconds: 8));
      if (reply.name == 'session.error') {
        throw StateError(reply.errorText('聊天没有送达'));
      }
      return reply;
    } catch (error) {
      final current = _pending[id];
      if (identical(current, waiter)) _pending.remove(id);
      rethrow;
    }
  }

  void _failPending() {
    final waiting = _pending.values.toList();
    _pending.clear();
    for (final waiter in waiting) {
      if (!waiter.isCompleted) {
        waiter.completeError(StateError('聊天通道已断开'));
      }
    }
  }

  Future<bool> send(Uint8List bytes) async {
    final socket = _socket;
    if (!_linked || socket == null || bytes.isEmpty) {
      log.info('聊天帧未发出：通道未连接 ${bytes.length} 字节');
      return false;
    }
    try {
      socket.add(bytes);
      await socket.flush();
      return true;
    } catch (error) {
      log.warning('聊天帧写出失败', error);
      _setLinked(false);
      _socket = null;
      return false;
    }
  }

  Future<void> _pause() async {
    final gap = _gap;
    final next = gap.inSeconds * 2;
    _gap = Duration(seconds: next > _maxGap.inSeconds ? _maxGap.inSeconds : next);
    await Future<void>.delayed(gap);
  }

  Future<void> _loop() async {
    while (true) {
      var opened = DateTime.now();
      var connected = false;
      try {
        final noted = await _note();
        if (noted == null) {
          await _pause();
          continue;
        }
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          noted.$1,
          timeout: const Duration(seconds: 3),
        );
        socket.setOption(SocketOption.tcpNoDelay, true);
        _socket = socket;
        final done = Completer<void>();
        socket.listen(
          (chunk) {
            try {
              _onBytes?.call(Uint8List.fromList(chunk));
            } catch (error, stack) {
              log.warning('聊天通道读帧失败', error, stack);
            }
          },
          onError: (Object error) {
            log.warning('聊天通道出错', error);
            if (!done.isCompleted) done.complete();
          },
          onDone: () {
            log.info('聊天通道已断开');
            if (!done.isCompleted) done.complete();
          },
        );
        final hello = FireDataRequest.json(
          name: linkHelloName,
          id: 0,
          body: <String, String>{
            'role': 'app',
            'token': noted.$2,
            'selfId': _selfId,
          },
        );
        socket.add(hello.bytes);
        await socket.flush();
        opened = DateTime.now();
        connected = true;
        _setLinked(true);
        await done.future;
      } catch (_) {}
      _setLinked(false);
      _failPending();
      final socket = _socket;
      _socket = null;
      try {
        await socket?.close();
      } catch (_) {}
      if (connected &&
          DateTime.now().difference(opened) >= const Duration(seconds: 15)) {
        _gap = _minGap;
      }
      await _pause();
    }
  }

  Future<(int, String)?> _note() async {
    final directory = await _storage.invokeMethod<String>(
      'externalFilesDirectory',
    );
    if (directory == null || directory.isEmpty) return null;
    final file = File('$directory${Platform.pathSeparator}fireadb-link');
    if (!await file.exists()) return null;
    final parts = (await file.readAsString()).trim().split(RegExp(r'\s+'));
    if (parts.length < 2) return null;
    final port = int.tryParse(parts[0]);
    if (port == null || port <= 0 || parts[1].isEmpty) return null;
    return (port, parts[1]);
  }
}
