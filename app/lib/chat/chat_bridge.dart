import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../appservice/protocol/fire_app_message.dart';
import '../link/device_link.dart';

/// 安卓应用作为客户端，连 FireAppService 写下的本机端口。桌面端没有这条通道。
class ChatBridge {
  static const _storage = MethodChannel('fireadb/storage');

  Socket? _socket;
  var _started = false;
  var _linked = false;
  String _selfId = '';
  void Function(Uint8List bytes)? _onBytes;
  void Function()? _onLinked;

  bool get available => Platform.isAndroid;

  void listen(
    void Function(Uint8List bytes) onBytes, {
    void Function()? onLinked,
  }) {
    _onBytes = onBytes;
    _onLinked = onLinked;
  }

  Future<void> start(String selfId) async {
    _selfId = selfId;
    if (!available || _started) return;
    _started = true;
    unawaited(_loop());
  }

  Future<bool> send(Uint8List bytes) async {
    final socket = _socket;
    if (!_linked || socket == null || bytes.isEmpty) return false;
    try {
      socket.add(bytes);
      await socket.flush();
      return true;
    } catch (_) {
      _linked = false;
      _socket = null;
      return false;
    }
  }

  Future<void> _loop() async {
    while (true) {
      try {
        final noted = await _note();
        if (noted == null) {
          await Future<void>.delayed(const Duration(seconds: 1));
          continue;
        }
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          noted.$1,
          timeout: const Duration(seconds: 3),
        );
        socket.setOption(SocketOption.tcpNoDelay, true);
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
        _socket = socket;
        _linked = true;
        _onLinked?.call();
        final done = Completer<void>();
        socket.listen(
          (chunk) {
            _onBytes?.call(Uint8List.fromList(chunk));
          },
          onError: (Object _) {
            if (!done.isCompleted) done.complete();
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
        );
        await done.future;
      } catch (_) {}
      _linked = false;
      final socket = _socket;
      _socket = null;
      try {
        await socket?.close();
      } catch (_) {}
      await Future<void>.delayed(const Duration(seconds: 1));
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
