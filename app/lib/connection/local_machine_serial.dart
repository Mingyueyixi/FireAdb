import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('fireadb/device');

const _storage = MethodChannel('fireadb/storage');

/// 把本机 FireAdb 的身份写到应用目录，adb shell 能读到才说明连的是这里。
Future<String> publishSelfMarker(String selfId) async {
  if (!Platform.isAndroid || selfId.isEmpty) return '';
  try {
    final directory = await _storage.invokeMethod<String>(
      'externalFilesDirectory',
    );
    if (directory == null || directory.isEmpty) return '';
    final file = File('$directory${Platform.pathSeparator}fireadb-self');
    await file.writeAsString(selfId);
    return file.path;
  } catch (_) {
    return '';
  }
}

/// 这部机器在 adbd 里报的序列号。桌面端没有，端口映射过来的设备对不上它。
Future<String> localMachineSerial() async {
  if (!Platform.isAndroid) return '';
  try {
    final value = await _channel.invokeMethod<String>('localSerial');
    final text = value?.trim() ?? '';
    if (text.isEmpty || text == 'unknown') return '';
    return text;
  } catch (_) {
    return '';
  }
}
