import 'package:flutter/material.dart';

import '../../widgets/system_navigation_padding.dart';
import '../files/file_backend.dart';
import '../files/local_file_backend.dart';
import '../files/ui/files_page.dart';

/// 浏览本机日志目录。和「应用数据目录」同一套交互：文件管理的完整操作
/// （多选、重命名、权限、编辑、删除）都可用，但不能离开这个目录，
/// 也不提供路径输入。设备文件后端特有的上传/导出按能力自动隐藏。
class LogDirectoryPage extends StatelessWidget {
  const LogDirectoryPage({
    super.key,
    required this.title,
    required this.directory,
  });

  final String title;
  final String directory;

  @override
  Widget build(BuildContext context) {
    final FileBackend backend = LocalFileBackend(directory);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SystemNavigationPadding(
        child: FileBrowser(
          serial: '',
          backend: backend,
          root: directory,
          showPathField: false,
          showLocations: false,
          showSuMode: false,
        ),
      ),
    );
  }
}
