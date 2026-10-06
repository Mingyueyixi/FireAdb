import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_feedback.dart';

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
    var selectedLimit = currentLimitMiB.clamp(minLimitMiB, maxLimitMiB).toInt();
    final newLimit = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Shell 输出设置'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('最大保留输出：$selectedLimit MiB'),
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
              const Text('不限制行数；达到容量后仅移除较早的输出。'),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(selectedLimit),
              child: const Text('保存'),
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
      logAppError('保存 Shell 输出设置失败', error, stackTrace);
      if (context.mounted) {
        showAppMessage(
          ScaffoldMessenger.of(context),
          Theme.of(context),
          title: '保存设置失败',
          message: '$error',
          isError: true,
        );
      }
    }
  }
}
