import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:get/get.dart';
import 'package:libadb/libadb.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../log/app_log.dart';
import 'adb_key_path.dart';
import 'model/connected_device.dart';
import 'model/device_profile.dart';
import 'sdk_adb.dart';

const int _defaultAdbServerPort = adbServerPort;

/// 管理所有 ADB 连接与连接历史，负责 RSA 密钥加载与历史持久化。
class ConnectionManager extends GetxService {
  static const String _historyPrefsKey = 'connection_history';
  static const String _manualHostPrefsKey = 'manual_connection_host';
  static const String _manualPortPrefsKey = 'manual_connection_port';
  static const String _preferSdkAdbServerKey = 'prefer_sdk_adb_server';
  static const String _adbServerPortKey = 'fire_adb_server_port';

  /// 新连接登记后调用。用来按设备尝试 adb root，失败则保持普通连接。
  Future<void> Function(String serial)? afterConnect;
  var _skipAfterConnect = 0;

  final RxMap<String, ConnectedDevice> _devices =
      <String, ConnectedDevice>{}.obs;
  final RxMap<String, DeviceProfile> _profiles = <String, DeviceProfile>{}.obs;
  final RxList<DeviceProfile> _history = <DeviceProfile>[].obs;
  List<AdbRsaKeyPair> _signers = const <AdbRsaKeyPair>[];
  SharedPreferences? _prefs;
  bool _signerResolved = false;
  Object? _signerError;
  bool _historyLoaded = false;
  LocalAdb? _localAdb;
  String? _loggedLocalUsbError;

  /// 本进程自己监听着本机 adb server 端口。USB 设备由它登记，列表走 host:devices。
  final RxBool ownsLocalAdbServer = false.obs;

  /// FireAdb 自己的 adb server 端口。设备列表也连接这里。
  final RxInt adbServerPort = _defaultAdbServerPort.obs;

  /// 电脑上优先让 SDK 的 adb 占用 [adbServerPort]。Android 不使用这项。默认关闭。
  final RxBool preferSdkAdbServer = false.obs;

  /// 当前设备列表来自 SDK adb 启动的 server。
  final RxBool usingSdkAdbServer = false.obs;

  /// 找到的 adb 路径。没有则为空。
  final RxnString sdkAdbPath = RxnString();

  /// 最近一次启动 SDK adb server 的失败原因。
  final RxnString sdkAdbError = RxnString();
  final RxnString localUsbError = RxnString();
  bool _serverSettingsLoaded = false;

  AdbHostClient hostClient({
    Duration connectTimeout = const Duration(seconds: 10),
  }) {
    return AdbHostClient(
      port: adbServerPort.value,
      connectTimeout: connectTimeout,
    );
  }

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

  /// 按设置选择本机 adb server 端口上的 server。
  ///
  /// 电脑上勾选优先使用 SDK 时，先找 adb 并在该端口执行 `start-server`。
  /// 找不到或启动失败时，再由本进程监听。Android 没有这项，始终走本进程。
  /// 未勾选时默认由本进程监听。
  Future<void> ensureLocalAdbServer({bool restart = false}) async {
    await init();
    _loadServerSettings();
    if (!restart && (_localAdb != null || usingSdkAdbServer.value)) return;
    await _applyAdbServer(releaseSdkServer: false);
  }

  Future<void> setPreferSdkAdbServer(bool value) async {
    await init();
    _loadServerSettings();
    preferSdkAdbServer.value = value;
    final preferences = _prefs;
    if (preferences != null) {
      final saved = await preferences.setBool(_preferSdkAdbServerKey, value);
      if (!saved) throw StateError('SharedPreferences 未能保存 adb server 设置');
    }
    await _applyAdbServer(releaseSdkServer: !value);
    _retargetHostClients();
  }

