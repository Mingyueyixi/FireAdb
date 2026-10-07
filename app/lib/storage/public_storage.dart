import 'dart:io';

import 'package:flutter/services.dart';

const MethodChannel _storageChannel = MethodChannel('fire_adb/storage');

/// Android 写入公共下载目录需要所有文件访问权限。未授权时打开系统设置。
Future<void> ensurePublicSaveAccess() async {
  if (!Platform.isAndroid) return;
  try {
    await _storageChannel.invokeMethod<bool>('ensurePublicStorage');
  } on MissingPluginException {
    // 桌面测试或尚未接上通道时，仍按目标目录尝试写入。
  }
}
