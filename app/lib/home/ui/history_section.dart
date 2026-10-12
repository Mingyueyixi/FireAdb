import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../l10n/fire_adb_localizations_ext.dart';
import '../home_actions.dart';
import '../home_controller.dart';
import 'home_section.dart';

class HistorySection extends GetView<HomeController> {
  const HistorySection({super.key});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final theme = Theme.of(context);
      final l10n = context.l10n;
      final history = controller.manager.history;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              HomeSectionHeader(
                icon: Icons.history,
                title: l10n.homeHistoryConnections,
              ),
              const SizedBox(height: 4),
              if (history.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    l10n.homeNoHistory,
                    style: TextStyle(color: theme.colorScheme.outline),
                  ),
                )
              else
                for (final profile in history)
                  HomeListTile(
                    dense: true,
                    leading: const Icon(Icons.smartphone),
                    title: Text(profile.displayName),
                    subtitle: Text(profile.connectionAddress, maxLines: 2),
                    trailing: IconButton(
                      tooltip: l10n.homeRemoveHistory,
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () =>
                          controller.manager.removeFromHistory(profile),
                    ),
                    onTap: () =>
                        connectHistoryProfile(context, controller, profile),
                  ),
            ],
          ),
        ),
      );
    });
  }
}
