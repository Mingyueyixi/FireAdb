import 'package:flutter/material.dart';

import '../../l10n/fire_adb_localizations_ext.dart';
import '../data/bean/app_freeze.dart';
import '../data/bean/installed_app.dart';
import 'app_freeze_dialogs.dart';

Future<bool> confirmUninstallApp(BuildContext context, InstalledApp app) async {
  final l10n = context.l10n;
  final system = app.isSystem || app.isCoreSystem;
  final core = app.isCoreSystem;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        title: Text(
          core
              ? l10n.appsUninstallCoreTitle
              : system
              ? l10n.appsUninstallSystemTitle
              : l10n.appsUninstallTitle,
        ),
        content: Text(
          core
              ? l10n.appsUninstallCoreConfirm(app.displayName, app.packageName)
              : system
              ? l10n.appsUninstallSystemConfirm(
                  app.displayName,
                  app.packageName,
                )
              : l10n.appsUninstallConfirm(app.displayName, app.packageName),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            style: system ? _dangerButtonStyle(scheme) : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              system
                  ? l10n.appsUninstallConfirmAction
                  : l10n.appsUninstallAction,
            ),
          ),
        ],
      );
    },
  );
  return confirmed == true;
}

Future<bool> confirmFreezeSystemApp(
  BuildContext context,
  InstalledApp app,
) async {
  final l10n = context.l10n;
  final core = app.isCoreSystem;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        title: Text(
          core ? l10n.appsFreezeCoreTitle : l10n.appsFreezeSystemTitle,
        ),
        content: Text(
          core
              ? l10n.appsFreezeCoreConfirm(app.displayName, app.packageName)
              : l10n.appsFreezeSystemConfirm(app.displayName, app.packageName),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            style: _dangerButtonStyle(scheme),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.appsFreezeConfirmAction),
          ),
        ],
      );
    },
  );
  return confirmed == true;
}

Future<bool> confirmBatchUninstall(
  BuildContext context,
  List<InstalledApp> apps,
) async {
  final l10n = context.l10n;
  final risk = systemAppRisk(apps);
  final danger = risk != SystemAppRisk.none;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        title: Text(switch (risk) {
          SystemAppRisk.core => l10n.appsUninstallCoreTitle,
          SystemAppRisk.system => l10n.appsUninstallSystemTitle,
          SystemAppRisk.none => l10n.appsUninstallTitle,
        }),
        content: Text(switch (risk) {
          SystemAppRisk.core => l10n.appsBatchUninstallCoreConfirm(
            apps.length,
            joinedAppNames(context, apps.where((app) => app.isCoreSystem)),
          ),
          SystemAppRisk.system => l10n.appsBatchUninstallSystemConfirm(
            apps.length,
            joinedAppNames(
              context,
              apps.where((app) => app.isSystem || app.isCoreSystem),
            ),
          ),
          SystemAppRisk.none => l10n.appsBatchUninstallConfirm(apps.length),
        }, style: danger ? TextStyle(color: scheme.error) : null),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            style: danger ? _dangerButtonStyle(scheme) : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              danger
                  ? l10n.appsUninstallConfirmAction
                  : l10n.appsUninstallAction,
            ),
          ),
        ],
      );
    },
  );
  return confirmed == true;
}

Future<AppFreezeMethod?> confirmBatchFreeze(
  BuildContext context, {
  required List<InstalledApp> apps,
  required AppFreezeMethod preferred,
}) {
  final l10n = context.l10n;
  final risk = systemAppRisk(apps);
  final danger = risk != SystemAppRisk.none;
  return showBatchFreezeDialog(
    context,
    title: switch (risk) {
      SystemAppRisk.core => l10n.appsFreezeCoreTitle,
      SystemAppRisk.system => l10n.appsFreezeSystemTitle,
      SystemAppRisk.none => l10n.appsFreezeTitle,
    },
    message: switch (risk) {
      SystemAppRisk.core => l10n.appsBatchFreezeCoreConfirm(
        apps.length,
        joinedAppNames(context, apps.where((app) => app.isCoreSystem)),
      ),
      SystemAppRisk.system => l10n.appsBatchFreezeSystemConfirm(
        apps.length,
        joinedAppNames(
          context,
          apps.where((app) => app.isSystem || app.isCoreSystem),
        ),
      ),
      SystemAppRisk.none => l10n.appsBatchFreezeConfirm(apps.length),
    },
    confirmLabel: danger ? l10n.appsFreezeConfirmAction : l10n.appsFreezeAction,
    danger: danger,
    preferred: preferred,
  );
}

String joinedAppNames(BuildContext context, Iterable<InstalledApp> apps) {
  final separator = Localizations.localeOf(context).languageCode == 'zh'
      ? '、'
      : ', ';
  final names = apps.map((app) => app.displayName).toList();
  if (names.length <= 6) return names.join(separator);
  return '${names.take(6).join(separator)}…';
}

ButtonStyle _dangerButtonStyle(ColorScheme scheme) {
  return FilledButton.styleFrom(
    backgroundColor: scheme.error,
    foregroundColor: scheme.onError,
  );
}
