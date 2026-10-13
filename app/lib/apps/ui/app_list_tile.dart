import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../l10n/fire_adb_localizations_ext.dart';
import '../data/bean/installed_app.dart';
import '../data/source/app_inventory.dart';

enum AppTileAction { details, export, uninstall, freeze, unfreeze }

/// 固定高度的应用行。名称、版本、体积和路径后到时不再把行撑高。
class AppListTile extends StatelessWidget {
  const AppListTile({
    super.key,
    required this.app,
    required this.icon,
    required this.selecting,
    required this.selected,
    required this.busy,
    required this.onToggleSelected,
    required this.onStartSelecting,
    required this.onUnfreeze,
    required this.onOpen,
    required this.onAction,
  });

  final InstalledApp app;
  final Uint8List? icon;
  final bool selecting;
  final bool selected;
  final bool busy;
  final VoidCallback onToggleSelected;
  final VoidCallback onStartSelecting;
  final VoidCallback onUnfreeze;
  final VoidCallback onOpen;
  final ValueChanged<AppTileAction> onAction;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final version = app.versionLabel;
    return ListTile(
      selected: selecting && selected,
      onTap: busy
          ? null
          : selecting
          ? onToggleSelected
          : onOpen,
      onLongPress: busy ? null : onStartSelecting,
      leading: _leading(theme),
      title: SizedBox(
        height: _AppMetaTag.height,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(
              child: Text(
                app.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (app.isDebuggable) ...<Widget>[
              const SizedBox(width: 8),
              _AppMetaTag(label: l10n.appsDebugBadge),
            ],
            if (app.isDisabledUser) ...<Widget>[
              const SizedBox(width: 8),
              _AppMetaTag(label: l10n.appsDisabledBadge),
            ],
            if (app.isSuspended) ...<Widget>[
              const SizedBox(width: 8),
              _AppMetaTag(label: l10n.appsSuspendedBadge),
            ],
            if (app.isAmFrozen) ...<Widget>[
              const SizedBox(width: 8),
              _AppMetaTag(label: l10n.appsAmFrozenBadge),
            ],
            if (app.isFrozen) ...<Widget>[
              const SizedBox(width: 8),
              _AppMetaTag.button(
                label: l10n.appsUnfreezeAction,
                onPressed: busy ? null : onUnfreeze,
              ),
            ],
          ],
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _detailLine(app.packageName),
          _detailLine(version.isEmpty ? '' : l10n.appsVersion(version)),
          _detailLine(
            app.sizeBytes == null
                ? ''
                : l10n.appsSize(formatByteSize(app.sizeBytes!)),
          ),
          _detailLine(
            app.primaryPath == null ? '' : l10n.appsPath(app.primaryPath!),
          ),
        ],
      ),
      trailing: PopupMenuButton<AppTileAction>(
        enabled: !busy,
        onSelected: onAction,
        itemBuilder: (context) => <PopupMenuEntry<AppTileAction>>[
          PopupMenuItem(
            value: AppTileAction.details,
            child: Text(l10n.appsDetailsAction),
          ),
          PopupMenuItem(
            value: AppTileAction.export,
            child: Text(l10n.appsExportAction),
          ),
          PopupMenuItem(
            value: AppTileAction.freeze,
            child: Text(l10n.appsFreezeAction),
          ),
          if (app.isFrozen)
            PopupMenuItem(
              value: AppTileAction.unfreeze,
              child: Text(l10n.appsUnfreezeAction),
            ),
          PopupMenuItem(
            value: AppTileAction.uninstall,
            child: Text(l10n.appsUninstallAction),
          ),
        ],
      ),
    );
  }

  Widget _leading(ThemeData theme) {
    final avatar = CircleAvatar(
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
      backgroundImage: icon == null ? null : MemoryImage(icon!),
      child: icon == null ? const Icon(Icons.android) : null,
    );
    if (!selecting) return avatar;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IgnorePointer(
          child: Checkbox(
            value: selected,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (_) {},
          ),
        ),
        avatar,
      ],
    );
  }
}

/// 空内容也占一行，避免后到的字段把行撑高。
Widget _detailLine(String text) {
  return Text(
    text.isEmpty ? '\u00a0' : text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  );
}

/// 应用状态标签与解冻按钮共用尺寸，保证同一行里等高。
class _AppMetaTag extends StatelessWidget {
  const _AppMetaTag({required this.label}) : onPressed = null, _button = false;

  const _AppMetaTag.button({required this.label, required this.onPressed})
    : _button = true;

  final String label;
  final VoidCallback? onPressed;
  final bool _button;

  static const double height = 32;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = !_button || onPressed != null;
    final background = _button && enabled
        ? scheme.secondaryContainer
        : scheme.surfaceContainerHighest;
    final foreground = _button && enabled
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant;
    final radius = BorderRadius.circular(height / 2);
    final child = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: height, maxHeight: height),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Center(
          child: Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(color: foreground),
          ),
        ),
      ),
    );
    return Material(
      color: background,
      borderRadius: radius,
      child: _button
          ? InkWell(onTap: onPressed, borderRadius: radius, child: child)
          : child,
    );
  }
}
