// 应用图标生成工具：从母版（assets/icon/flame_master.png，无水印的
// 干净源图）缩放到各平台启动图标尺寸。
//
// 用法（仓库根执行）：dart run app/tool/generate_icons.dart
// 母版更新后重跑一次即可全平台同步。
import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  const masterPath = 'assets/icon/flame_master.png';
  final master = img.decodePng(File(masterPath).readAsBytesSync());
  if (master == null) {
    stderr.writeln('无法解码母版图标：$masterPath');
    exitCode = 1;
    return;
  }

  void writePng(String path, int size) {
    final resized = img.copyResize(
      master,
      width: size,
      height: size,
      interpolation: img.Interpolation.cubic,
    );
    File(path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(img.encodePng(resized));
    stdout.writeln('$path ($size×$size)');
  }

  // Android 启动图标（传统 mipmap，自适应图标由启动器缩放遮罩）。
  const androidSizes = <String, int>{
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
  };
  androidSizes.forEach(
    (dir, size) => writePng('android/app/src/main/res/$dir/ic_launcher.png', size),
  );

  // macOS AppIcon（Contents.json 引用的全部尺寸）。
  const macSizes = [16, 32, 64, 128, 256, 512, 1024];
  for (final size in macSizes) {
    writePng('macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$size.png', size);
  }

  // Windows ico（ICO 单文件内嵌多分辨率，最大 256）。
  final icoImages = <img.Image>[
    for (final size in const [16, 24, 32, 48, 64, 128, 256])
      img.copyResize(
        master,
        width: size,
        height: size,
        interpolation: img.Interpolation.cubic,
      ),
  ];
  const icoPath = 'windows/runner/resources/app_icon.ico';
  File(icoPath).writeAsBytesSync(img.IcoEncoder().encodeImages(icoImages));
  stdout.writeln('$icoPath (16–256 多分辨率)');
}
