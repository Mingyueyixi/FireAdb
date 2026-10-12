import '../capture/data/capture_paths.dart';

const String kLinuxApplicationId = 'com.fire.adb';
const String kMacosApplicationId = 'com.fire.adb';
const String kLogFolderName = 'logs';

/// 桌面端日志目录。都落在文件管理器能够打开的位置。
///
/// Windows 的应用数据目录按「公司名\产品名」拼接。两边都是 FireAdb 时会变成
/// `Roaming\FireAdb\FireAdb`，这里只保留一层。
/// 安卓目录由系统外部文件目录决定，不在这里拼。
String? logDirectoryPathFor({
  required String operatingSystem,
  required Map<String, String> environment,
  String? separator,
}) {
  switch (operatingSystem) {
    case 'windows':
      final sep = separator ?? r'\';
      final roaming =
          _nonEmpty(environment['APPDATA']) ??
          _child(
            _nonEmpty(environment['USERPROFILE']),
            r'AppData\Roaming',
            sep,
          );
      if (roaming == null) return null;
      return _child(
        _child(roaming, kFireAdbDataFolder, sep),
        kLogFolderName,
        sep,
      );
    case 'macos':
      final home = _nonEmpty(environment['HOME']);
      if (home == null) return null;
      return '$home/Library/Application Support/$kMacosApplicationId/$kLogFolderName';
    case 'linux':
      final home = _nonEmpty(environment['HOME']);
      final dataHome =
          _nonEmpty(environment['XDG_DATA_HOME']) ??
          (home == null ? null : '$home/.local/share');
      if (dataHome == null) return null;
      return '$dataHome/$kLinuxApplicationId/$kLogFolderName';
    default:
      return null;
  }
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  if (trimmed.length > 1 && (trimmed.endsWith('/') || trimmed.endsWith(r'\'))) {
    return trimmed.substring(0, trimmed.length - 1);
  }
  return trimmed;
}

String? _child(String? parent, String name, String separator) {
  if (parent == null) return null;
  return '$parent$separator$name';
}
