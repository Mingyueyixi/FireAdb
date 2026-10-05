import 'dart:async';

import 'package:fire_adb/connection/connection_manager.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

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

  static const Map<String, String> _fieldLabels = <String, String>{
    'ro.product.model': '设备型号',
    'ro.product.manufacturer': '制造商',
    'ro.product.brand': '品牌',
    'ro.build.version.release': 'Android 版本',
    'ro.build.version.sdk': 'API 级别',
    'ro.product.cpu.abi': 'ABI',
  };

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
      setState(() => _error = '设备未连接');
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
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                  ? '网络连接 · ${profile.host}:${profile.port}'
                  : '已连接',
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '读取设备信息失败：$_error',
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
                  title: Text('基本信息', style: theme.textTheme.titleMedium),
                ),
                const Divider(height: 1),
                for (final entry in _fieldLabels.entries)
                  _InfoRow(label: entry.value, value: _props[entry.key]),
              ],
            ),
          ),
      ],
    );
  }
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