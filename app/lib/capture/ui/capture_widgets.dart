import 'package:flutter/material.dart';

import '../../app_feedback.dart';
import '../../files/data/source/remote_file_commands.dart';
import '../../l10n/fire_adb_localizations_ext.dart';
import '../../log/app_log.dart';
import '../capture_notice.dart';
import '../data/capture_store.dart';

void showCaptureNotice(BuildContext context, CaptureNotice? notice) {
  if (notice == null) return;
  if (notice.isError) {
    log.info('${notice.title}\n${notice.message}');
  }
  if (!context.mounted) return;
  if (notice.isError) {
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(notice.title),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(child: SelectableText(notice.message)),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(MaterialLocalizations.of(context).okButtonLabel),
            ),
          ],
        );
      },
    );
    return;
  }
  showAppMessage(
    ScaffoldMessenger.of(context),
    Theme.of(context),
    title: notice.title,
    message: notice.message,
    isError: notice.isError,
  );
}

Future<bool> confirmDeleteCapture(BuildContext context, String name) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) {
      final l10n = context.l10n;
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        title: Text(l10n.captureDelete),
        content: Text(
          l10n.captureDeleteConfirm(name),
          style: TextStyle(color: scheme.error),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.captureDelete),
          ),
        ],
      );
    },
  );
  return confirmed == true;
}

class CaptureDirectoryBar extends StatelessWidget {
  const CaptureDirectoryBar({
    super.key,
    required this.path,
    required this.enabled,
    required this.onOpen,
    required this.onRefresh,
  });

  final String path;
  final bool enabled;
  final VoidCallback onOpen;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  l10n.captureSaveLocation,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  path,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: l10n.captureRefresh,
            onPressed: enabled ? onRefresh : null,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: l10n.captureOpenFolder,
            onPressed: enabled ? onOpen : null,
            icon: const Icon(Icons.folder_open),
          ),
        ],
      ),
    );
  }
}

class CaptureFileList extends StatelessWidget {
  const CaptureFileList({
    super.key,
    required this.files,
    required this.emptyText,
    required this.selectedPath,
    required this.busy,
    required this.icon,
    required this.onTap,
    required this.onOpen,
    required this.onDelete,
    this.embedded = false,
  });

  final List<CaptureFile> files;
  final String emptyText;
  final String? selectedPath;
  final bool busy;
  final IconData icon;
  final ValueChanged<CaptureFile> onTap;
  final ValueChanged<CaptureFile> onOpen;
  final ValueChanged<CaptureFile> onDelete;

  /// 放进外层滚动视图时不再自己滚动。
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (files.isEmpty) {
      final empty = Padding(
        padding: const EdgeInsets.all(24),
        child: Text(emptyText, style: theme.textTheme.bodyMedium),
      );
      return embedded ? empty : Center(child: empty);
    }
    if (embedded) {
      return Column(
        children: <Widget>[
          for (var index = 0; index < files.length; index++) ...<Widget>[
            if (index > 0) const Divider(height: 1),
            _tile(context, files[index]),
          ],
        ],
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
      itemCount: files.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) => _tile(context, files[index]),
    );
  }

  Widget _tile(BuildContext context, CaptureFile file) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final subtitle = <String>[
      formatFileSize(file.size),
      formatRemoteTime(file.modified.millisecondsSinceEpoch ~/ 1000),
    ].where((part) => part.isNotEmpty).join('  ');
    return ListTile(
      key: ValueKey<String>(file.path),
      selected: file.path == selectedPath,
      leading: Icon(icon),
      title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      onTap: busy ? null : () => onTap(file),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            tooltip: l10n.captureOpenFile,
            onPressed: busy ? null : () => onOpen(file),
            icon: const Icon(Icons.open_in_new),
          ),
          IconButton(
            tooltip: l10n.captureDelete,
            onPressed: busy ? null : () => onDelete(file),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }
}
