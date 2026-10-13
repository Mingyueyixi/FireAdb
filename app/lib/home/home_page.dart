import 'package:flutter/material.dart';

import '../widgets/adaptive.dart';
import 'ui/device_list_section.dart';
import 'ui/discovery_section.dart';
import 'ui/history_section.dart';
import 'ui/manual_connect_section.dart';

/// 连接页：设备列表 / 手动连接 / mDNS 设备发现 / 历史连接。
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: const _HomeLayout(),
        ),
      ),
    );
  }
}

class _HomeLayout extends StatelessWidget {
  const _HomeLayout();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return _sectionLayout(constraints.maxWidth >= kDesktopBreakpoint);
      },
    );
  }

  Widget _sectionLayout(bool wide) {
    const devices = DeviceListSection();
    const manual = ManualConnectSection();
    const discovery = DiscoverySection();
    const history = HistorySection();
    if (wide) {
      return const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              children: <Widget>[manual, SizedBox(height: 10), discovery],
            ),
          ),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              children: <Widget>[devices, SizedBox(height: 10), history],
            ),
          ),
        ],
      );
    }
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        devices,
        SizedBox(height: 10),
        manual,
        SizedBox(height: 10),
        discovery,
        SizedBox(height: 10),
        history,
      ],
    );
  }
}
