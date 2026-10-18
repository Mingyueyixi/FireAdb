import 'dart:io';

import 'package:libadb/src/libusb_binary.dart';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

/// 按目标系统登记 libusb。
///
/// Windows x64 和 ARM64 拷贝仓库里对应的 `libusb-1.0.dll`。Linux / macOS 若
/// `vendor/` 里有对应动态库也拷贝；没有则登记系统库名。Android 不登记。
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final plan = planLibusbBinary(
      code.targetOS.name,
      code.targetArchitecture.name,
      bundledExists: (relative) =>
          File.fromUri(input.packageRoot.resolve(relative)).existsSync(),
    );
    if (plan == null) return;
    final relative = plan.relativePath;
    if (relative != null) {
      final source = input.packageRoot.resolve(relative);
      output.dependencies.add(source);
      final directory = Directory.fromUri(input.outputDirectory);
      directory.createSync(recursive: true);
      final bundled = directory.uri.resolve(plan.fileName);
      await File.fromUri(source).copy(bundled.toFilePath());
      output.assets.code.add(
        CodeAsset(
          package: input.packageName,
          name: libusbCodeAssetName,
          linkMode: DynamicLoadingBundled(),
          file: bundled,
        ),
      );
      await _bundleFireUsb(input, output, directory);
      return;
    }
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: libusbCodeAssetName,
        linkMode: DynamicLoadingSystem(Uri(path: plan.systemName!)),
      ),
    );
    await _bundleFireUsb(input, output, Directory.fromUri(input.outputDirectory));
  });
}

/// Optional process-owned USB helper. Present after building native/fire_usb.
Future<void> _bundleFireUsb(
  BuildInput input,
  BuildOutputBuilder output,
  Directory directory,
) async {
  final os = input.config.code.targetOS.name;
  final arch = input.config.code.targetArchitecture.name;
  final fileName = switch (os) {
    'windows' => 'fire_usb.dll',
    'macos' => 'libfire_usb.dylib',
    'linux' => 'libfire_usb.so',
    _ => null,
  };
  if (fileName == null) return;
  final relative = 'vendor/$os/$arch/$fileName';
  final source = input.packageRoot.resolve(relative);
  if (!File.fromUri(source).existsSync()) return;
  output.dependencies.add(source);
  directory.createSync(recursive: true);
  final bundled = directory.uri.resolve(fileName);
  await File.fromUri(source).copy(bundled.toFilePath());
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: 'src/fire_usb.dart',
      linkMode: DynamicLoadingBundled(),
      file: bundled,
    ),
  );
}
