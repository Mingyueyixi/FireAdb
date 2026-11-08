import 'package:flutter/material.dart';

import '../../files/ui/files_page.dart';
import '../../widgets/system_navigation_padding.dart';

/// 浏览和修改应用数据目录。操作和文件管理相同，只是不能离开这个目录，也不提供路径输入。
class AppDataPage extends StatelessWidget {
  const AppDataPage({
    super.key,
    required this.serial,
    required this.packageName,
    required this.root,
    required this.title,
  });

  final String serial;
  final String packageName;
  final String root;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SystemNavigationPadding(
        child: FileBrowser(
          serial: serial,
          root: root,
          showPathField: false,
          showLocations: false,
          showSuMode: false,
        ),
      ),
    );
  }
}
