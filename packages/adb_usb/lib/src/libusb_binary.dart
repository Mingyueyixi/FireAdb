/// 各平台 libusb 怎么进应用。构建钩子和测试共用这张表。
///
/// 上游 libusb 1.0.29 只发布 Windows 动态库。Linux、macOS 若把对应文件放进
/// `vendor/<系统>/<架构>/`，钩子会改成随包；现在仓库里没有这些文件，就登记系统库名。
class LibusbBinaryPlan {
  const LibusbBinaryPlan.bundled(this.relativePath) : systemName = null;

  const LibusbBinaryPlan.system(this.systemName) : relativePath = null;

  /// 相对包根，例如 `vendor/windows/x64/libusb-1.0.dll`。
  final String? relativePath;

  /// 交给动态链接器的库名，例如 `libusb-1.0.so.0`。
  final String? systemName;

  String get fileName {
    final path = relativePath;
    if (path != null) {
      final slash = path.lastIndexOf('/');
      return slash < 0 ? path : path.substring(slash + 1);
    }
    return systemName!;
  }
}

/// 代码资源 id 的包内名字。完整 id 是 `package:adb_usb/src/libusb.dart`。
const String libusbCodeAssetName = 'src/libusb.dart';

/// 已经放进仓库、构建时应当拷贝的相对路径。没有这份文件时返回 null。
///
/// Windows x64 是官方压缩包里的 `VS2022/MS64/dll/libusb-1.0.dll`。
/// Windows ARM64 是同一份 `libusb-1.0.29.7z` 里的
/// `MinGW-llvm-aarch64/dll/libusb-1.0.dll`，VS2022 目录没有 ARM64 构建。
String? vendoredLibusbPath(String os, String architecture) {
  return switch ((os, architecture)) {
    ('windows', 'x64') => 'vendor/windows/x64/libusb-1.0.dll',
    ('windows', 'arm64') => 'vendor/windows/arm64/libusb-1.0.dll',
    ('linux', 'x64') => 'vendor/linux/x64/libusb-1.0.so.0',
    ('linux', 'arm64') => 'vendor/linux/arm64/libusb-1.0.so.0',
    ('macos', 'x64') => 'vendor/macos/x64/libusb-1.0.dylib',
    ('macos', 'arm64') => 'vendor/macos/arm64/libusb-1.0.dylib',
    _ => null,
  };
}

/// 系统里 libusb 的库名。Windows 不走系统安装。
String? systemLibusbName(String os) {
  return switch (os) {
    'linux' => 'libusb-1.0.so.0',
    'macos' => 'libusb-1.0.dylib',
    _ => null,
  };
}

/// Windows x64 和 ARM64 必须有随包文件。Linux / macOS 有文件就随包，否则用系统库名。
/// Android 和其他没有 libusb 的目标返回 null。
LibusbBinaryPlan? planLibusbBinary(
  String os,
  String architecture, {
  required bool Function(String relativePath) bundledExists,
}) {
  final vendored = vendoredLibusbPath(os, architecture);
  if (vendored != null && bundledExists(vendored)) {
    return LibusbBinaryPlan.bundled(vendored);
  }
  if (os == 'windows' && (architecture == 'x64' || architecture == 'arm64')) {
    throw StateError('缺少 Windows $architecture libusb：$vendored');
  }
  final system = systemLibusbName(os);
  if (system == null) return null;
  return LibusbBinaryPlan.system(system);
}
