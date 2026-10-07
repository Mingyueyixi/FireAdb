import 'package:flutter/material.dart';

import '../apps/ui/apps_page.dart';
import '../capture/ui/screenrecord_page.dart';
import '../capture/ui/screenshot_page.dart';
import '../device_overview/device_overview_page.dart';
import '../files/ui/files_page.dart';
import '../shell/shell_page.dart';
import 'data/feature_spec.dart';
import 'feature_tile.dart';

/// 某个设备上的功能内容。宽屏和窄屏共用这一份。
Widget deviceFeatureBody({
  Key? key,
  required String serial,
  required FeatureSpec spec,
}) {
  return switch (spec.id) {
    kOverviewFeatureId => DeviceOverviewPage(key: key, serial: serial),
    'shell' => ShellPage(key: key, serial: serial),
    'apps' => AppsPage(key: key, serial: serial),
    'files' => FilesPage(key: key, serial: serial),
    'screenshot' => ScreenshotPage(key: key, serial: serial),
    'screenrecord' => ScreenrecordPage(key: key, serial: serial),
    _ => PlaceholderFeatureBody(key: key, spec: spec),
  };
}
