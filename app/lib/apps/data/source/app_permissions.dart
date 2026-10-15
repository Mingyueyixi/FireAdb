import 'dart:convert';

/// 应用清单里的一项权限，以及当前是否已授予。
class AppPermissionEntry {
  const AppPermissionEntry({
    required this.name,
    required this.granted,
    required this.changeable,
  });

  final String name;
  final bool granted;

  /// 运行时权限可以用 `pm grant` / `pm revoke` 修改。
  final bool changeable;

  AppPermissionEntry copyWith({bool? granted}) {
    return AppPermissionEntry(
      name: name,
      granted: granted ?? this.granted,
      changeable: changeable,
    );
  }
}

final _permissionName = RegExp(r'^[A-Za-z_][\w.]*$');

bool isAppPermissionName(String name) => _permissionName.hasMatch(name);
final _grantedLine = RegExp(r'^([A-Za-z_][\w.]*)\s*:\s*granted=(true|false)\b');

enum _PermissionSection { none, requested, install, runtime }

/// 解析 `dumpsys package <包名>` 里的权限段。
List<AppPermissionEntry> parsePackagePermissions(String output) {
  var section = _PermissionSection.none;
  String? pendingName;
  final requested = <String>{};
  final install = <String, bool>{};
  final runtime = <String, bool>{};

  void takeGranted(String name, bool granted) {
    if (section == _PermissionSection.install) {
      install[name] = granted;
    } else if (section == _PermissionSection.runtime) {
      runtime[name] = granted;
    }
  }

  for (final raw in const LineSplitter().convert(output)) {
    final line = raw.trim();
    if (line.isEmpty) {
      pendingName = null;
      continue;
    }
    if (line == 'requested permissions:') {
      section = _PermissionSection.requested;
      pendingName = null;
      continue;
    }
    if (line == 'install permissions:') {
      section = _PermissionSection.install;
      pendingName = null;
      continue;
    }
    if (line == 'runtime permissions:') {
      section = _PermissionSection.runtime;
      pendingName = null;
      continue;
    }
    if (section == _PermissionSection.none) continue;

    if (pendingName != null && line.startsWith('granted=')) {
      takeGranted(pendingName, line.startsWith('granted=true'));
      pendingName = null;
      continue;
    }
    if (line.startsWith('flags=') || line.startsWith('gids=')) continue;

    final granted = _grantedLine.firstMatch(line);
    if (granted != null && section != _PermissionSection.requested) {
      takeGranted(granted.group(1)!, granted.group(2) == 'true');
      pendingName = null;
      continue;
    }

    if (line.endsWith(':') && section != _PermissionSection.requested) {
      final name = line.substring(0, line.length - 1).trim();
      if (_permissionName.hasMatch(name)) {
        pendingName = name;
        continue;
      }
    }

    if (section == _PermissionSection.requested &&
        _permissionName.hasMatch(line)) {
      requested.add(line);
      continue;
    }

    section = _PermissionSection.none;
    pendingName = null;
  }

  final names = <String>{...requested, ...install.keys, ...runtime.keys};
  final entries =
      <AppPermissionEntry>[
        for (final name in names)
          AppPermissionEntry(
            name: name,
            granted: runtime[name] ?? install[name] ?? false,
            changeable: runtime.containsKey(name),
          ),
      ]..sort((a, b) {
        if (a.changeable != b.changeable) return a.changeable ? -1 : 1;
        return a.name.compareTo(b.name);
      });
  return entries;
}

/// 这些权限不是 `pm grant` 能改的运行时权限，要用 `appops`。
const appOpsByPermission = <String, String>{
  'android.permission.SYSTEM_ALERT_WINDOW': 'SYSTEM_ALERT_WINDOW',
  'android.permission.WRITE_SETTINGS': 'WRITE_SETTINGS',
  'android.permission.REQUEST_INSTALL_PACKAGES': 'REQUEST_INSTALL_PACKAGES',
  'android.permission.PACKAGE_USAGE_STATS': 'GET_USAGE_STATS',
  'android.permission.MANAGE_EXTERNAL_STORAGE': 'MANAGE_EXTERNAL_STORAGE',
};

