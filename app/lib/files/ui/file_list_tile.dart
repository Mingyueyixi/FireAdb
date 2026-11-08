import 'package:flutter/material.dart';

import '../../l10n/fireadb_localizations_ext.dart';
import '../data/source/remote_file_commands.dart';
import '../file_entry.dart';

enum FileTileAction {
  open,
  export,
  rename,
  copy,
  cut,
  edit,
  permission,
  delete,
}

class FileListTile extends StatelessWidget {
  const FileListTile({
    super.key,
    required this.file,
    required this.showPath,
    required this.selecting,
    required this.selected,
    required this.busy,
    required this.onTap,
    required this.onToggleSelected,
    required this.onStartSelecting,
    required this.onAction,
    this.showExport = true,
  });

  final FileEntry file;

  /// 导出是跨机传输，仅设备后端显示。
  final bool showExport;
  final bool showPath;
  final bool selecting;
  final bool selected;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback onToggleSelected;
  final VoidCallback onStartSelecting;
  final ValueChanged<FileTileAction> onAction;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final subtitle = <String>[
      if (file.canEnter) l10n.filesFolder,
      if (file.isLink) l10n.filesLink,
      if (!file.canEnter && file.sizeKnown) formatFileSize(file.size),
      if (file.mtime > 0) formatRemoteTime(file.mtime),
      if ((file.mode & 0x1ff) != 0) formatPermission(file.mode),
    ].join('  ');
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 16),
      leading: selecting
          ? Checkbox(
              value: selected,
              onChanged: busy ? null : (_) => onToggleSelected(),
            )
          : Icon(_icon),
      title: Text(
        showPath ? file.path : file.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
      onTap: busy ? null : onTap,
      onLongPress: busy ? null : onStartSelecting,
      trailing: selecting
          ? null
          : PopupMenuButton<FileTileAction>(
              padding: EdgeInsets.zero,
              enabled: !busy,
              onSelected: onAction,
              itemBuilder: (context) => <PopupMenuEntry<FileTileAction>>[
                if (file.canEnter)
                  PopupMenuItem(
                    value: FileTileAction.open,
                    child: Text(l10n.filesOpen),
                  ),
                if (showExport)
                  PopupMenuItem(
                    value: FileTileAction.export,
                    child: Text(l10n.filesExport),
                  ),
                PopupMenuItem(
                  value: FileTileAction.rename,
                  child: Text(l10n.filesRename),
                ),
                PopupMenuItem(
                  value: FileTileAction.copy,
                  child: Text(l10n.filesCopy),
                ),
                PopupMenuItem(
                  value: FileTileAction.cut,
                  child: Text(l10n.filesCut),
                ),
                if (!file.canEnter)
                  PopupMenuItem(
                    value: FileTileAction.edit,
                    child: Text(l10n.filesEdit),
                  ),
                if (file.canChmod)
                  PopupMenuItem(
                    value: FileTileAction.permission,
                    child: Text(l10n.filesPermission),
                  ),
                PopupMenuItem(
                  value: FileTileAction.delete,
                  child: Text(l10n.filesDelete),
                ),
              ],
            ),
    );
  }

  IconData get _icon {
    if (file.canEnter) return Icons.folder;
    if (file.isLink) return Icons.link;
    return Icons.insert_drive_file_outlined;
  }
}
