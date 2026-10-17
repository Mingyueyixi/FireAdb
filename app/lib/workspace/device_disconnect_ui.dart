import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../l10n/fire_adb_localizations_ext.dart';

/// 传输意外掉线时：若仍在工作区，弹窗提示并回首页。
Future<void> handleUnexpectedDeviceDisconnect(String serial) async {
  if (Get.currentRoute != '/workspace') return;

  final context = Get.overlayContext ?? Get.context;
  if (context == null || !context.mounted) {
    Get.offAllNamed<void>('/');
    return;
  }

  final l10n = context.l10n;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return AlertDialog(
        title: Text(l10n.workspaceDeviceDisconnectedTitle),
        content: Text(l10n.workspaceDeviceDisconnectedBody),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.workspaceBackToHome),
          ),
        ],
      );
    },
  );

  if (Get.currentRoute == '/workspace') {
    Get.offAllNamed<void>('/');
  }
}
