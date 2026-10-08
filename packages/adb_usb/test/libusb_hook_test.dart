import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:test/test.dart';

import '../hook/build.dart' as libusb_hook;

void main() {
  Future<void> inPackage(Future<void> Function() body) async {
    final previous = Directory.current;
    final package = Directory('packages/adb_usb');
    if (package.existsSync()) Directory.current = package.absolute;
    try {
      await body();
    } finally {
      Directory.current = previous;
    }
  }

  test('Windows x64 钩子拷贝 DLL', () async {
    await inPackage(() async {
      await testCodeBuildHook(
        mainMethod: libusb_hook.main,
        targetOS: OS.windows,
        targetArchitecture: Architecture.x64,
        check: (input, output) {
          final asset = output.assets.code.single;
          expect(asset.id, 'package:adb_usb/src/libusb.dart');
          expect(asset.linkMode, isA<DynamicLoadingBundled>());
          expect(asset.file!.pathSegments.last, 'libusb-1.0.dll');
          expect(File.fromUri(asset.file!).existsSync(), isTrue);
        },
      );
    });
  });

  test('Windows ARM64 钩子拷贝 ARM64 DLL', () async {
    await inPackage(() async {
      await testCodeBuildHook(
        mainMethod: libusb_hook.main,
        targetOS: OS.windows,
        targetArchitecture: Architecture.arm64,
        check: (input, output) {
          final asset = output.assets.code.single;
          expect(asset.linkMode, isA<DynamicLoadingBundled>());
          final copied = File.fromUri(asset.file!);
          final vendored = File('vendor/windows/arm64/libusb-1.0.dll');
          expect(copied.lengthSync(), vendored.lengthSync());
        },
      );
    });
  });

  test('Linux 和 macOS 钩子登记系统库名', () async {
    await inPackage(() async {
      await testCodeBuildHook(
        mainMethod: libusb_hook.main,
        targetOS: OS.linux,
        targetArchitecture: Architecture.x64,
        check: (input, output) {
          final asset = output.assets.code.single;
          final mode = asset.linkMode;
          expect(mode, isA<DynamicLoadingSystem>());
          expect((mode as DynamicLoadingSystem).uri.path, 'libusb-1.0.so.0');
          expect(asset.file, isNull);
        },
      );
      await testCodeBuildHook(
        mainMethod: libusb_hook.main,
        targetOS: OS.macOS,
        targetArchitecture: Architecture.arm64,
        check: (input, output) {
          final mode =
              output.assets.code.single.linkMode as DynamicLoadingSystem;
          expect(mode.uri.path, 'libusb-1.0.dylib');
        },
      );
    });
  });

  test('Android 钩子不登记 USB 库', () async {
    await inPackage(() async {
      await testCodeBuildHook(
        mainMethod: libusb_hook.main,
        targetOS: OS.android,
        targetArchitecture: Architecture.arm64,
        check: (input, output) {
          expect(output.assets.code, isEmpty);
        },
      );
    });
  });
}
