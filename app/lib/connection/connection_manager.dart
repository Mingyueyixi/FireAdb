import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:adb_core/adb_core.dart';
import 'package:adb_usb/adb_usb.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_feedback.dart';
import 'model/connected_device.dart';
import 'model/device_profile.dart';

/// 管理所有 ADB 连接与连接历史，负责 RSA 密钥加载与历史持久化。
class ConnectionManager extends GetxService {
  static const String _historyPrefsKey = 'connection_history';

  final RxMap<String, ConnectedDevice> _devices =
      <String, ConnectedDevice>{}.obs;
  final RxMap<String, DeviceProfile> _profiles = <String, DeviceProfile>{}.obs;
  final RxList<DeviceProfile> _history = <DeviceProfile>[].obs;
  List<AdbRsaKeyPair> _signers = const <AdbRsaKeyPair>[];
  SharedPreferences? _prefs;
  bool _signerResolved = false;
  bool _historyLoaded = false;
  AdbServer? _localServer;
  UsbAdbTracker? _usbTracker;
  String? _loggedLocalUsbError;

  /// 本进程自己监听着 127.0.0.1:5037。USB 设备由它登记，列表走 host:devices。
  final RxBool ownsLocalAdbServer = false.obs;
  final RxnString localUsbError = RxnString();

  List<ConnectedDevice> get devices => _devices.values.toList();

  List<DeviceProfile> get profiles => _profiles.values.toList();

  List<DeviceProfile> get history => List<DeviceProfile>.unmodifiable(_history);

  ConnectedDevice? deviceOf(String serial) => _devices[serial];

  DeviceProfile? profileOf(String serial) => _profiles[serial];

  bool isConnected(String serial) => _devices.containsKey(serial);

  bool canConnectAdbDevice(AdbDeviceInfo info) => info.isOnline;

