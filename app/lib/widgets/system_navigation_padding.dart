import 'package:flutter/widgets.dart';

/// 把内容抬到系统导航栏上面。
///
/// 主页底部栏会自己留出这块高度。没有底部栏的页面要单独补上，
/// 否则虚拟导航栏会挡住最下面的内容。状态栏仍由 AppBar 处理。
class SystemNavigationPadding extends StatelessWidget {
  const SystemNavigationPadding({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SafeArea(top: false, left: false, right: false, child: child);
  }
}