  Future<void> setAdbServerPort(int port) async {
    if (port < 1 || port > 65535) {
      throw ArgumentError.value(port, 'port', '端口必须在 1 到 65535 之间');
    }
    await init();
    _loadServerSettings();
    if (port == adbServerPort.value) return;
    final previous = adbServerPort.value;
    final preferences = _prefs;
    if (preferences != null) {
      final saved = await preferences.setInt(_adbServerPortKey, port);
      if (!saved) throw StateError('SharedPreferences 未能保存 adb server 端口');
    }
    if (usingSdkAdbServer.value) {
      final adb = sdkAdbPath.value ?? await findSdkAdb();
      sdkAdbPath.value = adb;
      if (adb != null) {
        try {
          await killSdkAdbServer(adb, port: previous);
        } catch (error, stackTrace) {
          log.severe('关闭 SDK adb server 失败', error, stackTrace);
        }
      }
      usingSdkAdbServer.value = false;
    }
    await _stopFireServer();
    adbServerPort.value = port;
    await _applyAdbServer(releaseSdkServer: false);
    _retargetHostClients();
  }

  void _loadServerSettings() {
    if (_serverSettingsLoaded) return;
    _serverSettingsLoaded = true;
    final storedPrefer = _prefs?.getBool(_preferSdkAdbServerKey);
    if (storedPrefer != null) preferSdkAdbServer.value = storedPrefer;
    final storedPort = _prefs?.getInt(_adbServerPortKey);
    if (storedPort != null && storedPort >= 1 && storedPort <= 65535) {
      adbServerPort.value = storedPort;
    }
  }

  void _retargetHostClients() {
    final client = hostClient();
    for (final device in _devices.values) {
      device.retargetHostClient(client);
    }
  }

  bool get _useSdkAdbServer => !Platform.isAndroid && preferSdkAdbServer.value;

  Future<void> _applyAdbServer({required bool releaseSdkServer}) async {
    if (_useSdkAdbServer) {
      final adb = await findSdkAdb();
      sdkAdbPath.value = adb;
      if (adb != null) {
        try {
          await _stopFireServer();
          await startSdkAdbServer(adb, port: adbServerPort.value);
          usingSdkAdbServer.value = true;
          sdkAdbError.value = null;
          log.info('已使用 SDK adb server：$adb，端口 ${adbServerPort.value}');
          return;
        } catch (error, stackTrace) {
          log.severe('启动 SDK adb server 失败', error, stackTrace);
          sdkAdbError.value = '$error';
          usingSdkAdbServer.value = false;
        }
      } else {
        sdkAdbError.value = null;
        usingSdkAdbServer.value = false;
      }
    } else {
      sdkAdbError.value = null;
      if (releaseSdkServer) {
        final adb = sdkAdbPath.value ?? await findSdkAdb();
        sdkAdbPath.value = adb;
        if (adb != null) {
          try {
            await killSdkAdbServer(adb, port: adbServerPort.value);
          } catch (error, stackTrace) {
            log.severe('关闭 SDK adb server 失败', error, stackTrace);
          }
        }
      }
      usingSdkAdbServer.value = false;
    }
    await _startFireServer();
  }

  Future<void> _stopFireServer() async {
    final local = _localAdb;
    _localAdb = null;
    ownsLocalAdbServer.value = false;
    if (local != null) await local.close();
  }

