import 'dart:io';

import 'package:hooks/hooks.dart';

/// `flutter build` / `flutter run` 会先跑这个钩子，再打包 assets。
///
/// 只有 jar 不存在，或 [service.version] 和已构建的版本不一致时才启动 Gradle。
/// 改了 `android/fire_app_service` 的源码后，把 `service.version` 加一。
void main(List<String> args) async {
  await build(args, (input, output) async {
    final packageDir = Directory.fromUri(input.packageRoot);
    final versionFile = File(
      _path(packageDir, ['android', 'fire_app_service', 'service.version']),
    );
    final jar = File(_path(packageDir, ['assets', 'fire-app-service.jar']));
    final builtVersion = File(
      _path(packageDir, ['assets', 'fire-app-service.version']),
    );
    if (versionFile.existsSync()) output.dependencies.add(versionFile.uri);
    if (_versionMatches(jar, versionFile, builtVersion)) return;

    final androidDir = Directory(_path(packageDir, ['android']));
    final gradle = Platform.isWindows ? 'gradlew.bat' : './gradlew';
    final result = await Process.run(
      gradle,
      <String>[
        ':fire_app_service:packageAppServiceJar',
        '--console=plain',
      ],
      workingDirectory: androidDir.path,
      runInShell: Platform.isWindows,
    );
    if (result.exitCode != 0) {
      final details = '${result.stdout}\n${result.stderr}'.trim();
      throw StateError(
        '编译 fire-app-service.jar 失败（exit ${result.exitCode}）\n$details',
      );
    }
    if (!jar.existsSync()) {
      throw StateError('Gradle 已结束，但没有生成 ${jar.path}');
    }
    _writeBuiltVersion(versionFile, builtVersion);
  });
}

bool _versionMatches(File jar, File versionFile, File builtVersion) {
  if (!jar.existsSync() ||
      !versionFile.existsSync() ||
      !builtVersion.existsSync()) {
    return false;
  }
  return versionFile.readAsStringSync().trim() ==
      builtVersion.readAsStringSync().trim();
}

void _writeBuiltVersion(File versionFile, File builtVersion) {
  if (!versionFile.existsSync()) {
    throw StateError('缺少版本文件 ${versionFile.path}');
  }
  builtVersion.writeAsStringSync('${versionFile.readAsStringSync().trim()}\n');
}

String _path(Directory root, List<String> parts) {
  return [root.path, ...parts].join(Platform.pathSeparator);
}
