import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 首页和设置页共用的自动刷新状态。
///
/// 设备列表默认开启，mDNS 默认关闭。间隔默认 3 秒，可在 1 到 3600 秒之间改。
class AppSettingsStore extends GetxController {
  static const String autoRefreshMdnsKey = 'autoRefreshMdns';
  static const String autoRefreshDevicesKey = 'autoRefreshDevices';
  static const String autoRefreshIntervalKey = 'autoRefreshIntervalSeconds';
  static const int defaultAutoRefreshSeconds = 3;
  static const int minAutoRefreshSeconds = 1;
  static const int maxAutoRefreshSeconds = 3600;

  final RxBool autoRefreshMdns = false.obs;
  final RxBool autoRefreshDevices = true.obs;
  final RxInt autoRefreshIntervalSeconds = defaultAutoRefreshSeconds.obs;

  SharedPreferences? _preferences;

  Future<void> load() async {
    final preferences = _preferences ??= await SharedPreferences.getInstance();
    autoRefreshMdns.value = preferences.getBool(autoRefreshMdnsKey) ?? false;
    autoRefreshDevices.value =
        preferences.getBool(autoRefreshDevicesKey) ?? true;
    autoRefreshIntervalSeconds.value = _clampInterval(
      preferences.getInt(autoRefreshIntervalKey),
    );
  }

  Future<void> setAutoRefreshMdns(bool value) {
    return _save(autoRefreshMdns, autoRefreshMdnsKey, value);
  }

  Future<void> setAutoRefreshDevices(bool value) {
    return _save(autoRefreshDevices, autoRefreshDevicesKey, value);
  }

  Future<void> setAutoRefreshIntervalSeconds(int seconds) async {
    final value = _clampInterval(seconds);
    if (value != seconds) {
      throw ArgumentError.value(seconds, 'seconds', '刷新间隔超出范围');
    }
    final previous = autoRefreshIntervalSeconds.value;
    autoRefreshIntervalSeconds.value = value;
    try {
      final preferences = _preferences ??=
          await SharedPreferences.getInstance();
      final saved = await preferences.setInt(autoRefreshIntervalKey, value);
      if (!saved) {
        throw StateError('SharedPreferences 未能保存设置');
      }
    } catch (_) {
      autoRefreshIntervalSeconds.value = previous;
      rethrow;
    }
  }

  static int _clampInterval(int? seconds) {
    if (seconds == null) return defaultAutoRefreshSeconds;
    if (seconds < minAutoRefreshSeconds || seconds > maxAutoRefreshSeconds) {
      return defaultAutoRefreshSeconds;
    }
    return seconds;
  }

  Future<void> _save(RxBool target, String key, bool value) async {
    final previous = target.value;
    target.value = value;
    try {
      final preferences = _preferences ??=
          await SharedPreferences.getInstance();
      final saved = await preferences.setBool(key, value);
      if (!saved) {
        throw StateError('SharedPreferences 未能保存设置');
      }
    } catch (_) {
      target.value = previous;
      rethrow;
    }
  }
}
