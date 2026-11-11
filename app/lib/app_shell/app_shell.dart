import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../about/about_page.dart';
import '../chat/chat_controller.dart';
import '../chat/ui/chat_page.dart';
import '../home/home_page.dart';
import '../l10n/fireadb_localizations_ext.dart';
import '../log/log_page.dart';
import '../widgets/adaptive.dart';

/// 应用外壳：连接、聊天、日志、关于。
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  var _index = 0;

  /// 已访问过的 tab 下标：惰性挂载用。首次访问才真正构建页面，
  /// 之后常驻（IndexedStack 切换只改可见索引），滚动位置、已加载
  /// 数据、页面状态都保留，无闪动。未访问过的页面不参与初始化。
  final Set<int> _visited = <int>{0};

  /// 连接页是否为当前 tab。页面常驻后，首页的自动刷新启停
  /// 需要这个信号（路由/dispose 不再随 tab 切换变化）。
  final ValueNotifier<bool> _homeVisible = ValueNotifier<bool>(true);

  void _select(int index) {
    setState(() {
      _index = index;
      _visited.add(index);
      _homeVisible.value = index == 0;
    });
    if (index == 1 && Get.isRegistered<ChatController>()) {
      Get.find<ChatController>().refreshMembers();
    }
  }

  /// 四个槽位始终对齐 tab 下标；未访问的槽位用空占位。
  List<Widget> _stackChildren() => <Widget>[
    if (_visited.contains(0))
      HomePage(tabVisible: _homeVisible)
    else
      const SizedBox.shrink(),
    if (_visited.contains(1)) const ChatPage() else const SizedBox.shrink(),
    if (_visited.contains(2)) const LogPage() else const SizedBox.shrink(),
    if (_visited.contains(3)) const AboutPage() else const SizedBox.shrink(),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final destinations = <_Destination>[
      _Destination(l10n.navConnection, Icons.link_outlined, Icons.link),
      _Destination(l10n.navGroup, Icons.forum_outlined, Icons.forum),
      _Destination(l10n.navLogs, Icons.article_outlined, Icons.article),
      _Destination(l10n.navAbout, Icons.info_outline, Icons.info),
    ];
    final wide = isWide(context);
    final settingsButton = IconButton(
      tooltip: l10n.settingsTitle,
      onPressed: () => Get.toNamed<void>('/settings'),
      icon: const Icon(Icons.settings_outlined),
    );
    return Scaffold(
      // 窄屏底栏已经标出当前页。日志页自带标题栏，这里不再叠一条。
      appBar: wide || _index == 2
          ? null
          : AppBar(
              forceMaterialTransparency: true,
              elevation: 0,
              scrolledUnderElevation: 0,
              automaticallyImplyLeading: false,
              actions: <Widget>[settingsButton],
            ),
      body: wide
          ? SafeArea(
              bottom: false,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  NavigationRail(
                    selectedIndex: _index,
                    onDestinationSelected: _select,
                    labelType: NavigationRailLabelType.all,
                    scrollable: true,
                    trailingAtBottom: true,
                    leading: Padding(
                      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                      child: Text(
                        'FireAdb',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    trailing: Expanded(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: settingsButton,
                        ),
                      ),
                    ),
                    destinations: <NavigationRailDestination>[
                      for (final destination in destinations)
                        NavigationRailDestination(
                          icon: Icon(destination.icon),
                          selectedIcon: Icon(destination.selectedIcon),
                          label: Text(destination.label),
                        ),
                    ],
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: IndexedStack(
                      index: _index,
                      children: _stackChildren(),
                    ),
                  ),
                ],
              ),
            )
          : IndexedStack(index: _index, children: _stackChildren()),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: _select,
              destinations: <NavigationDestination>[
                for (final destination in destinations)
                  NavigationDestination(
                    icon: Icon(destination.icon),
                    selectedIcon: Icon(destination.selectedIcon),
                    label: destination.label,
                  ),
              ],
            ),
    );
  }
}

class _Destination {
  const _Destination(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}
