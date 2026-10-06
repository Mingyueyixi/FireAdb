import 'package:flutter/material.dart';

import '../../l10n/fire_adb_localizations_ext.dart';
import '../../l10n/generated/fire_adb_localizations.dart';
import '../data/bean/app_freeze.dart';
import '../data/bean/installed_app.dart';

String freezeMethodTitle(FireAdbLocalizations l10n, AppFreezeMethod method) {
  return switch (method) {
    AppFreezeMethod.disableUser => l10n.appsFreezeMethodDisableUser,
    AppFreezeMethod.suspend => l10n.appsFreezeMethodSuspend,
    AppFreezeMethod.amFreeze => l10n.appsFreezeMethodAmFreeze,
  };
}

String freezeMethodDescription(
  FireAdbLocalizations l10n,
  AppFreezeMethod method,
) {
  return switch (method) {
    AppFreezeMethod.disableUser => l10n.appsFreezeMethodDisableUserDescription,
    AppFreezeMethod.suspend => l10n.appsFreezeMethodSuspendDescription,
    AppFreezeMethod.amFreeze => l10n.appsFreezeMethodAmFreezeDescription,
  };
}

String freezeMethodCommandHint(AppFreezeMethod method) {
  return switch (method) {
    AppFreezeMethod.disableUser => 'pm disable-user / pm enable',
    AppFreezeMethod.suspend => 'pm suspend / pm unsuspend',
    AppFreezeMethod.amFreeze => 'am freeze / am unfreeze',
  };
}

Future<AppFreezeMethod?> showBatchFreezeDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  required bool danger,
  required AppFreezeMethod preferred,
}) {
  final l10n = context.l10n;
  var selected = preferred;
  return showDialog<AppFreezeMethod>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) {
        final scheme = Theme.of(context).colorScheme;
        return AlertDialog(
          scrollable: true,
          title: Text(title),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  message,
                  style: danger ? TextStyle(color: scheme.error) : null,
                ),
                const SizedBox(height: 12),
                RadioGroup<AppFreezeMethod>(
                  groupValue: selected,
                  onChanged: (value) {
                    if (value == null) return;
                    setDialogState(() => selected = value);
                  },
                  child: Column(
                    children: <Widget>[
                      for (final method in AppFreezeMethod.values)
                        RadioListTile<AppFreezeMethod>(
                          value: method,
                          contentPadding: EdgeInsets.zero,
                          title: Text(freezeMethodTitle(l10n, method)),
                          subtitle: Text(
                            '${freezeMethodDescription(l10n, method)}\n${freezeMethodCommandHint(method)}',
                          ),
                          isThreeLine: true,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              style: danger
                  ? FilledButton.styleFrom(
                      backgroundColor: scheme.error,
                      foregroundColor: scheme.onError,
                    )
                  : null,
              onPressed: () => Navigator.pop(context, selected),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    ),
  );
}

Future<AppFreezeMethod?> showFreezeMethodDialog(
  BuildContext context, {
  required InstalledApp app,
  required AppFreezeMethod preferred,
}) {
  final l10n = context.l10n;
  var selected = preferred;
  return showDialog<AppFreezeMethod>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text(l10n.appsFreezeTitle),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(l10n.appsFreezePrompt(app.displayName)),
              const SizedBox(height: 12),
              RadioGroup<AppFreezeMethod>(
                groupValue: selected,
                onChanged: (value) {
                  if (value == null) return;
                  setDialogState(() => selected = value);
                },
                child: Column(
                  children: <Widget>[
                    for (final method in AppFreezeMethod.values)
                      RadioListTile<AppFreezeMethod>(
                        value: method,
                        contentPadding: EdgeInsets.zero,
                        title: Text(freezeMethodTitle(l10n, method)),
                        subtitle: Text(
                          '${freezeMethodDescription(l10n, method)}\n${freezeMethodCommandHint(method)}',
                        ),
                        isThreeLine: true,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, selected),
            child: Text(l10n.appsFreezeAction),
          ),
        ],
      ),
    ),
  );
}
