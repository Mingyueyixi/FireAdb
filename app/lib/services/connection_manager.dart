import 'dart:io';

import 'package:adb_core/adb_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/device_profile.dart';

/// 管理所有 ADB 连接与连接历史，负责 RSA 密钥加载与历史持久化。
class ConnectionManager extends ChangeNotifier {
  static const String _historyPrefsKey = 'connection_history';

  final Map<String, AdbDevice> _devices = <String, AdbDevice>{};
  final Map<String, DeviceProfile> _profiles = <String, DeviceProfile>{};
  final List<DeviceProfile> _history = <DeviceProfile>[];
  List<AdbRsaKeyPair> _signers = const <AdbRsaKeyPair>[];
  SharedPreferences? _prefs;
  bool _signerResolved = false;

  List<AdbDevice> get devices => _devices.values.toList();

  List<DeviceProfile> get profiles => _profiles.values.toList();

  List<DeviceProfile> get history => List<DeviceProfile>.unmodifiable(_history);

  AdbDevice? deviceOf(String serial) => _devices[serial];

  DeviceProfile? profileOf(String serial) => _profiles[serial];

  bool isConnected(String serial) => _devices.containsKey(serial);

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    _loadHistory();
    _resolveSigners();
  }

  void _resolveSigners() {
    if (_signerResolved) return;
    _signerResolved = true;
    try {
      final home = Platform.environment['HOME'];
      if (home == null || home.isEmpty) return;
      final dir = '$home${Platform.pathSeparator}.config'
          '${Platform.pathSeparator}fire_adb';
      Directory(dir).createSync(recursive: true);
      _signers = <AdbRsaKeyPair>[
        loadOrCreateAdbKey('$dir${Platform.pathSeparator}adbkey.pem'),
      ];
    } catch (_) {
      _signers = const <AdbRsaKeyPair>[];
    }
  }

  /// 直连 TCP 设备（WiFi adb connect / 模拟器端口）。
  ///
  /// 适用场景：
  /// - 已知设备 IP 和端口（如 `adb connect 192.168.8.150:6666`）
  /// - 设备**未**开启无线调试，或 mDNS 扫描无结果时
  /// - 模拟器端口、USB 网络共享等非 mDNS 场景
  ///
  /// 与 [MdnsBrowser.discover] 的区别：
  /// - 本方法：直接 TCP 握手，**不依赖 mDNS**，只要端口通即可连
  /// - mDNS 发现：仅能发现**主动广播** `_adb-tls-pairing._tcp` 等服务的设备
  Future<AdbDevice> connectHost(String host, int port) async {
    await init();
    final device = await adbConnectTcp(host, port: port, signers: _signers);
    _profiles[device.serial] = DeviceProfile(
      serial: device.serial,
      host: host,
      port: port,
      label: host,
    );
    _devices[device.serial] = device;
    _remember(host, port);
    notifyListeners();
    return device;
  }

  Future<void> disconnect(String serial) async {
    final device = _devices.remove(serial);
    _profiles.remove(serial);
    if (device != null) {
      try {
        await device.close();
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> removeFromHistory(DeviceProfile profile) async {
    await init();
    _history.remove(profile);
    _saveHistory();
    notifyListeners();
  }

  void _remember(String host, int port) {
    _history
      ..removeWhere((h) => h.host == host && h.port == port)
      ..insert(
        0,
        DeviceProfile(serial: '$host:$port', host: host, port: port),
      );
    _saveHistory();
  }

  void _loadHistory() {
    _history.clear();
    final entries =
        _prefs?.getStringList(_historyPrefsKey) ?? const <String>[];
    for (final entry in entries) {
      final parts = entry.split(':');
      if (parts.length != 2) continue;
      final port = int.tryParse(parts[1]);
      if (port == null || port <= 0) continue;
      _history.add(DeviceProfile(
        serial: entry,
        host: parts[0],
        port: port,
        label: parts[0],
      ));
    }
  }

  void _saveHistory() {
    _prefs?.setStringList(
      _historyPrefsKey,
      _history.map((h) => h.toHistoryKey()).toList(),
    );
  }
}