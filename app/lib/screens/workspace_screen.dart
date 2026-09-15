import 'package:flutter/material.dart';

import '../models/feature_spec.dart';
import '../services/connection_manager.dart';
import '../widgets/adaptive.dart'
    show isWide, isAtLeastTablet;
import '../widgets/feature_tile.dart';
import 'features/device_overview.dart';
import 'features/placeholder_feature_page.dart';
import 'features/shell_panel.dart';

/// 设备工作区：切换设备 + 选择功能。
///
/// 桌面（宽屏）：左侧设备栏 + 功能栏 + 内容面板（三栏分栏）。
/// 移动端（窄屏）：顶部下拉切换设备，功能九宫格，点击进入全屏页。
class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({
    super.key,
    required this.serial,
    required this.manager,
  });

  final String serial;
  final ConnectionManager manager;

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> {
  late String _serial = widget.serial;
  String _feature = kOverviewFeatureId;

  String _shortName(String serial) {
    final colon = serial.indexOf(':');
    return colon > 0 ? serial.substring(0, colon) : serial;
  }

  void _openFeature(BuildContext context, FeatureSpec spec) {
    if (spec.id == kOverviewFeatureId) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            appBar: AppBar(title: Text(spec.title)),
            body: DeviceOverviewView(serial: _serial, manager: widget.manager),
          ),
        ),
      );
      return;
    }
    if (spec.id == 'shell') {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            appBar: AppBar(title: Text(spec.title)),
            body: ShellPanelView(serial: _serial, manager: widget.manager),
          ),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlaceholderFeaturePage(spec: spec),
      ),
    );
  }

  Widget _buildFeaturePane() {
    final spec = kDeviceFeatures.firstWhere((f) => f.id == _feature);
    if (spec.id == kOverviewFeatureId) {
      return DeviceOverviewView(serial: _serial, manager: widget.manager);
    }
    if (spec.id == 'shell') {
      return ShellPanelView(serial: _serial, manager: widget.manager);
    }
    return PlaceholderFeatureBody(spec: spec);
  }

  Widget _buildWide(BuildContext context, List<String> serials) {
    final selectedIndex = serials.indexOf(_serial);
    return Scaffold(
      body: Row(
        children: <Widget>[
          NavigationRail(
            selectedIndex: selectedIndex,
            onDestinationSelected: (i) =>
                setState(() => _serial = serials[i]),
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
                      '功能',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  for (final spec in kDeviceFeatures)
                    FeatureListTile(
                      spec: spec,
                      selected: spec.id == _feature,
                      onTap: () => setState(() => _feature = spec.id),
                    ),
                ],
              ),
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: SafeArea(child: _buildFeaturePane()),
          ),
        ],
      ),
    );
  }

  Widget _buildNarrow(BuildContext context, List<String> serials) {
    final gridCount = isAtLeastTablet(context) ? 4 : 2;
    return Scaffold(
      appBar: AppBar(
        title: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: _serial,
            isDense: true,
            items: <DropdownMenuItem<String>>[
              for (final s in serials)
                DropdownMenuItem<String>(value: s, child: Text(_shortName(s))),
            ],
            onChanged: (s) {
              if (s != null) setState(() => _serial = s);
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
              FeatureTile(
                spec: spec,
                onTap: () => _openFeature(context, spec),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDisconnected(BuildContext context, List<String> serials) {
    final hasAny = serials.isNotEmpty;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.usb_off, size: 64, color: scheme.outline),
            const SizedBox(height: 16),
            const Text('设备已断开连接'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: hasAny
                  ? () => setState(() => _serial = serials.first)
                  : () => Navigator.of(context).maybePop(),
              child: Text(hasAny ? '切换到其他设备' : '返回连接页'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.manager,
      builder: (context, _) {
        final serials =
            widget.manager.profiles.map((p) => p.serial).toList();
        if (!serials.contains(_serial)) {
          return _buildDisconnected(context, serials);
        }
        if (isWide(context)) {
          return _buildWide(context, serials);
        }
        return _buildNarrow(context, serials);
      },
    );
  }
}