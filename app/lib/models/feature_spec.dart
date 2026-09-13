import 'package:flutter/material.dart';

/// 设备页的某个功能入口（总览已实现，其余为规划中的占位）。
class FeatureSpec {
  const FeatureSpec({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    this.implemented = false,
  });

  final String id;
  final String title;
  final String description;
  final IconData icon;
  final bool implemented;
}

const String kOverviewFeatureId = 'overview';

const List<FeatureSpec> kDeviceFeatures = <FeatureSpec>[
  FeatureSpec(
    id: kOverviewFeatureId,
    title: '设备总览',
    description: '设备型号、品牌、系统版本等基本信息',
    icon: Icons.phonelink_ring,
    implemented: true,
  ),
  FeatureSpec(
    id: 'apps',
    title: '设备应用',
    description: '查看已安装应用、卸载应用、安装 APK',
    icon: Icons.apps,
  ),
  FeatureSpec(
    id: 'transfer',
    title: '文件传输',
    description: '推送文件到设备 / 从设备拉取文件',
    icon: Icons.swap_horiz,
  ),
  FeatureSpec(
    id: 'files',
    title: '文件管理',
    description: '浏览设备存储，下载、删除、分享文件',
    icon: Icons.folder_open,
  ),
  FeatureSpec(
    id: 'screenshot',
    title: '截图',
    description: '调用 screencap -p 截取屏幕并保存 PNG',
    icon: Icons.screenshot_monitor,
  ),
  FeatureSpec(
    id: 'screenrecord',
    title: '录屏',
    description: '调用 screenrecord 录制设备屏幕',
    icon: Icons.videocam,
  ),
  FeatureSpec(
    id: 'shell',
    title: '命令面板',
    description: '执行 adb shell 命令并查看输出',
    icon: Icons.terminal,
  ),
];