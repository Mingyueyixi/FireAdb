import 'package:flutter/material.dart';

import '../l10n/fire_adb_localizations_ext.dart';
import 'data/feature_spec.dart';

/// 功能入口卡片（移动端九宫格用）。
class FeatureTile extends StatelessWidget {
  const FeatureTile({super.key, required this.spec, this.onTap});

  final FeatureSpec spec;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(spec.icon, size: 32, color: scheme.primary),
                  const Spacer(),
                  if (!spec.implemented)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        l10n.workspacePlanned,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.outline,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                featureTitle(context, spec),
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                featureDescription(context, spec),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 功能列表项（桌面端功能栏用）。
class FeatureListTile extends StatelessWidget {
  const FeatureListTile({
    super.key,
    required this.spec,
    this.selected = false,
    this.onTap,
  });

  final FeatureSpec spec;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListTile(
      leading: Icon(spec.icon),
      title: Text(featureTitle(context, spec)),
      subtitle: spec.implemented ? null : Text(l10n.workspacePlanned),
      selected: selected,
      onTap: onTap,
    );
  }
}

/// 未实现功能的占位内容（桌面内容面板与移动端全屏页共用）。
class PlaceholderFeatureBody extends StatelessWidget {
  const PlaceholderFeatureBody({super.key, required this.spec});

  final FeatureSpec spec;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(spec.icon, size: 72, color: scheme.outline),
            const SizedBox(height: 16),
            Text(
              featureTitle(context, spec),
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              featureDescription(context, spec),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.outline,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.workspaceFeaturePlannedDescription,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
