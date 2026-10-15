import 'dart:convert';

import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 文件管理和应用管理各自决定要不要用 su。
enum SuScope { files, apps }

/// 每台设备自己的 root 选择。`adb root` 作用于整条连接，su 按功能分开。
class DeviceRootOptions {
  const DeviceRootOptions({
    this.adbRoot = false,
    this.fileSu = false,
    this.appSu = false,
    this.suCommand = defaultSuCommand,
  });

  static const String defaultSuCommand = 'su';

  final bool adbRoot;
  final bool fileSu;
  final bool appSu;
  final String suCommand;

  bool suFor(SuScope scope) {
    return switch (scope) {
      SuScope.files => fileSu,
      SuScope.apps => appSu,
    };
  }

  bool get usesSu => fileSu || appSu;

  DeviceRootOptions copyWith({
    bool? adbRoot,
    bool? fileSu,
    bool? appSu,
    String? suCommand,
  }) {
    return DeviceRootOptions(
      adbRoot: adbRoot ?? this.adbRoot,
      fileSu: fileSu ?? this.fileSu,
      appSu: appSu ?? this.appSu,
      suCommand: suCommand ?? this.suCommand,
    );
  }

  Map<String, Object> toJson() {
    return <String, Object>{
      'adbRoot': adbRoot,
      'fileSu': fileSu,
      'appSu': appSu,
      'suCommand': suCommand,
    };
  }

  static DeviceRootOptions fromJson(Object? json) {
    if (json is! Map) return const DeviceRootOptions();
    final legacy = json['useSu'] == true;
    return DeviceRootOptions(
      adbRoot: json['adbRoot'] == true,
      fileSu: json.containsKey('fileSu') ? json['fileSu'] == true : legacy,
      appSu: json.containsKey('appSu') ? json['appSu'] == true : legacy,
      suCommand: normalizeSuCommand('${json['suCommand'] ?? ''}'),
    );
  }
}

/// 空、换行或过长都退回默认 `su`。
String normalizeSuCommand(String? value) {
  final trimmed = value?.trim() ?? '';
  if (trimmed.isEmpty || trimmed.contains('\n') || trimmed.contains('\r')) {
    return DeviceRootOptions.defaultSuCommand;
  }
  if (trimmed.length > 128) return DeviceRootOptions.defaultSuCommand;
  return trimmed;
}

class DeviceRootStore extends GetxController {
  static const String prefsKey = 'deviceRootOptions';

  final RxMap<String, DeviceRootOptions> options =
      <String, DeviceRootOptions>{}.obs;
  final RxSet<String> adbRootActive = <String>{}.obs;
  SharedPreferences? _preferences;

  DeviceRootOptions of(String serial) {
    return options[serial] ?? const DeviceRootOptions();
  }

  bool isAdbRootActive(String serial) => adbRootActive.contains(serial);

  Future<void> load() async {
    final preferences = _preferences ??= await SharedPreferences.getInstance();
    final raw = preferences.getString(prefsKey);
    if (raw == null || raw.isEmpty) return;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;
    options.assignAll(<String, DeviceRootOptions>{
      for (final entry in decoded.entries)
        if (entry.key is String)
          entry.key as String: DeviceRootOptions.fromJson(entry.value),
    });
  }

  void markAdbRoot(String serial, bool active) {
    if (active) {
      adbRootActive.add(serial);
    } else {
      adbRootActive.remove(serial);
    }
  }

  Future<void> setAdbRoot(String serial, bool value) {
    return _save(serial, of(serial).copyWith(adbRoot: value));
  }

  Future<void> setSuScope(String serial, SuScope scope, bool value) {
    final current = of(serial);
    final next = switch (scope) {
      SuScope.files => current.copyWith(fileSu: value),
      SuScope.apps => current.copyWith(appSu: value),
    };
    return _save(serial, next);
  }

  Future<void> setSuCommand(String serial, String value) {
    return _save(
      serial,
      of(serial).copyWith(suCommand: normalizeSuCommand(value)),
    );
  }

  Future<void> _save(String serial, DeviceRootOptions next) async {
    final previous = Map<String, DeviceRootOptions>.from(options);
    options[serial] = next;
    try {
      final preferences = _preferences ??=
          await SharedPreferences.getInstance();
      final saved = await preferences.setString(
        prefsKey,
        jsonEncode(<String, Object>{
          for (final entry in options.entries) entry.key: entry.value.toJson(),
        }),
      );
      if (!saved) throw StateError('SharedPreferences 未能保存设备 root 设置');
    } catch (_) {
      options.assignAll(previous);
      rethrow;
    }
  }
}
