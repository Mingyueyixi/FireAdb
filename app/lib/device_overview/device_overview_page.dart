import 'dart:async';

import 'package:fire_adb/connection/connection_manager.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../l10n/fire_adb_localizations_ext.dart';
import '../log/app_log.dart';

/// 设备基本信息面板（连接后按需读取 getprop）。
class DeviceOverviewPage extends StatefulWidget {
  const DeviceOverviewPage({
    super.key,
    required this.serial,
  });

  final String serial;

  @override
  State<DeviceOverviewPage> createState() => _DeviceOverviewPageState();
}

class _DeviceOverviewPageState extends State<DeviceOverviewPage> {
  ConnectionManager get _manager => Get.find<ConnectionManager>();

  static String _fieldLabel(BuildContext context, String key) {
    final l10n = context.l10n;
    return switch (key) {
      'ro.product.model' => l10n.deviceOverviewModel,
      'ro.product.manufacturer' => l10n.deviceOverviewManufacturer,
      'ro.product.brand' => l10n.deviceOverviewBrand,
      'ro.build.version.release' => l10n.deviceOverviewAndroidVersion,
      'ro.build.version.sdk' => l10n.deviceOverviewApiLevel,
      'ro.product.cpu.abi' => 'ABI',
      _ => key,
    };
  }

  Map<String, String> _props = const <String, String>{};
  Object? _error;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final device = _manager.deviceOf(widget.serial);
    if (device == null) {
      setState(() => _error = const _DeviceNotConnectedException());
      return;
    }
    try {
      final props = await device.getProperties().timeout(
        const Duration(seconds: 10),
      );
      if (!mounted) return;
      setState(() {
        _props = props;
        _loaded = true;
      });
    } catch (error, stackTrace) {
      log.severe('读取设备信息失败：${widget.serial}', error, stackTrace);
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final profile = _manager.profileOf(widget.serial);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Card(
          child: ListTile(
            leading: Icon(Icons.phonelink, color: theme.colorScheme.primary),
            title: Text(widget.serial, style: theme.textTheme.titleMedium),
            subtitle: Text(
              profile != null && profile.host != null
                  ? l10n.deviceOverviewNetworkConnection(profile.host!, profile.port!)
                  : l10n.deviceOverviewConnected,
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              l10n.deviceOverviewInfoReadFailed(
                _error is _DeviceNotConnectedException
                    ? l10n.deviceOverviewNotConnected
                    : '$_error',
              ),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          )
        else if (!_loaded)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          Card(
            child: Column(
              children: <Widget>[
                ListTile(
                  title: Text(l10n.deviceOverviewBasicInformation, style: theme.textTheme.titleMedium),
                ),
                const Divider(height: 1),
                for (final key in const <String>[
                  'ro.product.model',
                  'ro.product.manufacturer',
                  'ro.product.brand',
                  'ro.build.version.release',
                  'ro.build.version.sdk',
                  'ro.product.cpu.abi',
                ])
                  _InfoRow(
                    label: _fieldLabel(context, key),
                    value: _props[key],
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _DeviceNotConnectedException implements Exception {
  const _DeviceNotConnectedException();
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      title: Text(label),
      trailing: Text(
        value ?? '-',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }
}