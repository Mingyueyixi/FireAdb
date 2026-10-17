import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app_feedback.dart';
import '../connection/model/device_profile.dart';
import '../l10n/fire_adb_localizations_ext.dart';
import '../log/app_log.dart';
import 'workspace_controller.dart';
import 'workspace_reconnect.dart';

var _disconnectDialogOpen = false;
var _dismissRequested = false;

/// 自动重连成功等场景：若断线弹窗还开着（或即将打开），关掉它。
void dismissUnexpectedDisconnectDialog() {
  _dismissRequested = true;
  if (!_disconnectDialogOpen) return;
  final context = Get.overlayContext ?? Get.context;
  if (context == null) return;
  final navigator = Navigator.of(context, rootNavigator: true);
  if (navigator.canPop()) {
    navigator.pop();
  }
}

/// 传输意外掉线时：若仍在工作区，弹窗提示；由用户选择回首页、关闭或重连。
Future<void> handleUnexpectedDeviceDisconnect(
  String serial, {
  DeviceProfile? profile,
}) async {
  if (serial.isEmpty) return;
  if (Get.currentRoute != '/workspace') return;

  if (Get.isRegistered<WorkspaceController>()) {
    final workspace = Get.find<WorkspaceController>();
    // 每台掉线设备都留在侧栏并排队重连，不只当前正在看的那台。
    workspace.noteUnexpectedDisconnect(serial, profile: profile);
    if (workspace.selectedSerial.value != serial) return;
  }
  if (_disconnectDialogOpen) return;

  _dismissRequested = false;

  final context = Get.overlayContext ?? Get.context;
  if (context == null || !context.mounted) return;
  if (_dismissRequested) return;

  _disconnectDialogOpen = true;
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        if (_dismissRequested) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (dialogContext.mounted &&
                Navigator.of(dialogContext).canPop()) {
              Navigator.of(dialogContext).pop();
            }
          });
        }
        return _UnexpectedDisconnectDialog(serial: serial);
      },
    );
  } finally {
    _disconnectDialogOpen = false;
  }
}

class _UnexpectedDisconnectDialog extends StatefulWidget {
  const _UnexpectedDisconnectDialog({required this.serial});

  final String serial;

  @override
  State<_UnexpectedDisconnectDialog> createState() =>
      _UnexpectedDisconnectDialogState();
}

class _UnexpectedDisconnectDialogState
    extends State<_UnexpectedDisconnectDialog> {
  var _reconnecting = false;
  String? _error;

  void _close() {
    if (_reconnecting) return;
    Navigator.of(context).pop();
  }

  void _goHome() {
    if (_reconnecting) return;
    if (Get.isRegistered<WorkspaceController>()) {
      Get.find<WorkspaceController>().disarmAutoReconnect();
    }
    Navigator.of(context).pop();
    Get.offAllNamed<void>('/');
  }

  Future<void> _reconnect() async {
    if (_reconnecting) return;
    setState(() {
      _reconnecting = true;
      _error = null;
    });
    try {
      final workspace = Get.isRegistered<WorkspaceController>()
          ? Get.find<WorkspaceController>()
          : null;
      final connected = await reconnectWorkspaceDevice(
        widget.serial,
        host: workspace?.reconnectHostFor(widget.serial),
        port: workspace?.reconnectPortFor(widget.serial),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      workspace?.selectSerial(connected.serial);
    } catch (error, stackTrace) {
      log.severe('断线后重连失败：${widget.serial}', error, stackTrace);
      if (!mounted) return;
      setState(() {
        _reconnecting = false;
        _error = '$error';
      });
      showAppMessage(
        ScaffoldMessenger.of(context),
        Theme.of(context),
        title: context.l10n.homeConnectionFailed,
        message: '$error',
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Row(
        children: <Widget>[
          Expanded(child: Text(l10n.workspaceDeviceDisconnectedTitle)),
          IconButton(
            tooltip: l10n.commonClose,
            onPressed: _reconnecting ? null : _close,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(l10n.workspaceDeviceDisconnectedBody),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _reconnecting ? null : _goHome,
          child: Text(l10n.workspaceBackToHome),
        ),
        TextButton(
          onPressed: _reconnecting ? null : _close,
          child: Text(l10n.commonClose),
        ),
        FilledButton(
          onPressed: _reconnecting ? null : _reconnect,
          child: _reconnecting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.workspaceReconnect),
        ),
      ],
    );
  }
}
