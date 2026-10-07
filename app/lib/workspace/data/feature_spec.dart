import 'package:flutter/material.dart';

import '../../l10n/fire_adb_localizations_ext.dart';

/// 设备页的某个功能入口（总览已实现，其余为规划中的占位）。
class FeatureSpec {
  const FeatureSpec({
    required this.id,
    required this.icon,
    this.implemented = false,
  });

  final String id;
  final IconData icon;
  final bool implemented;
}

const String kOverviewFeatureId = 'overview';

String featureTitle(BuildContext context, FeatureSpec feature) {
  final l10n = context.l10n;
  return switch (feature.id) {
    kOverviewFeatureId => l10n.workspaceOverviewTitle,
    'apps' => l10n.workspaceAppsTitle,
    'files' => l10n.workspaceFilesTitle,
    'screenshot' => l10n.workspaceScreenshotTitle,
    'screenrecord' => l10n.workspaceScreenrecordTitle,
    'shell' => l10n.workspaceShellTitle,
    _ => feature.id,
  };
}

String featureDescription(BuildContext context, FeatureSpec feature) {
  final l10n = context.l10n;
  return switch (feature.id) {
    kOverviewFeatureId => l10n.workspaceOverviewDescription,
    'apps' => l10n.workspaceAppsDescription,
    'files' => l10n.workspaceFilesDescription,
    'screenshot' => l10n.workspaceScreenshotDescription,
    'screenrecord' => l10n.workspaceScreenrecordDescription,
    'shell' => l10n.workspaceShellDescription,
    _ => '',
  };
}

const List<FeatureSpec> kDeviceFeatures = <FeatureSpec>[
  FeatureSpec(
    id: kOverviewFeatureId,
    icon: Icons.phonelink_ring,
    implemented: true,
  ),
  FeatureSpec(id: 'apps', icon: Icons.apps, implemented: true),
  FeatureSpec(id: 'files', icon: Icons.folder_open, implemented: true),
  FeatureSpec(id: 'screenshot', icon: Icons.screenshot_monitor),
  FeatureSpec(id: 'screenrecord', icon: Icons.videocam),
  FeatureSpec(id: 'shell', icon: Icons.terminal, implemented: true),
];
