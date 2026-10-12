import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_feedback.dart';
import '../l10n/fire_adb_localizations_ext.dart';
import '../log/app_log.dart';

class ShellOutputSettings {
  ShellOutputSettings._();

  static const String _preferenceKey = 'shellOutputLimitMiB';
  static const int defaultLimitMiB = 10;
  static const int minLimitMiB = 1;
  static const int maxLimitMiB = 100;

  static Future<int> loadLimitMiB() async {
    final preferences = await SharedPreferences.getInstance();
    final savedLimit = preferences.getInt(_preferenceKey);
    if (savedLimit == null) return defaultLimitMiB;
    return savedLimit.clamp(minLimitMiB, maxLimitMiB).toInt();
  }

  static Future<void> show(
    BuildContext context, {
    required int currentLimitMiB,
    required ValueChanged<int> onSaved,
  }) async {
    final l10n = context.l10n;
    var selectedLimit = currentLimitMiB.clamp(minLimitMiB, maxLimitMiB).toInt();
    final newLimit = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(l10n.shellOutputSettings),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(l10n.shellMaxRetainedOutput(selectedLimit)),
              Slider(
                value: selectedLimit.toDouble(),
                min: minLimitMiB.toDouble(),
                max: maxLimitMiB.toDouble(),
                divisions: maxLimitMiB - minLimitMiB,
                label: '$selectedLimit MiB',
                onChanged: (value) {
                  setDialogState(() => selectedLimit = value.round());
                },
              ),
              Text(l10n.shellOutputLimitNote),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(selectedLimit),
              child: Text(l10n.commonSave),
            ),
          ],
        ),
      ),
    );
    if (newLimit == null || !context.mounted) return;

    try {
      final preferences = await SharedPreferences.getInstance();
      final saved = await preferences.setInt(_preferenceKey, newLimit);
      if (!saved) throw StateError('SharedPreferences 未能保存 Shell 输出设置');
      if (context.mounted) onSaved(newLimit);
    } catch (error, stackTrace) {
      log.severe('保存 Shell 输出设置失败', error, stackTrace);
      if (context.mounted) {
        showAppMessage(
          ScaffoldMessenger.of(context),
          Theme.of(context),
          title: l10n.commonSettingsSaveFailed,
          message: '$error',
          isError: true,
        );
      }
    }
  }
}
