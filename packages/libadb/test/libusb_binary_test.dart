import 'dart:io';
import 'dart:typed_data';

import 'package:libadb/src/libusb_binary.dart';
import 'package:test/test.dart';

void main() {
  test('Windows x64 随包，缺文件则失败', () {
    final plan = planLibusbBinary('windows', 'x64', bundledExists: (_) => true);
    expect(plan!.relativePath, 'vendor/windows/x64/libusb-1.0.dll');
    expect(plan.fileName, 'libusb-1.0.dll');
    expect(
      () => planLibusbBinary('windows', 'x64', bundledExists: (_) => false),
      throwsStateError,
    );
  });

  test('Linux 和 macOS 没有随包文件时登记系统库名', () {
    final linux = planLibusbBinary('linux', 'x64', bundledExists: (_) => false);
    expect(linux!.systemName, 'libusb-1.0.so.0');
    expect(linux.relativePath, isNull);

    final macos = planLibusbBinary(
      'macos',
      'arm64',
      bundledExists: (_) => false,
    );
    expect(macos!.systemName, 'libusb-1.0.dylib');
  });

  test('Linux 和 macOS 放进 vendor 后改为随包', () {
    final plan = planLibusbBinary(
      'linux',
      'arm64',
      bundledExists: (path) => path == 'vendor/linux/arm64/libusb-1.0.so.0',
    );
    expect(plan!.relativePath, 'vendor/linux/arm64/libusb-1.0.so.0');
    expect(plan.fileName, 'libusb-1.0.so.0');
  });

  test('Windows ARM64 随包，缺文件则失败', () {
    final plan = planLibusbBinary(
      'windows',
      'arm64',
      bundledExists: (_) => true,
    );
    expect(plan!.relativePath, 'vendor/windows/arm64/libusb-1.0.dll');
    expect(plan.fileName, 'libusb-1.0.dll');
    expect(
      () => planLibusbBinary('windows', 'arm64', bundledExists: (_) => false),
      throwsStateError,
    );
  });

  test('Android 不登记 libusb', () {
    expect(
      planLibusbBinary('android', 'arm64', bundledExists: (_) => false),
      isNull,
    );
  });

  test('仓库里的 Windows DLL 架构与文件名一致', () {
    final root = Directory('packages/libadb').existsSync()
        ? 'packages/libadb'
        : '.';
    expect(_peMachine('$root/vendor/windows/x64/libusb-1.0.dll'), 0x8664);
    expect(_peMachine('$root/vendor/windows/arm64/libusb-1.0.dll'), 0xAA64);
  });
}

int _peMachine(String path) {
  final bytes = File(path).readAsBytesSync();
  final data = ByteData.sublistView(bytes);
  final pe = data.getUint32(0x3C, Endian.little);
  return data.getUint16(pe + 4, Endian.little);
}
