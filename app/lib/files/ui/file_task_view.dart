import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../l10n/fire_adb_localizations_ext.dart';
import '../data/source/remote_file_commands.dart';
import '../files_controller.dart';

class FileTaskBar extends StatelessWidget {
  const FileTaskBar({super.key, required this.task, required this.onCancel});

  final FileTask task;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final name = task.currentName.isEmpty ? '…' : task.currentName;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                LinearProgressIndicator(
                  value: task.total <= 0 ? null : task.completed / task.total,
                  minHeight: 4,
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.appsTaskProgress(
                    task.label,
                    name,
                    task.completed,
                    task.total,
                    task.countPercent,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: task.completed >= task.total ? null : onCancel,
            child: Text(l10n.appsCancelTask),
          ),
        ],
      ),
    );
  }
}

class FileTransferDialog extends StatefulWidget {
  const FileTransferDialog({super.key, required this.controller});

  final FilesController controller;

  @override
  State<FileTransferDialog> createState() => _FileTransferDialogState();
}

class _FileTransferDialogState extends State<FileTransferDialog> {
  var _popped = false;

  void _popIfDone(FileTask? task) {
    if (_popped || task != null || !mounted) return;
    _popped = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Obx(() {
      final task = widget.controller.task.value;
      widget.controller.taskTick.value;
      if (task == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _popIfDone(task));
        return const SizedBox.shrink();
      }
      final percent = task.bytePercent;
      return PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(task.label),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  task.currentName.isEmpty ? '…' : task.currentName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 16),
                LinearProgressIndicator(
                  value: task.measuring || task.bytesTotal <= 0
                      ? null
                      : percent / 100,
                ),
                const SizedBox(height: 8),
                Text(
                  task.measuring
                      ? l10n.appsExportMeasuring
                      : '${l10n.appsExportPercent(percent)}  ${l10n.appsExportBytes(formatFileSize(task.bytesDone), formatFileSize(task.bytesTotal))}',
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: widget.controller.requestCancel,
              child: Text(l10n.appsCancelTask),
            ),
          ],
        ),
      );
    });
  }
}
