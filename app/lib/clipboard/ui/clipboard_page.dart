import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../appservice/fire_app_service.dart';
import '../../connection/connection_manager.dart';
import '../../l10n/fireadb_localizations_ext.dart';
import '../../log/app_log.dart';
import '../clipboard_sync_controller.dart';
import 'clipboard_text_dialog.dart';

/// 设备剪贴板功能页：同步开关 + 文本转发 + 设备剪贴板历史。
///
/// 推送确认横幅在首页设备列表；这里管单台设备的开关和显式收发。
class ClipboardPage extends StatefulWidget {
  const ClipboardPage({super.key, required this.serial});

  final String serial;

  @override
  State<ClipboardPage> createState() => _ClipboardPageState();
}

class _ClipboardPageState extends State<ClipboardPage> {
  final ClipboardSyncController controller = Get.find<ClipboardSyncController>();
  var _busy = false;

  ConnectionManager get _manager => Get.find<ConnectionManager>();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Obx(
      () => ListView(
        padding: const EdgeInsets.all(12),
        children: <Widget>[
          SwitchListTile(
            value: controller.watchEnabled(widget.serial),
            onChanged: _busy ? null : _toggleWatch,
            title: Text(l10n.clipboardWatchTitle),
            subtitle: Text(
              l10n.clipboardWatchSubtitle,
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const Divider(),
          ListTile(
            enabled: !_busy,
            leading: const Icon(Icons.text_snippet_outlined),
            title: Text(l10n.clipboardSendToDevice),
            onTap: () => unawaited(_send()),
          ),
          ListTile(
            enabled: !_busy,
            leading: const Icon(Icons.history),
            title: Text(l10n.clipboardReadFromDevice),
            onTap: () => unawaited(_viewHistory()),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleWatch(bool value) async {
    setState(() => _busy = true);
    try {
      await controller.setWatch(widget.serial, value);
    } catch (error) {
      if (mounted) _showFailed(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 输入任意文本转发到设备剪贴板，预填本机剪贴板内容。
  Future<void> _send() async {
    final device = _manager.deviceOf(widget.serial);
    if (!mounted) return;
    if (device == null) {
      _showInfo(context.l10n.clipboardDeviceDisconnected);
      return;
    }
    final l10n = context.l10n;
    final preset = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    if (!mounted) return;
    final text = await promptClipboardText(
      context,
      title: l10n.clipboardSendTextTitle,
      preset: preset,
    );
    if (text == null || text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      await controller.sendTo(widget.serial, text);
      if (mounted) _showInfo(context.l10n.clipboardSendDone);
    } catch (error) {
      if (mounted) _showFailed(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 查看设备剪贴板历史（新的在前）。每条可以复制到本机，也可以从设备删掉。
  Future<void> _viewHistory() async {
    final device = _manager.deviceOf(widget.serial);
    if (!mounted) return;
    if (device == null) {
      _showInfo(context.l10n.clipboardDeviceDisconnected);
      return;
    }
    setState(() => _busy = true);
    try {
      final texts = await getFireAppClipHistory(device);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => _ClipboardHistoryDialog(
          serial: widget.serial,
          texts: texts,
        ),
      );
    } catch (error, stackTrace) {
      log.warning('读取设备剪贴板历史失败 ${widget.serial}', error, stackTrace);
      if (mounted) _showFailed(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showInfo(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _showFailed(Object error) {
    _showInfo(context.l10n.clipboardOperationFailed('$error'));
  }
}

class _ClipboardHistoryDialog extends StatefulWidget {
  const _ClipboardHistoryDialog({required this.serial, required this.texts});

  final String serial;
  final List<String> texts;

  @override
  State<_ClipboardHistoryDialog> createState() => _ClipboardHistoryDialogState();
}

class _ClipboardHistoryDialogState extends State<_ClipboardHistoryDialog> {
  late final List<String> _texts = List<String>.of(widget.texts);
  var _busy = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.clipboardHistoryTitle),
      content: SizedBox(
        width: 440,
        child: _texts.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(l10n.clipboardReadEmpty, textAlign: TextAlign.center),
              )
            : ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _texts.length,
                  separatorBuilder: (context, index) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final text = _texts[index];
                    return ListTile(
                      dense: true,
                      title: Text(
                        text.replaceAll('\n', ' ').trim(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          IconButton(
                            tooltip: l10n.clipboardOfferCopy,
                            icon: const Icon(Icons.copy, size: 20),
                            onPressed: _busy ? null : () => unawaited(_copy(text)),
                          ),
                          IconButton(
                            tooltip: l10n.clipboardDelete,
                            icon: const Icon(Icons.delete_outline, size: 20),
                            onPressed: _busy ? null : () => unawaited(_delete(text)),
                          ),
                        ],
                      ),
                      onTap: _busy ? null : () => unawaited(_showDetail(text)),
                    );
                  },
                ),
              ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).closeButtonTooltip),
        ),
      ],
    );
  }

  Future<void> _copy(String text) async {
    final messenger = ScaffoldMessenger.of(context);
    final message = context.l10n.clipboardReadDone;
    await Clipboard.setData(ClipboardData(text: text));
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _delete(String text) async {
    if (_busy) return false;
    final device = Get.find<ConnectionManager>().deviceOf(widget.serial);
    if (!mounted) return false;
    if (device == null) {
      _snack(context.l10n.clipboardDeviceDisconnected);
      return false;
    }
    setState(() => _busy = true);
    try {
      await removeFireAppClip(device, text);
      if (!mounted) return false;
      setState(() => _texts.remove(text));
      _snack(context.l10n.clipboardDeleted);
      return true;
    } catch (error, stackTrace) {
      log.warning('删除设备剪贴板失败 ${widget.serial}', error, stackTrace);
      if (mounted) _snack(context.l10n.clipboardOperationFailed('$error'));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showDetail(String text) async {
    final removed = await showDialog<bool>(
      context: context,
      builder: (detailContext) => AlertDialog(
        title: Text(context.l10n.clipboardHistoryTitle),
        content: SingleChildScrollView(child: SelectableText(text)),
        actions: <Widget>[
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(detailContext).pop(false),
            child: Text(MaterialLocalizations.of(detailContext).closeButtonTooltip),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () async {
                    final ok = await _delete(text);
                    if (ok && detailContext.mounted) {
                      Navigator.of(detailContext).pop(true);
                    }
                  },
            child: Text(context.l10n.clipboardDelete),
          ),
          FilledButton(
            onPressed: _busy
                ? null
                : () {
                    unawaited(_copy(text));
                    Navigator.of(detailContext).pop(false);
                  },
            child: Text(context.l10n.clipboardOfferCopy),
          ),
        ],
      ),
    );
    if (removed == true && mounted) setState(() {});
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
