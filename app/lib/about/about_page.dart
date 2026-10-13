import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../l10n/fire_adb_localizations_ext.dart';
import '../log/app_log.dart';

/// 应用名称、版本和构建号。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  PackageInfo? _info;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _info = info);
    } catch (error, stackTrace) {
      log.severe('读取应用版本失败', error, stackTrace);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final info = _info;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: <Widget>[
            Icon(Icons.adb, size: 56, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text(
              'FireAdb',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              info == null
                  ? l10n.aboutVersionUnknown
                  : l10n.aboutVersion(info.version),
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            if (info != null && info.buildNumber.isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                l10n.aboutBuild(info.buildNumber),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              l10n.aboutDescription,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