String? appOpForPermission(String permission) => appOpsByPermission[permission];

final _appOpMode = RegExp(
  r'\b([A-Z][A-Z0-9_]*):\s*(allow|ignore|deny|default|foreground)\b',
);

/// 解析 `appops get <包名>`。同一个操作出现多次时，后面的记录覆盖前面的。
Map<String, String> parseAppOps(String output) {
  final modes = <String, String>{};
  for (final match in _appOpMode.allMatches(output)) {
    modes[match.group(1)!] = match.group(2)!;
  }
  return modes;
}

/// 把特殊权限标成可修改，并用 appops 的 allow 作为是否授予。
List<AppPermissionEntry> applyAppOps(
  List<AppPermissionEntry> entries,
  Map<String, String> modes,
) {
  final merged =
      <AppPermissionEntry>[
        for (final entry in entries)
          if (appOpForPermission(entry.name) case final op?)
            AppPermissionEntry(
              name: entry.name,
              granted: modes.containsKey(op)
                  ? modes[op] == 'allow'
                  : entry.granted,
              changeable: true,
            )
          else
            entry,
      ]..sort((a, b) {
        if (a.changeable != b.changeable) return a.changeable ? -1 : 1;
        return a.name.compareTo(b.name);
      });
  return merged;
}

/// 从 `pm` 失败输出里取出异常原文，去掉后面的调用堆栈。
String permissionCommandError(String output) {
  for (final raw in const LineSplitter().convert(output)) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('at ')) continue;
    if (line.startsWith('Exception occurred while executing')) continue;
    if (line.startsWith('Caused by:')) {
      final rest = line.substring('Caused by:'.length).trim();
      if (rest.isNotEmpty) return rest;
      continue;
    }
    return line;
  }
  return output.trim();
}

/// 厂商拿走了 shell 的运行时授权能力。命令仍是 `pm grant` / `pm revoke`。
bool shellBlockedRuntimeGrant(String output) {
  return output.contains('GRANT_RUNTIME_PERMISSIONS') ||
      output.contains('REVOKE_RUNTIME_PERMISSIONS');
}

/// `pm grant` / `pm revoke` 成功时经常没有输出。
void ensurePermissionCommand(String output) {
  final trimmed = output.trim();
  if (trimmed.isEmpty) return;
  if (RegExp(r'^Success\b', caseSensitive: false).hasMatch(trimmed)) return;
  final failed =
      trimmed.contains('Exception') ||
      trimmed.contains('Error:') ||
      trimmed.startsWith('Error ') ||
      trimmed.contains('Unknown operation') ||
      trimmed.contains('No such');
  if (!failed) return;
  throw StateError(permissionCommandError(trimmed));
}

/// 常见权限的短名称。没有对应文案时用权限名最后一段。
String permissionTitle(String name, {required bool chinese}) {
  final short = name.split('.').last;
  final known = chinese ? _permissionTitlesZh : _permissionTitlesEn;
  return known[short] ?? short;
}

