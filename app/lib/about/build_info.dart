/// 构建期注入的元信息。打包脚本（scripts/build_app.py）通过
/// --dart-define 传入 git 提交与构建时间（Unix 秒）；直接 `flutter run`
/// 时两者为空，界面显示为开发构建。检查更新用它判断本地版本的新旧。
abstract final class BuildInfo {
  static const gitCommit = String.fromEnvironment('FIREADB_GIT_COMMIT');

  /// 构建时间，Unix 时间戳（秒），显示时格式化为本地时间。
  static const buildTime = String.fromEnvironment('FIREADB_BUILD_TIME');

  /// 未注入构建元信息的本地开发构建（提交号 unknown 也视为可用信息）。
  static bool get isDevBuild => buildTime.isEmpty;

  /// 构建时间解析为 epoch 秒；未注入或格式非法为 null。
  static int? get buildEpoch => int.tryParse(buildTime);
}
