import 'dart:io';

import 'package:adb_usb/src/libusb_binary.dart';
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
      return;
    }
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: libusbCodeAssetName,
        linkMode: DynamicLoadingSystem(Uri(path: plan.systemName!)),
      ),
    );
  });
}