  /// USB 枚举只在桌面端做。Android 没有 libusb，设备来自手动 TCP 和本机模拟器端口扫描。
  Future<void> _startFireServer() async {
    if (_localAdb != null) return;
    _resolveSigners();
    final port = adbServerPort.value;
    final local = await LocalAdb.tryStart(
      port: port,
      signers: _signers,
      onKilled: _onLocalServerKilled,
      onUsbError: _onLocalUsbError,
    );
    if (local == null) {
      log.info('127.0.0.1:$port 已有 ADB Server，直接使用它列出的设备');
      return;
    }
    _localAdb = local;
    ownsLocalAdbServer.value = true;
    log.info('已启动本机 ADB Server 127.0.0.1:$port');
  }

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
    log.severe('读取 USB 设备失败', error, stackTrace ?? StackTrace.current);
  }

  void _onLocalServerKilled() {
    ownsLocalAdbServer.value = false;
    _localAdb = null;
  }

  void _resolveSigners() {
    if (_signerResolved) return;
    try {
      final path = adbKeyFilePath(
        android: Platform.isAndroid,
        environment: Platform.environment,
        androidDataDir: Directory.systemTemp.parent.path,
      );
      _signers = <AdbRsaKeyPair>[loadOrCreateAdbKey(path)];
      _signerError = null;
      _signerResolved = true;
    } catch (error, stackTrace) {
      log.severe('加载 ADB RSA 签名密钥失败', error, stackTrace);
      _signers = const <AdbRsaKeyPair>[];
      _signerError = error;
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
  Future<AdbDevice> connectHost(
    String host,
    int port, {
    bool rememberManual = true,
  }) async {
    await init();
    _resolveSigners();
    final device = await adbConnectTcp(host, port: port, signers: _signers);
    final connected = ConnectedDevice.direct(device);
    final profile = DeviceProfile(
      serial: device.serial,
      host: host,
      port: port,
      label: _savedHostLabel(host, port) ?? host,
    );
    if (rememberManual) await rememberManualEndpoint(host, port);
    await _registerConnection(profile, connected);
    return device;
  }

  /// 用手机上的配对码完成无线调试配对。成功后，同一把密钥可以连 TLS 端口。
  Future<void> pairWireless(String host, int port, String code) async {
    await init();
    _resolveSigners();
    if (_signers.isEmpty) {
      final reason = _signerError;
      throw AdbKeyUnavailable(
        reason == null ? '没有 ADB 密钥，无法配对' : '没有 ADB 密钥，无法配对：$reason',
      );
    }
    final password = code.replaceAll(RegExp(r'\s+'), '');
    if (password.isEmpty) {
      throw const FormatException('配对码为空');
    }
    final key = _signers.first;
    final socket = await _connectTcp(host, port);
    try {
      await runPairing(
        socket: socket,
        isClient: true,
        password: utf8.encode(password),
        tlsKey: key,
        tlsCertificate: buildSelfSignedRsaCertificate(key),
        localPeerInfo: AdbPeerInfo(
          type: AdbPeerInfo.typeRsaPubKey,
          data: utf8.encode(key.base64PublicKey()),
        ),
      );
    } finally {
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  Future<Socket> _connectTcp(String host, int port) async {
    final interfaces = await NetworkInterface.list(
      includeLinkLocal: true,
      type: InternetAddressType.IPv6,
    );
    final targets = linkLocalConnectHosts(host, <({String name, int index})>[
      for (final iface in interfaces)
        if (iface.addresses.any((address) => address.isLinkLocal))
          (name: iface.name, index: iface.index),
    ]);
    Object? lastError;
    for (final target in targets) {
      try {
        return await Socket.connect(
          target,
          port,
          timeout: const Duration(seconds: 10),
        );
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? StateError('无法连接 $host:$port');
  }

  /// 上次成功的手动连接。首页用它把地址填回输入框。
  (String, int)? manualEndpoint() {
    final host = _prefs?.getString(_manualHostPrefsKey);
    final port = _prefs?.getInt(_manualPortPrefsKey);
    if (host == null || host.isEmpty) return null;
    if (port == null || port <= 0 || port > 65535) return null;
    return (host, port);
  }

  Future<void> rememberManualEndpoint(String host, int port) async {
    await init();
    final preferences = _prefs;
    if (preferences == null) return;
    try {
      final savedHost = await preferences.setString(_manualHostPrefsKey, host);
      final savedPort = await preferences.setInt(_manualPortPrefsKey, port);
      if (!savedHost || !savedPort) {
        throw StateError('SharedPreferences 未能保存手动连接');
      }
    } catch (error, stackTrace) {
      log.severe('保存手动连接失败', error, stackTrace);
    }
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

  /// adbd 因 root / unroot 重启后，按原来的地址把直连设备接回来。
  /// 经本机 adb server 的连接不用换对象，server 会自己重连。
  Future<ConnectedDevice?> reconnectDirect(String serial) async {
    final current = deviceOf(serial);
    if (current != null && current.usesHost) return current;
    final profile = profileOf(serial);
    if (profile == null) return null;
    _skipAfterConnect++;
    try {
      final host = profile.host;
      final port = profile.port;
      final usbAddress = profile.usbAddress;
      final adbSerial = profile.adbSerial;
      await disconnect(serial);
      if (host != null && port != null) {
        final adb = await connectHost(host, port, rememberManual: false);
        return deviceOf(adb.serial);
      }
      if (usbAddress == null && adbSerial == null) return null;
      final usb = await _matchUsb(usbAddress, adbSerial);
      if (usb == null) return null;
      final adb = await connectUsb(usb);
      return deviceOf(adb.serial);
    } finally {
      _skipAfterConnect--;
    }
  }

  Future<UsbAdbDevice?> _matchUsb(String? address, String? serial) async {
    final devices = await listUsbAdbDevices();
    for (final usb in devices) {
      if (address != null && usb.address == address) return usb;
      if (serial != null && usb.serialNumber == serial) return usb;
    }
    return null;
  }

  Future<void> disconnect(String serial) async {
    final device = _devices.remove(serial);
    _profiles.remove(serial);
    if (device != null) {
      try {
        await device.close();
      } catch (error, stackTrace) {
        log.severe('关闭 ADB 设备连接失败：$serial', error, stackTrace);
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
    final hook = afterConnect;
    if (hook != null && _skipAfterConnect == 0) {
      await hook(device.serial);
    }
    if (deviceOf(profile.serial) == null) {
      throw StateError('adb root 后设备没有连上');
    }
    final current = deviceOf(profile.serial);
    final currentProfile = profileOf(profile.serial);
    if (current != null &&
        currentProfile != null &&
        !currentProfile.hasDeviceName) {
      unawaited(_refreshDeviceName(currentProfile, current));
    }
  }

  String? _savedHostLabel(String host, int port) {
    final key = 'tcp:$host:$port';
    for (final entry in _history) {
      if (entry.historyKey == key && entry.hasDeviceName) return entry.label;
    }
    return null;
  }

  /// 手动输入地址、二维码连上时往往只有地址。和没有型号的 USB、adb 列表一样，连上后读设备型号。
  Future<void> _refreshDeviceName(
    DeviceProfile profile,
    ConnectedDevice device,
  ) async {
    final model = await _modelName(device);
    if (model == null || model == profile.label) return;
    final updated = DeviceProfile(
      serial: profile.serial,
      host: profile.host,
      port: profile.port,
      label: model,
      adbSerial: profile.adbSerial,
      usbAddress: profile.usbAddress,
    );
    if (_devices.containsKey(device.serial)) {
      _profiles[profile.serial] = updated;
    }
    await _remember(updated);
  }

  Future<String?> _modelName(ConnectedDevice device) async {
    try {
      final model = (await device.shell('getprop ro.product.model'))
          .trim()
          .replaceAll('_', ' ');
      if (model.isEmpty) return null;
      return model;
    } catch (error, stackTrace) {
      log.severe('读取设备名称失败', error, stackTrace);
      return null;
    }
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
        if (json is! Map) return null;
        final serial = json['serial'];
        final host = json['host'];
        final port = json['port'];
        final label = json['label'];
        final adbSerial = json['adbSerial'];
        if (serial != null && serial is! String) return null;
        if (host != null && host is! String) return null;
        if (port != null && port is! int) return null;
        if (label != null && label is! String) return null;
        if (adbSerial != null && adbSerial is! String) return null;
        final usbAddress = json['usbAddress'];
        if (usbAddress != null && usbAddress is! String) return null;
        final hostText = host as String?;
        final portNumber = port as int?;
        // 无线直连的 CNXN banner 经常是 device::...，序列号是空的。
        // 这条历史仍然有效，用主机和端口当作标识。
        var serialText = serial as String? ?? '';
        if (serialText.isEmpty) {
          if (hostText == null ||
              hostText.isEmpty ||
              portNumber == null ||
              portNumber <= 0 ||
              portNumber > 65535) {
            return null;
          }
          serialText = '$hostText:$portNumber';
        }
        return DeviceProfile(
          serial: serialText,
          host: hostText,
          port: portNumber,
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

  String _storedSerial(DeviceProfile profile) {
    if (profile.serial.isNotEmpty) return profile.serial;
    final host = profile.host;
    final port = profile.port;
    if (host != null && host.isNotEmpty && port != null) {
      return '$host:$port';
    }
    final adbSerial = profile.adbSerial;
    if (adbSerial != null && adbSerial.isNotEmpty) return adbSerial;
    return profile.serial;
  }

  Future<void> _saveHistory() async {
    final preferences = _prefs;
    if (preferences == null) return;
    final encoded = _history
        .map(
          (profile) => jsonEncode(<String, Object?>{
            'serial': _storedSerial(profile),
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
      log.severe('保存连接历史失败', error, stackTrace);
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
