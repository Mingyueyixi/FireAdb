import 'package:flutter/material.dart';

import '../../l10n/fire_adb_localizations_ext.dart';
import '../../shell/device_root_store.dart';
import '../../shell/su_mode_chip.dart';
import '../data/bean/installed_app.dart';

class AppsToolbar extends StatelessWidget {
  const AppsToolbar({
    super.key,
    required this.serial,
    required this.search,
    required this.filter,
    required this.onFilter,
    required this.selecting,
    required this.busy,
    required this.loading,
    required this.visibleCount,
    required this.markedCount,
    required this.selectedCount,
    required this.onToggleSelecting,
    required this.onRefresh,
    required this.onSelectAll,
    required this.onClearSelection,
    required this.onExport,
    required this.onFreeze,
    required this.onUninstall,
  });

  final String serial;
  final TextEditingController search;
  final AppListFilter filter;
  final ValueChanged<AppListFilter> onFilter;
  final bool selecting;
  final bool busy;
  final bool loading;
  final int visibleCount;
  final int markedCount;
  final int selectedCount;
  final VoidCallback onToggleSelecting;
  final VoidCallback onRefresh;
  final VoidCallback onSelectAll;
  final VoidCallback onClearSelection;
  final VoidCallback onExport;
  final VoidCallback onFreeze;
  final VoidCallback onUninstall;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final canRun = !busy && selectedCount > 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            controller: search,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: l10n.appsSearchHint,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 4),
          SuModeChip(serial: serial, scope: SuScope.apps),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final entry in <(AppListFilter, String)>[
                    (AppListFilter.user, l10n.appsFilterUser),
                    (AppListFilter.system, l10n.appsFilterSystem),
                    (AppListFilter.debug, l10n.appsFilterDebug),
                    (AppListFilter.frozen, l10n.appsFilterFrozen),
                    (AppListFilter.all, l10n.appsFilterAll),
                  ])
                    FilterChip(
                      label: Text(entry.$2),
                      selected: filter == entry.$1,
                      onSelected: (_) => onFilter(entry.$1),
                    ),
                ],
              ),
              IconButton(
                tooltip: selecting ? l10n.appsSelectDone : l10n.appsSelect,
                onPressed: busy ? null : onToggleSelecting,
                icon: Icon(selecting ? Icons.close : Icons.checklist),
              ),
              IconButton(
                tooltip: l10n.appsRefresh,
                onPressed: loading || busy ? null : onRefresh,
                icon: const Icon(Icons.refresh),
              ),
              Text(
                l10n.appsCount(visibleCount),
                style: theme.textTheme.bodySmall,
              ),
              if (selecting)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    Text(
                      l10n.appsSelectedCount(selectedCount),
                      style: theme.textTheme.bodySmall,
                    ),
                    TextButton(
                      onPressed: busy ? null : onSelectAll,
                      child: Text(l10n.appsSelectAll),
                    ),
                    TextButton(
                      onPressed: busy || markedCount == 0
                          ? null
                          : onClearSelection,
                      child: Text(l10n.appsSelectClear),
                    ),
                    TextButton(
                      onPressed: canRun ? onExport : null,
                      child: Text(l10n.appsExportAction),
                    ),
                    TextButton(
                      onPressed: canRun ? onFreeze : null,
                      child: Text(l10n.appsFreezeAction),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                      onPressed: canRun ? onUninstall : null,
                      child: Text(l10n.appsUninstallAction),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}
