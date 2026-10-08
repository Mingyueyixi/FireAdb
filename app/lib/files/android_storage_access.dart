import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/fire_adb_localizations_ext.dart';

const MethodChannel _storageChannel = MethodChannel('fire_adb/storage');

/// 安卓 11 及以上看「所有文件访问权限」，更早的系统看存储读写权限。
/// 其他平台不需要这一步。
Future<bool> hasAllFilesAccess() async {
  if (!Platform.isAndroid) return true;
  final granted = await _storageChannel.invokeMethod<bool>('hasAllFilesAccess');
  return granted == true;
}

/// 还没有权限时先说明原因，再打开系统授权页。用户拒绝或返回后仍未授权时返回 false。
Future<bool> ensureAllFilesAccess(BuildContext context) async {
  if (!Platform.isAndroid) return true;
  if (await hasAllFilesAccess()) return true;
  if (!context.mounted) return false;
  final proceed = await showDialog<bool>(
    context: context,
    builder: (context) {
      final l10n = context.l10n;
      return AlertDialog(
        title: Text(l10n.storageAccessTitle),
        content: Text(l10n.storageAccessMessage),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.storageAccessGrant),
          ),
        ],
      );
    },
  );
  if (proceed != true) return false;
  final granted = await _storageChannel.invokeMethod<bool>(
    'requestAllFilesAccess',
  );
  return granted == true;
}