  DeviceProfile? profileForAdbDevice(AdbDeviceInfo info) {
    for (final profile in _profiles.values) {
      if (profile.serial == info.serial || profile.adbSerial == info.serial) {
        return profile;
      }
      final endpoint = _adbEndpoint(info.serial);
      if (endpoint != null &&
          profile.host == endpoint.$1 &&
          profile.port == endpoint.$2) {
        return profile;
      }
    }
    return null;
  }

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    if (!_historyLoaded) _loadHistory();
  }

  /// 没有官方 adb server 时，自己监听 5037。
  ///
  /// USB 枚举只在桌面端做。Android 没有 libusb，设备来自手动 TCP 和本机模拟器端口扫描。
  Future<void> ensureLocalAdbServer() async {
    if (_localServer != null) return;
    _resolveSigners();
    final server = await AdbServer.tryStart(signers: _signers);
    if (server == null) {
      developer.log(
        '127.0.0.1:5037 已有 ADB Server，直接使用它列出的设备',
        name: 'fire_adb',
      );
      return;
    }
    server.onKilled = _onLocalServerKilled;
    _localServer = server;
    ownsLocalAdbServer.value = true;
    if (!_desktopUsb) {
      developer.log('已启动本机 ADB Server 127.0.0.1:5037', name: 'fire_adb');
      return;
    }
    final tracker = UsbAdbTracker(
      server: server,
      signers: _signers,
      onError: _onLocalUsbError,
    );
    _usbTracker = tracker;
    tracker.start();
    developer.log('已启动本机 ADB Server 127.0.0.1:5037', name: 'fire_adb');
  }

  bool get _desktopUsb =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  void _onLocalUsbError(Object? error, StackTrace? stackTrace) {
    if (error == null) {
      localUsbError.value = null;
      _loggedLocalUsbError = null;
      return;
    }
    final message = '$error';
    localUsbError.value = message;
    if (message == _loggedLocalUsbError) return;
    _loggedLocalUsbError = message;
    logAppError('读取 USB 设备失败', error, stackTrace ?? StackTrace.current);
  }

  void _onLocalServerKilled() {
    ownsLocalAdbServer.value = false;
    _localServer = null;
    final tracker = _usbTracker;
    _usbTracker = null;
    if (tracker != null) unawaited(tracker.close());
  }

  void _resolveSigners() {
    if (_signerResolved) return;
    _signerResolved = true;
    try {
      final home = Platform.environment['HOME'];
      final profile = Platform.environment['USERPROFILE'];
      final root = (home != null && home.isNotEmpty) ? home : profile;
      if (root == null || root.isEmpty) return;
      final dir =
          '$root${Platform.pathSeparator}.config'
          '${Platform.pathSeparator}fire_adb';
      Directory(dir).createSync(recursive: true);
      _signers = <AdbRsaKeyPair>[
        loadOrCreateAdbKey('$dir${Platform.pathSeparator}adbkey.pem'),
      ];
    } catch (error, stackTrace) {
      logAppError('加载 ADB RSA 签名密钥失败', error, stackTrace);
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
    _resolveSigners();
    final device = await adbConnectTcp(host, port: port, signers: _signers);
    final profile = DeviceProfile(
      serial: device.serial,
      host: host,
      port: port,
      label: host,
    );
    await _registerConnection(profile, ConnectedDevice.direct(device));
    return device;
  }

  Future<ConnectedDevice> connectAdbDevice(
    AdbDeviceInfo info, {
    required AdbHostClient hostClient,
  }) async {
    await init();
    final existingProfile = profileForAdbDevice(info);
    if (existingProfile != null) {
      final existingDevice = _devices[existingProfile.serial];
      if (existingDevice != null) {
        await _remember(existingProfile);
        return existingDevice;
      }
    }

    if (!info.isOnline) {
      throw StateError('设备 ${info.serial} 当前状态为 ${info.state}，无法连接');
    }
    final device = ConnectedDevice.viaHost(hostClient, info.serial);
    final endpoint = _adbEndpoint(info.serial);
    final profile = DeviceProfile(
      serial: device.serial,
      host: endpoint?.$1,
      port: endpoint?.$2,
      label: info.model?.replaceAll('_', ' ') ?? info.product ?? device.serial,
      adbSerial: info.serial,
    );
    await _registerConnection(profile, device);
    return device;
  }

  /// 直接打开 USB 上的 ADB 接口，不经过本机 adb server。
  Future<AdbDevice> connectUsb(UsbAdbDevice usb) async {
    await init();
    _resolveSigners();
    final transport = await openUsbAdbDevice(usb);
    final connection = AdbConnection(transport, signers: _signers);
    try {
      await connection.connect();
    } catch (_) {
      await transport.close();
      rethrow;
    }
    final device = AdbDevice(connection);
    final profile = DeviceProfile(
      serial: device.serial,
      label: usb.productName ?? usb.address,
      adbSerial: device.serial,
      usbAddress: usb.address,
    );
    await _registerConnection(profile, ConnectedDevice.direct(device));
    return device;
  }

  Future<void> disconnect(String serial) async {
    final device = _devices.remove(serial);
    _profiles.remove(serial);
    if (device != null) {
      try {
        await device.close();
      } catch (error, stackTrace) {
        logAppError('关闭 ADB 设备连接失败：$serial', error, stackTrace);
      }
    }
  }

  Future<void> removeFromHistory(DeviceProfile profile) async {
    await init();
    _history.removeWhere((entry) => entry.historyKey == profile.historyKey);
    await _saveHistory();
  }

  Future<void> _registerConnection(
    DeviceProfile profile,
    ConnectedDevice device,
  ) async {
    _profiles[profile.serial] = profile;
    _devices[device.serial] = device;
    await _remember(profile);
  }

  Future<void> _remember(DeviceProfile profile) async {
    _history
      ..removeWhere((entry) => entry.historyKey == profile.historyKey)
      ..insert(0, profile);
    await _saveHistory();
  }

  void _loadHistory() {
    _history.clear();
    final entries = _prefs?.getStringList(_historyPrefsKey) ?? const <String>[];
    for (final entry in entries) {
      final profile = _decodeHistoryEntry(entry);
      if (profile == null ||
          _history.any((item) => item.historyKey == profile.historyKey)) {
        continue;
      }
      _history.add(profile);
    }
    _historyLoaded = true;
  }

  DeviceProfile? _decodeHistoryEntry(String entry) {
    if (entry.startsWith('{')) {
      try {
        final json = jsonDecode(entry);
        if (json is! Map<String, dynamic>) return null;
        final serial = json['serial'];
        final host = json['host'];
        final port = json['port'];
        final label = json['label'];
        final adbSerial = json['adbSerial'];
        if (serial is! String || serial.isEmpty) return null;
        if (host != null && host is! String) return null;
        if (port != null && port is! int) return null;
        if (label != null && label is! String) return null;
        if (adbSerial != null && adbSerial is! String) return null;
        final usbAddress = json['usbAddress'];
        if (usbAddress != null && usbAddress is! String) return null;
        return DeviceProfile(
          serial: serial,
          host: host as String?,
          port: port as int?,
          label: label as String? ?? '',
          adbSerial: adbSerial as String?,
          usbAddress: usbAddress as String?,
        );
      } on FormatException {
        return null;
      }
    }

    final separator = entry.lastIndexOf(':');
    if (separator < 1 || separator == entry.length - 1) return null;
    final port = int.tryParse(entry.substring(separator + 1));
    if (port == null || port <= 0 || port > 65535) return null;
    var host = entry.substring(0, separator);
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    if (host.isEmpty) return null;
    return DeviceProfile(serial: entry, host: host, port: port, label: host);
  }

  Future<void> _saveHistory() async {
    final preferences = _prefs;
    if (preferences == null) return;
    final encoded = _history
        .map(
          (profile) => jsonEncode(<String, Object?>{
            'serial': profile.serial,
            'host': profile.host,
            'port': profile.port,
            'label': profile.label,
            'adbSerial': profile.adbSerial,
            'usbAddress': profile.usbAddress,
          }),
        )
        .toList();
    try {
      final saved = await preferences.setStringList(_historyPrefsKey, encoded);
      if (!saved) throw StateError('SharedPreferences 未能保存连接历史');
    } catch (error, stackTrace) {
      logAppError('保存连接历史失败', error, stackTrace);
    }
  }

  static (String, int)? _adbEndpoint(String serial) {
    final separator = serial.lastIndexOf(':');
    if (separator < 1 || separator == serial.length - 1) return null;
    final port = int.tryParse(serial.substring(separator + 1));
    if (port == null || port <= 0 || port > 65535) return null;
    var host = serial.substring(0, separator);
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    return (host, port);
  }
}
