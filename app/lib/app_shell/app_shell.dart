import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../about/about_page.dart';
import '../home/home_page.dart';
import '../l10n/fire_adb_localizations_ext.dart';
import '../log/log_page.dart';
import '../widgets/adaptive.dart';

/// 应用外壳：连接、日志、关于。
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  var _index = 0;

  void _select(int index) => setState(() => _index = index);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final destinations = <_Destination>[
      _Destination(l10n.navConnection, Icons.link_outlined, Icons.link),
      _Destination(l10n.navLogs, Icons.article_outlined, Icons.article),
      _Destination(l10n.navAbout, Icons.info_outline, Icons.info),
    ];
    final page = switch (_index) {
      0 => const HomePage(),
      1 => const LogPage(),
      _ => const AboutPage(),
    };
    final wide = isWide(context);
    final settingsButton = IconButton(
      tooltip: l10n.settingsTitle,
      onPressed: () => Get.toNamed<void>('/settings'),
      icon: const Icon(Icons.settings_outlined),
    );
    return Scaffold(
      // 窄屏底栏已经标出当前页。日志页自带标题栏，这里不再叠一条。
      appBar: wide || _index == 1
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
                  Expanded(child: page),
                ],
              ),
            )
          : page,
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
