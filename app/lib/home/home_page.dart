import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../l10n/fire_adb_localizations_ext.dart';
import '../widgets/adaptive.dart';
import 'ui/device_list_section.dart';
import 'ui/discovery_section.dart';
import 'ui/history_section.dart';
import 'ui/manual_connect_section.dart';

/// 连接中心：设备列表 / 手动连接 / mDNS 设备发现 / 历史连接。
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FireAdb'),
        actions: <Widget>[
          IconButton(
            tooltip: context.l10n.settingsTitle,
            onPressed: () => Get.toNamed<void>('/settings'),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: const _HomeLayout(),
          ),
        ),
      ),
    );
  }
}

class _HomeLayout extends StatelessWidget {
  const _HomeLayout();

  @override
  Widget build(BuildContext context) {
    const devices = DeviceListSection();
    const manual = ManualConnectSection();
    const discovery = DiscoverySection();
    const history = HistorySection();
    if (isWide(context)) {
      return const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              children: <Widget>[manual, SizedBox(height: 16), discovery],
            ),
          ),
          SizedBox(width: 16),
          Expanded(
            child: Column(
              children: <Widget>[devices, SizedBox(height: 16), history],
            ),
          ),
        ],
      );
    }
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        devices,
        SizedBox(height: 16),
        manual,
        SizedBox(height: 16),
        discovery,
        SizedBox(height: 16),
        history,
      ],
    );
  }
}
