import 'dart:ffi';
import 'dart:io';

import 'package:dart_libusb/dart_libusb.dart';
import 'package:ffi/ffi.dart';

import 'adb_usb_device.dart';

/// 打开 libusb。Windows 优先用程序旁边的 `libusb-1.0.dll`。
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
    return _firstExisting(windowsLibusbCandidates(executable), exists) ??
        'libusb-1.0.dll';
  }
  if (Platform.isLinux) return 'libusb-1.0.so.0';
  if (Platform.isMacOS) {
    return _firstExisting(const <String>[
          '/opt/homebrew/lib/libusb-1.0.dylib',
          '/usr/local/lib/libusb-1.0.dylib',
        ], exists) ??
        'libusb-1.0.dylib';
  }
  return null;
}

/// 调试运行时 DLL 还在源码目录，不在 exe 旁边。从 exe 往上找工程里的那一份。
List<String> windowsLibusbCandidates(String executablePath) {
  final separator = Platform.pathSeparator;
  final directory = File(executablePath).parent;
  final candidates = <String>['${directory.path}${separator}libusb-1.0.dll'];
  var current = directory;
  for (var depth = 0; depth < 10; depth++) {
    candidates.add(
      '${current.path}${separator}packages${separator}adb_usb'
      '${separator}vendor${separator}windows${separator}libusb-1.0.dll',
    );
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
