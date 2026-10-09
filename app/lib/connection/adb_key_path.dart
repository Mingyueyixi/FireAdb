import 'dart:io';

/// ADB RSA 私钥的保存路径。桌面放在用户配置目录，安卓放在应用私有目录。
///
/// 安卓没有 `HOME` / `USERPROFILE`。[androidDataDir] 取缓存目录的上一级
/// （`/data/user/0/<包名>`），旁边的 `files` 不会随缓存清理被删掉。
String adbKeyFilePath({
  required bool android,
  required Map<String, String> environment,
  required String androidDataDir,
  String? separator,
}) {
  final sep = separator ?? Platform.pathSeparator;
  if (android) {
    return '$androidDataDir${sep}files'
        '$sep$kAdbKeyDirName$sep$kAdbKeyFileName';
  }
  final home = environment['HOME'];
  final profile = environment['USERPROFILE'];
  final root = (home != null && home.isNotEmpty) ? home : profile;
  if (root == null || root.isEmpty) {
    throw const AdbKeyUnavailable('没有可写入的用户目录，无法保存 ADB 密钥');
  }
  return '$root$sep.config$sep$kAdbKeyDirName$sep$kAdbKeyFileName';
}

const String kAdbKeyDirName = 'fire_adb';
const String kAdbKeyFileName = 'adbkey.pem';

class AdbKeyUnavailable implements Exception {
  const AdbKeyUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}
