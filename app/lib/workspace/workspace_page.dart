import 'package:fire_adb/connection/connection_manager.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../l10n/fire_adb_localizations_ext.dart';
import '../widgets/adaptive.dart' show isWide, isAtLeastTablet;
import 'data/feature_spec.dart';
import 'device_switcher.dart';
import 'feature_cache.dart';
import 'feature_tile.dart';
import 'workspace_controller.dart';

/// 设备工作区：切换设备 + 选择功能。
///
/// 桌面（宽屏）：左侧已连接设备栏，栏底和标题栏都能打开设备列表。
/// 移动端（窄屏）：点标题栏里的设备名打开同一份列表。
/// 列表里已连接的用来切换，未连接的点一下就连接并切过去。
class WorkspacePage extends GetView<WorkspaceController> {
  const WorkspacePage({super.key});

  Widget _homeButton(BuildContext context) {
    return IconButton(
      tooltip: context.l10n.workspaceBackToHome,
      onPressed: () => Get.offAllNamed<void>('/'),
      icon: const Icon(Icons.arrow_back),
    );
  }

  Widget _deviceTitle(BuildContext context) {
    final serial = controller.selectedSerial.value;
    final name =
        Get.find<ConnectionManager>().profileOf(serial)?.displayName ?? serial;
    return TextButton.icon(
      onPressed: () => showWorkspaceDeviceSwitcher(context),
      iconAlignment: IconAlignment.end,
      icon: const Icon(Icons.arrow_drop_down),
      label: Text(name, overflow: TextOverflow.ellipsis),
    );
  }

  Widget _connectDeviceButton(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: InkWell(
        onTap: () => showWorkspaceDeviceSwitcher(context),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.add, color: theme.colorScheme.primary),
              const SizedBox(height: 4),
              Text(
                context.l10n.workspaceConnectDevice,
                style: theme.textTheme.labelSmall,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
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

  Widget _buildWide(
    BuildContext context,
    List<String> serials,
    Widget cache,
    ConnectionManager manager,
  ) {
    final selectedIndex = serials.indexOf(controller.selectedSerial.value);
    return Scaffold(
      appBar: AppBar(
        leading: _homeButton(context),
        title: const Text('FireAdb'),
        actions: <Widget>[_deviceTitle(context)],
      ),
      body: Row(
        children: <Widget>[
          NavigationRail(
            selectedIndex: selectedIndex,
            onDestinationSelected: (i) => controller.selectSerial(serials[i]),
            labelType: NavigationRailLabelType.all,
            scrollable: true,
            trailingAtBottom: true,
            trailing: _connectDeviceButton(context),
            destinations: <NavigationRailDestination>[
              for (final s in serials)
                NavigationRailDestination(
                  icon: const Icon(Icons.smartphone),
                  selectedIcon: const Icon(Icons.phone_android),
                  label: Text(manager.profileOf(s)?.displayName ?? s),
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
          actions: <Widget>[
            IconButton(
              tooltip: context.l10n.workspaceDevices,
              onPressed: () => showWorkspaceDeviceSwitcher(context),
              icon: const Icon(Icons.devices),
            ),
          ],
        ),
        body: cache,
      ),
    );
  }

  Widget _buildNarrow(BuildContext context) {
    final gridCount = isAtLeastTablet(context) ? 4 : 2;
    return Scaffold(
      appBar: AppBar(
        leading: _homeButton(context),
        title: _deviceTitle(context),
      ),
      body: SafeArea(
        child: GridView(
          padding: const EdgeInsets.all(16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: gridCount,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            mainAxisExtent: 148,
          ),
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
              onPressed: () => showWorkspaceDeviceSwitcher(context),
              child: Text(
                hasAny
                    ? context.l10n.workspaceSwitchToOtherDevice
                    : context.l10n.workspaceConnectDevice,
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
        return _buildWide(context, serials, cache, manager);
      }
      if (controller.narrowFeatureOpen.value) {
        return _buildNarrowFeature(context, cache);
      }
      return _keepCache(_buildNarrow(context), cache);
    });
  }
}
