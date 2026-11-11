import 'dart:io';

import 'package:flutter/services.dart';

/// 安卓应用侧的聊天端口。桌面经 adb 连 `tcp:28165`，不经过 shell。
class ChatBridge {
  static const _methods = MethodChannel('fireadb/chat');
  static const _events = EventChannel('fireadb/chat-events');

  bool get available => Platform.isAndroid;

  void listen(
    void Function(Uint8List bytes) onBytes, {
    void Function()? onLinked,
  }) {
    if (!available) return;
    _events.receiveBroadcastStream().listen((event) {
      if (event == 'linked') {
        onLinked?.call();
      } else if (event is Uint8List) {
        onBytes(event);
      } else if (event is List) {
        onBytes(Uint8List.fromList(event.cast<int>()));
      }
    });
  }

  Future<void> start() async {
    if (!available) return;
    await _methods.invokeMethod<void>('start');
  }

  Future<bool> send(Uint8List bytes) async {
    if (!available || bytes.isEmpty) return false;
    return await _methods.invokeMethod<bool>('send', bytes) ?? false;
  }
}
