import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../log/app_log.dart';

/// 首页和设置页共用的设置。自动刷新、日志缓冲区和保存天数都记在这里。
///
/// 设备列表默认开启，mDNS 默认关闭。间隔默认 3 秒，可在 1 到 3600 秒之间改。
class AppSettingsStore extends GetxController {
  static const String autoRefreshMdnsKey = 'autoRefreshMdns';
  static const String autoRefreshDevicesKey = 'autoRefreshDevices';
  static const String autoRefreshIntervalKey = 'autoRefreshIntervalSeconds';
  static const String refreshInBackgroundKey = 'refreshInBackground';
  static const String logBufferKbKey = 'logBufferKb';
  static const String logRetentionDaysKey = 'logRetentionDays';
  static const int defaultAutoRefreshSeconds = 3;
  static const int minAutoRefreshSeconds = 1;
  static const int maxAutoRefreshSeconds = 3600;
  static const int defaultLogBufferKb = 256;
  static const int minLogBufferKb = 16;
  static const int maxLogBufferKb = 8192;
  static const int defaultLogRetentionDays = 7;
  static const int minLogRetentionDays = 1;
  static const int maxLogRetentionDays = 365;

  final RxBool autoRefreshMdns = false.obs;
  final RxBool autoRefreshDevices = true.obs;

  /// 默认关闭：连接页不在前台，或应用进入后台时，不自动刷新。
  final RxBool refreshInBackground = false.obs;
  final RxInt autoRefreshIntervalSeconds = defaultAutoRefreshSeconds.obs;
  final RxInt logBufferKb = defaultLogBufferKb.obs;
  final RxInt logRetentionDays = defaultLogRetentionDays.obs;

  SharedPreferences? _preferences;

  Future<void> load() async {
    final preferences = _preferences ??= await SharedPreferences.getInstance();
    autoRefreshMdns.value = preferences.getBool(autoRefreshMdnsKey) ?? false;
    autoRefreshDevices.value =
        preferences.getBool(autoRefreshDevicesKey) ?? true;
    refreshInBackground.value =
        preferences.getBool(refreshInBackgroundKey) ?? false;
    autoRefreshIntervalSeconds.value = _clampInterval(
      preferences.getInt(autoRefreshIntervalKey),
    );
    logBufferKb.value = _clampRange(
      preferences.getInt(logBufferKbKey),
      min: minLogBufferKb,
      max: maxLogBufferKb,
      fallback: defaultLogBufferKb,
    );
    logRetentionDays.value = _clampRange(
      preferences.getInt(logRetentionDaysKey),
      min: minLogRetentionDays,
      max: maxLogRetentionDays,
      fallback: defaultLogRetentionDays,
    );
    sessionLog.setMaxCharacters(logBufferKb.value * 1024);
  }

  Future<void> setAutoRefreshMdns(bool value) {
    return _save(autoRefreshMdns, autoRefreshMdnsKey, value);
  }

  Future<void> setAutoRefreshDevices(bool value) {
    return _save(autoRefreshDevices, autoRefreshDevicesKey, value);
  }

  Future<void> setRefreshInBackground(bool value) {
    return _save(refreshInBackground, refreshInBackgroundKey, value);
  }

  Future<void> setAutoRefreshIntervalSeconds(int seconds) {
    return _saveInt(
      autoRefreshIntervalSeconds,
      autoRefreshIntervalKey,
      seconds,
      min: minAutoRefreshSeconds,
      max: maxAutoRefreshSeconds,
      name: 'seconds',
      reason: '刷新间隔超出范围',
    );
  }

  Future<void> setLogBufferKb(int kb) {
    return _saveInt(
      logBufferKb,
      logBufferKbKey,
      kb,
      min: minLogBufferKb,
      max: maxLogBufferKb,
      name: 'kb',
      reason: '日志缓冲区超出范围',
      afterSave: () => sessionLog.setMaxCharacters(kb * 1024),
    );
  }

  Future<void> setLogRetentionDays(int days) {
    return _saveInt(
      logRetentionDays,
      logRetentionDaysKey,
      days,
      min: minLogRetentionDays,
      max: maxLogRetentionDays,
      name: 'days',
      reason: '日志保存天数超出范围',
    );
  }

  static int _clampInterval(int? seconds) {
    return _clampRange(
      seconds,
      min: minAutoRefreshSeconds,
      max: maxAutoRefreshSeconds,
      fallback: defaultAutoRefreshSeconds,
    );
  }

  static int _clampRange(
    int? value, {
    required int min,
    required int max,
    required int fallback,
  }) {
    if (value == null || value < min || value > max) return fallback;
    return value;
  }

  Future<void> _saveInt(
    RxInt target,
    String key,
    int value, {
    required int min,
    required int max,
    required String name,
    required String reason,
    void Function()? afterSave,
  }) async {
    if (value < min || value > max) {
      throw ArgumentError.value(value, name, reason);
    }
    final previous = target.value;
    target.value = value;
    try {
      final preferences = _preferences ??=
          await SharedPreferences.getInstance();
      final saved = await preferences.setInt(key, value);
      if (!saved) {
        throw StateError('SharedPreferences 未能保存设置');
      }
      afterSave?.call();
    } catch (_) {
      target.value = previous;
      rethrow;
    }
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
