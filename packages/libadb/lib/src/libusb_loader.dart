import 'dart:ffi';
import 'dart:io';

import 'package:dart_libusb/dart_libusb.dart';
import 'package:ffi/ffi.dart';

import 'adb_usb_device.dart';
import 'libusb_binary.dart';

/// 打开 libusb。
///
/// 构建钩子把 Windows 的 `libusb-1.0.dll` 放到可执行文件旁边，文件名保持不变，
/// 所以按这个名字打开即可。Linux / macOS 用系统库名。
Libusb loadLibusb() {
  final path = resolveLibusbLibraryPath();
  if (path == null) {
    throw AdbUsbException('当前平台没有可用的 libusb。');
  }
  try {
    return Libusb(DynamicLibrary.open(path));
  } on ArgumentError catch (error) {
    throw AdbUsbException('无法加载 libusb（$path）：$error');
  }
}

String? resolveLibusbLibraryPath({
  String? executablePath,
  bool Function(String path)? fileExists,
}) {
  final override = Platform.environment['FIRE_ADB_LIBUSB'];
  if (override != null && override.isNotEmpty) return override;
  final exists = fileExists ?? ((String path) => File(path).existsSync());
  final executable = executablePath ?? Platform.resolvedExecutable;
  if (Platform.isWindows) {
    return _firstExisting(
          windowsLibusbCandidates(
            executable,
            architecture: windowsProcessArchitecture(),
          ),
          exists,
        ) ??
        'libusb-1.0.dll';
  }
  if (Platform.isLinux) {
    final name = systemLibusbName('linux')!;
    final separator = Platform.pathSeparator;
    final directory = File(executable).parent.path;
    return _firstExisting(<String>['$directory$separator$name'], exists) ??
        name;
  }
  if (Platform.isMacOS) {
    final name = systemLibusbName('macos')!;
    return _firstExisting(const <String>[
          '/opt/homebrew/lib/libusb-1.0.dylib',
          '/usr/local/lib/libusb-1.0.dylib',
        ], exists) ??
        name;
  }
  return null;
}

/// 当前进程能加载的 Windows 架构。x64 模拟进程在 ARM 电脑上仍返回 `x64`。
String windowsProcessArchitecture() {
  if (Abi.current() == Abi.windowsArm64) return 'arm64';
  return 'x64';
}

/// 调试运行时 DLL 还在源码目录，不在 exe 旁边。从 exe 往上找工程里的那一份。
List<String> windowsLibusbCandidates(
  String executablePath, {
  String architecture = 'x64',
}) {
  final separator = Platform.pathSeparator;
  final directory = File(executablePath).parent;
  final candidates = <String>['${directory.path}${separator}libusb-1.0.dll'];
  final vendored = vendoredLibusbPath('windows', architecture);
  final suffix = vendored?.replaceAll('/', separator);
  var current = directory;
  for (var depth = 0; depth < 10; depth++) {
    if (suffix != null) {
      candidates.add(
        '${current.path}${separator}packages${separator}libadb'
        '$separator$suffix',
      );
    }
    final parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  return candidates;
}

String? _firstExisting(
  List<String> candidates,
  bool Function(String path) exists,
) {
  for (final candidate in candidates) {
    if (exists(candidate)) return candidate;
  }
  return null;
}

String libusbErrorText(Libusb libusb, int code) {
  final name = libusb.libusb_error_name(code);
  if (name == nullptr) return 'libusb $code';
  return name.cast<Utf8>().toDartString();
}
