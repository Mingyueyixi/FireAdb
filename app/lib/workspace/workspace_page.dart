import 'package:fire_adb/connection/connection_manager.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../apps/apps_page.dart';
import '../device_overview/device_overview_page.dart';
import '../l10n/fire_adb_localizations_ext.dart';
import '../shell/shell_page.dart';
import '../widgets/adaptive.dart' show isWide, isAtLeastTablet;
import '../widgets/locale_selector.dart';
import 'data/feature_spec.dart';
import 'feature_tile.dart';
import 'placeholder_feature_page.dart';
import 'workspace_controller.dart';

/// 设备工作区：切换设备 + 选择功能。
///
/// 桌面（宽屏）：左侧设备栏 + 功能栏 + 内容面板（三栏分栏）。
/// 移动端（窄屏）：顶部下拉切换设备，功能九宫格，点击进入全屏页。
class WorkspacePage extends GetView<WorkspaceController> {
  const WorkspacePage({super.key});

  String _shortName(String serial) {
    final colon = serial.indexOf(':');
    return colon > 0 ? serial.substring(0, colon) : serial;
  }

  Widget _homeButton(BuildContext context) {
    return IconButton(
      tooltip: context.l10n.workspaceBackToHome,
      onPressed: () => Get.offAllNamed<void>('/'),
      icon: const Icon(Icons.arrow_back),
    );
  }

  void _openFeature(BuildContext context, FeatureSpec spec) {
    if (spec.id == kOverviewFeatureId) {
      Get.to<void>(
        () => Scaffold(
          appBar: AppBar(
            title: Builder(
              builder: (context) => Text(featureTitle(context, spec)),
            ),
            actions: const <Widget>[LocaleSelector()],
          ),
          body: DeviceOverviewPage(serial: controller.selectedSerial.value),
        ),
      );
      return;
    }
    if (spec.id == 'shell') {
      Get.to<void>(
        () => Scaffold(
          appBar: AppBar(
            title: Builder(
              builder: (context) => Text(featureTitle(context, spec)),
            ),
            actions: const <Widget>[LocaleSelector()],
          ),
          body: ShellPage(serial: controller.selectedSerial.value),
        ),
      );
      return;
    }
    if (spec.id == 'apps') {
      Get.to<void>(
        () => AppsFeaturePage(serial: controller.selectedSerial.value),
      );
      return;
    }
    Get.to<void>(() => PlaceholderFeaturePage(spec: spec));
  }

  Widget _buildFeaturePane(BuildContext context) {
    final spec = kDeviceFeatures.firstWhere(
      (f) => f.id == controller.selectedFeature.value,
    );
    if (spec.id == kOverviewFeatureId) {
      return DeviceOverviewPage(serial: controller.selectedSerial.value);
    }
    if (spec.id == 'shell') {
      return ShellPage(serial: controller.selectedSerial.value);
    }
    if (spec.id == 'apps') {
      return AppsPage(serial: controller.selectedSerial.value);
    }
    return PlaceholderFeatureBody(spec: spec);
  }

  Widget _buildWide(BuildContext context, List<String> serials) {
    final selectedIndex = serials.indexOf(controller.selectedSerial.value);
    return Scaffold(
      appBar: AppBar(
        leading: _homeButton(context),
        title: const Text('FireAdb'),
        actions: const <Widget>[LocaleSelector()],
      ),
      body: Row(
        children: <Widget>[
          NavigationRail(
            selectedIndex: selectedIndex,
            onDestinationSelected: (i) => controller.selectSerial(serials[i]),
            labelType: NavigationRailLabelType.all,
            destinations: <NavigationRailDestination>[
              for (final s in serials)
                NavigationRailDestination(
                  icon: const Icon(Icons.smartphone),
                  selectedIcon: const Icon(Icons.phone_android),
                  label: Text(_shortName(s)),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          SafeArea(
            child: SizedBox(
              width: 220,
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      context.l10n.workspaceFeatures,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  for (final spec in kDeviceFeatures)
                    FeatureListTile(
                      spec: spec,
                      selected: spec.id == controller.selectedFeature.value,
                      onTap: () => controller.selectFeature(spec.id),
                    ),
                ],
              ),
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: SafeArea(child: _buildFeaturePane(context))),
        ],
      ),
    );
  }

  Widget _buildNarrow(BuildContext context, List<String> serials) {
    final gridCount = isAtLeastTablet(context) ? 4 : 2;
    return Scaffold(
      appBar: AppBar(
        leading: _homeButton(context),
        actions: const <Widget>[LocaleSelector()],
        title: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: controller.selectedSerial.value,
            isDense: true,
            items: <DropdownMenuItem<String>>[
              for (final s in serials)
                DropdownMenuItem<String>(value: s, child: Text(_shortName(s))),
            ],
            onChanged: (s) {
              if (s != null) controller.selectSerial(s);
            },
          ),
        ),
      ),
      body: SafeArea(
        child: GridView.count(
          padding: const EdgeInsets.all(16),
          crossAxisCount: gridCount,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          children: <Widget>[
            for (final spec in kDeviceFeatures)
              FeatureTile(spec: spec, onTap: () => _openFeature(context, spec)),
          ],
        ),
      ),
    );
  }

  Widget _buildDisconnected(BuildContext context, List<String> serials) {
    final hasAny = serials.isNotEmpty;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: _homeButton(context),
        title: const Text('FireAdb'),
        actions: const <Widget>[LocaleSelector()],
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.usb_off, size: 64, color: scheme.outline),
            const SizedBox(height: 16),
            Text(context.l10n.workspaceDeviceDisconnectedTitle),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: hasAny
                  ? () => controller.selectSerial(serials.first)
                  : () => Get.back<void>(),
              child: Text(
                hasAny
                    ? context.l10n.workspaceSwitchToOtherDevice
                    : context.l10n.workspaceBackToConnections,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final manager = Get.find<ConnectionManager>();
    return Obx(() {
      final serials = manager.profiles.map((p) => p.serial).toList();
      if (!serials.contains(controller.selectedSerial.value)) {
        return _buildDisconnected(context, serials);
      }
      if (isWide(context)) {
        return _buildWide(context, serials);
      }
      return _buildNarrow(context, serials);
    });
  }
}