const _permissionTitlesZh = <String, String>{
  'CAMERA': '相机',
  'RECORD_AUDIO': '麦克风',
  'ACCESS_FINE_LOCATION': '精确位置',
  'ACCESS_COARSE_LOCATION': '大致位置',
  'ACCESS_BACKGROUND_LOCATION': '后台位置',
  'READ_CONTACTS': '读取通讯录',
  'WRITE_CONTACTS': '修改通讯录',
  'READ_CALENDAR': '读取日历',
  'WRITE_CALENDAR': '修改日历',
  'READ_CALL_LOG': '读取通话记录',
  'WRITE_CALL_LOG': '修改通话记录',
  'READ_PHONE_STATE': '读取电话状态',
  'CALL_PHONE': '拨打电话',
  'READ_SMS': '读取短信',
  'SEND_SMS': '发送短信',
  'RECEIVE_SMS': '接收短信',
  'READ_EXTERNAL_STORAGE': '读取存储',
  'WRITE_EXTERNAL_STORAGE': '修改存储',
  'READ_MEDIA_IMAGES': '读取图片',
  'READ_MEDIA_VIDEO': '读取视频',
  'READ_MEDIA_AUDIO': '读取音频',
  'MANAGE_EXTERNAL_STORAGE': '所有文件访问',
  'POST_NOTIFICATIONS': '通知',
  'BODY_SENSORS': '身体传感器',
  'ACTIVITY_RECOGNITION': '身体活动',
  'BLUETOOTH_CONNECT': '蓝牙连接',
  'BLUETOOTH_SCAN': '蓝牙扫描',
  'BLUETOOTH_ADVERTISE': '蓝牙广播',
  'NEARBY_WIFI_DEVICES': '附近的 Wi-Fi 设备',
  'SYSTEM_ALERT_WINDOW': '悬浮窗',
  'WRITE_SETTINGS': '修改系统设置',
  'REQUEST_INSTALL_PACKAGES': '安装应用',
  'PACKAGE_USAGE_STATS': '使用情况访问',
  'INTERNET': '网络',
  'ACCESS_NETWORK_STATE': '查看网络状态',
  'ACCESS_WIFI_STATE': '查看 Wi-Fi 状态',
  'WAKE_LOCK': '防止休眠',
  'RECEIVE_BOOT_COMPLETED': '开机启动',
  'FOREGROUND_SERVICE': '前台服务',
};

const _permissionTitlesEn = <String, String>{
  'CAMERA': 'Camera',
  'RECORD_AUDIO': 'Microphone',
  'ACCESS_FINE_LOCATION': 'Precise location',
  'ACCESS_COARSE_LOCATION': 'Approximate location',
  'ACCESS_BACKGROUND_LOCATION': 'Background location',
  'READ_CONTACTS': 'Read contacts',
  'WRITE_CONTACTS': 'Modify contacts',
  'READ_CALENDAR': 'Read calendar',
  'WRITE_CALENDAR': 'Modify calendar',
  'READ_CALL_LOG': 'Read call log',
  'WRITE_CALL_LOG': 'Modify call log',
  'READ_PHONE_STATE': 'Read phone state',
  'CALL_PHONE': 'Phone calls',
  'READ_SMS': 'Read SMS',
  'SEND_SMS': 'Send SMS',
  'RECEIVE_SMS': 'Receive SMS',
  'READ_EXTERNAL_STORAGE': 'Read storage',
  'WRITE_EXTERNAL_STORAGE': 'Modify storage',
  'READ_MEDIA_IMAGES': 'Read images',
  'READ_MEDIA_VIDEO': 'Read videos',
  'READ_MEDIA_AUDIO': 'Read audio',
  'MANAGE_EXTERNAL_STORAGE': 'All files access',
  'POST_NOTIFICATIONS': 'Notifications',
  'BODY_SENSORS': 'Body sensors',
  'ACTIVITY_RECOGNITION': 'Physical activity',
  'BLUETOOTH_CONNECT': 'Bluetooth connect',
  'BLUETOOTH_SCAN': 'Bluetooth scan',
  'BLUETOOTH_ADVERTISE': 'Bluetooth advertise',
  'NEARBY_WIFI_DEVICES': 'Nearby Wi-Fi devices',
  'SYSTEM_ALERT_WINDOW': 'Display over other apps',
  'WRITE_SETTINGS': 'Modify system settings',
  'REQUEST_INSTALL_PACKAGES': 'Install apps',
  'PACKAGE_USAGE_STATS': 'Usage access',
  'INTERNET': 'Internet',
  'ACCESS_NETWORK_STATE': 'View network state',
  'ACCESS_WIFI_STATE': 'View Wi-Fi state',
  'WAKE_LOCK': 'Keep awake',
  'RECEIVE_BOOT_COMPLETED': 'Run at startup',
  'FOREGROUND_SERVICE': 'Foreground service',
};
