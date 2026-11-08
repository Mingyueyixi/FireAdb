import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../widgets/adaptive.dart';
import 'home_controller.dart';
import 'ui/device_list_section.dart';
import 'ui/discovery_section.dart';
import 'ui/history_section.dart';
import 'ui/manual_connect_section.dart';

/// 连接页：设备列表（含可连接的无线服务）/ 手动连接 / 配对发现 / 历史连接。
///
/// [tabVisible]：外壳（tab 容器）提供的“本页是否为当前 tab”。页面常驻
/// IndexedStack 后不再随切换销毁，仅靠路由/dispose 无法感知 tab 切换，
/// 自动刷新的启停需要这个信号。
class HomePage extends StatelessWidget {
  const HomePage({super.key, this.tabVisible});

  final ValueListenable<bool>? tabVisible;

  @override
  Widget build(BuildContext context) {
    return _ConnectionPagePresence(
      tabVisible: tabVisible,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
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

class _ConnectionPagePresence extends StatefulWidget {
  const _ConnectionPagePresence({required this.child, this.tabVisible});

  final Widget child;
  final ValueListenable<bool>? tabVisible;

  @override
  State<_ConnectionPagePresence> createState() =>
      _ConnectionPagePresenceState();
}

class _ConnectionPagePresenceState extends State<_ConnectionPagePresence> {
  static var _nextOwner = 0;
  late final int _owner = ++_nextOwner;
  var _routeCurrent = true;

  ValueListenable<bool>? get _tabVisible => widget.tabVisible;

  @override
  void initState() {
    super.initState();
    _tabVisible?.addListener(_handleTabChange);
  }

  @override
  void didUpdateWidget(_ConnectionPagePresence oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tabVisible != widget.tabVisible) {
      oldWidget.tabVisible?.removeListener(_handleTabChange);
      _tabVisible?.addListener(_handleTabChange);
      _handleTabChange();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeCurrent = ModalRoute.of(context)?.isCurrent ?? false;
    _report(_routeCurrent && (_tabVisible?.value ?? true));
  }

  @override
  void dispose() {
    _tabVisible?.removeListener(_handleTabChange);
    _report(false);
    super.dispose();
  }

  void _handleTabChange() {
    if (!mounted) return;
    _report(_routeCurrent && (_tabVisible?.value ?? true));
  }

  void _report(bool visible) {
    if (!Get.isRegistered<HomeController>()) return;
    Get.find<HomeController>().setConnectionPageVisible(visible, owner: _owner);
  }

  @override
  Widget build(BuildContext context) => widget.child;
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
