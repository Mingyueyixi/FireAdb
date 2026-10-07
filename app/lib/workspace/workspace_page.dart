import 'package:fire_adb/connection/connection_manager.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../l10n/fire_adb_localizations_ext.dart';
import '../widgets/adaptive.dart' show isWide, isAtLeastTablet;
import '../widgets/locale_selector.dart';
import 'data/feature_spec.dart';
import 'feature_cache.dart';
import 'feature_tile.dart';
import 'workspace_controller.dart';

/// 设备工作区：切换设备 + 选择功能。
///
/// 桌面（宽屏）：左侧设备栏 + 功能栏 + 内容面板（三栏分栏）。
/// 移动端（窄屏）：顶部下拉切换设备，功能九宫格，点进功能后全屏显示同一份页面。
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

  void _openFeature(FeatureSpec spec) => controller.openFeature(spec.id);

  Widget _featureCache(List<String> serials) {
    return FeatureCache(
      key: controller.featureCacheKey,
      serials: serials,
      serial: controller.selectedSerial.value,
      featureId: controller.currentFeatureId,
    );
  }

  Widget _keepCache(Widget foreground, Widget cache) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        foreground,
        Offstage(child: cache),
      ],
    );
  }

  Widget _buildWide(BuildContext context, List<String> serials, Widget cache) {
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
                      selected: spec.id == controller.currentFeatureId,
                      onTap: () => controller.selectFeature(spec.id),
                    ),
                ],
              ),
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: SafeArea(child: cache)),
        ],
      ),
    );
  }

  Widget _buildNarrowFeature(BuildContext context, Widget cache) {
    final spec = featureSpecById(controller.currentFeatureId);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) controller.closeFeature();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: controller.closeFeature),
          title: Text(featureTitle(context, spec)),
          actions: const <Widget>[LocaleSelector()],
        ),
        body: cache,
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
              FeatureTile(spec: spec, onTap: () => _openFeature(spec)),
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
      final cache = _featureCache(serials);
      if (!serials.contains(controller.selectedSerial.value)) {
        return _keepCache(_buildDisconnected(context, serials), cache);
      }
      if (isWide(context)) {
        return _buildWide(context, serials, cache);
      }
      if (controller.narrowFeatureOpen.value) {
        return _buildNarrowFeature(context, cache);
      }
      return _keepCache(_buildNarrow(context, serials), cache);
    });
  }
}
