import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:libadb/libadb.dart';

import '../connection/connection_manager.dart';
import '../connection/model/connected_device.dart';
import '../log/app_log.dart';
import '../settings/app_settings_store.dart';

class HomeController extends GetxController {
  static const Duration adbDeviceRefreshInterval = Duration(seconds: 3);

  HomeController({
    AdbHostClient? hostClient,
    Future<List<UsbAdbDevice>> Function()? listUsbDevices,
    bool? usbSupported,
    this.discoverServices,
  }) : _injectedHostClient = hostClient,
       _listUsbDevices = listUsbDevices ?? listUsbAdbDevices,
       usbSupported = usbSupported ?? libadbUsbSupported;

  final AdbHostClient? _injectedHostClient;

  AdbHostClient get _hostClient =>
      _injectedHostClient ??
      manager.hostClient(connectTimeout: const Duration(milliseconds: 400));
  final Future<List<UsbAdbDevice>> Function() _listUsbDevices;
  final bool usbSupported;

  /// 测试可替换 mDNS 发现。为空时走真实扫描。
  final Future<List<MdnsService>> Function(
    void Function(List<MdnsService> services)? onUpdate,
  )?
  discoverServices;

  final TextEditingController hostController = TextEditingController();
  final TextEditingController portController = TextEditingController(
    text: '5555',
  );
  final RxBool connecting = false.obs;
  final RxBool scanning = false.obs;
  final RxBool loadingAdbDevices = false.obs;
  final RxList<MdnsService> discovered = <MdnsService>[].obs;
  final RxList<AdbDeviceInfo> adbDevices = <AdbDeviceInfo>[].obs;
  final RxList<UsbAdbDevice> usbDevices = <UsbAdbDevice>[].obs;
  final RxBool loadingUsbDevices = false.obs;
  final RxnString scanError = RxnString();
  final RxnString adbDevicesError = RxnString();
  final RxnString usbDevicesError = RxnString();

  /// 各平台都有本机 ADB Server。Android 没有 USB 传输，列表里不会出现插线设备。
  final RxBool adbServerSupported = true.obs;

  /// 本机 5037 没有 adb server。这是正常情况，不按异常记录。
  final RxBool adbServerAbsent = false.obs;
  String? _loggedUsbError;
  String? _loggedAdbError;
  Timer? _adbDeviceRefreshTimer;
  Timer? _mdnsRefreshTimer;
  Worker? _devicesRefreshWorker;
  Worker? _mdnsRefreshWorker;
  Worker? _intervalWorker;
  var _mdnsRefreshGeneration = 0;

  ConnectionManager get manager => Get.find<ConnectionManager>();

  AppSettingsStore get _settings => Get.find<AppSettingsStore>();

  @override
  void onInit() {
    super.onInit();
    _restoreManualConnection();
    final canListDevices = adbServerSupported.value || usbSupported;
    if (canListDevices) {
      _applyDeviceAutoRefresh(_settings.autoRefreshDevices.value);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (isClosed) return;
        refreshListedDevices();
      });
    }
    _applyMdnsAutoRefresh(_settings.autoRefreshMdns.value);
    _devicesRefreshWorker = ever<bool>(
      _settings.autoRefreshDevices,
      _applyDeviceAutoRefresh,
    );
    _mdnsRefreshWorker = ever<bool>(
      _settings.autoRefreshMdns,
      _applyMdnsAutoRefresh,
    );
    _intervalWorker = ever<int>(_settings.autoRefreshIntervalSeconds, (_) {
      _applyDeviceAutoRefresh(_settings.autoRefreshDevices.value);
      _applyMdnsAutoRefresh(_settings.autoRefreshMdns.value);
    });
  }

  Duration get _refreshInterval =>
      Duration(seconds: _settings.autoRefreshIntervalSeconds.value);

  void _applyDeviceAutoRefresh(bool enabled) {
    _adbDeviceRefreshTimer?.cancel();
    _adbDeviceRefreshTimer = null;
    if (!enabled || isClosed) return;
    if (!adbServerSupported.value && !usbSupported) return;
    _adbDeviceRefreshTimer = Timer.periodic(_refreshInterval, (_) {
      refreshListedDevices();
    });
  }

  /// 上一次扫描结束后再等设定的秒数。扫描本身大约要数秒，固定周期会和它叠在一起。
  void _applyMdnsAutoRefresh(bool enabled) {
    _mdnsRefreshTimer?.cancel();
    _mdnsRefreshTimer = null;
    _mdnsRefreshGeneration++;
    if (!enabled || isClosed) return;
    _scheduleMdnsRefresh(_mdnsRefreshGeneration);
  }

  void _scheduleMdnsRefresh(int generation) {
    _mdnsRefreshTimer = Timer(_refreshInterval, () async {
      if (generation != _mdnsRefreshGeneration || isClosed) return;
      await scan(automatic: true);
      if (generation != _mdnsRefreshGeneration || isClosed) return;
      if (!_settings.autoRefreshMdns.value) return;
      _scheduleMdnsRefresh(generation);
    });
  }

  bool get showDirectUsbList =>
      usbSupported &&
      !manager.ownsLocalAdbServer.value &&
      !manager.usingSdkAdbServer.value;

  void _restoreManualConnection() {
    final endpoint = manager.manualEndpoint();
    if (endpoint == null) return;
    hostController.text = endpoint.$1;
    portController.text = '${endpoint.$2}';
  }

  void refreshListedDevices() {
    if (adbServerSupported.value) unawaited(refreshAdbDevices());
    if (showDirectUsbList) {
      unawaited(refreshUsbDevices());
    } else {
      usbDevices.clear();
    }
  }

  Future<AdbDevice> connectUsb(UsbAdbDevice device) async {
    connecting.value = true;
    try {
      return await manager.connectUsb(device);
    } finally {
      connecting.value = false;
    }
  }

  Future<void> pair(String host, int port, String code) async {
    connecting.value = true;
    try {
      await manager.pairWireless(host, port, code);
    } finally {
      connecting.value = false;
    }
  }

  Future<AdbDevice> connect(String host, int port) async {
    connecting.value = true;
    try {
      return await manager.connectHost(host, port);
    } finally {
      connecting.value = false;
    }
  }

  Future<ConnectedDevice> connectAdbDevice(AdbDeviceInfo device) async {
    connecting.value = true;
    try {
      return await manager.connectAdbDevice(device, hostClient: _hostClient);
    } finally {
      connecting.value = false;
    }
  }

  Future<void> scan({bool automatic = false}) async {
    if (scanning.value) return;
    scanning.value = true;
    scanError.value = null;
    if (!automatic) {
      log.info('开始扫描无线设备');
      discovered.clear();
    }
    try {
      final found = await _discover((services) {
        discovered.assignAll(services);
        if (!automatic) {
          log.info(
            '扫描到 ${services.length} 个：${services.map((service) => service.endpointText).join('，')}',
          );
        }
      });
      discovered.assignAll(found);
      if (!automatic) {
        log.info(found.isEmpty ? '扫描结束，没有发现无线设备' : '扫描结束，共 ${found.length} 个');
      }
    } catch (error, stackTrace) {
      log.severe('mDNS 设备扫描失败', error, stackTrace);
      scanError.value = '$error';
    } finally {
      scanning.value = false;
    }
  }

  /// 给二维码配对用。不改首页上的发现列表，也不占用扫描按钮。
  ///
  /// [stopWhen] 成立时马上返回，不用等满 [timeout]。
  Future<List<MdnsService>> discoverServicesOnce({
    Duration? timeout,
    void Function(List<MdnsService> services)? onUpdate,
    bool Function(List<MdnsService> services)? stopWhen,
    bool Function()? isCancelled,
  }) {
    return _discover(
      onUpdate,
      timeout: timeout,
      stopWhen: stopWhen,
      isCancelled: isCancelled,
    );
  }

  Future<List<MdnsService>> _discover(
    void Function(List<MdnsService> services)? onUpdate, {
    Duration? timeout,
    bool Function(List<MdnsService> services)? stopWhen,
    bool Function()? isCancelled,
  }) {
    final override = discoverServices;
    if (override != null) return override(onUpdate);
    return discoverAdbServices(
      serviceTypes: const <String>{
        adbServiceTypeTransport,
        adbServiceTypeConnect,
        adbServiceTypePairing,
      },
      timeout: timeout ?? kMdnsInterfaceTimeout,
      onUpdate: onUpdate,
      stopWhen: stopWhen,
      requeryInterval: stopWhen == null ? null : const Duration(seconds: 1),
      isCancelled: isCancelled,
    );
  }

  Future<void> refreshUsbDevices() async {
    if (!showDirectUsbList || loadingUsbDevices.value) return;
    loadingUsbDevices.value = true;
    usbDevicesError.value = null;
    try {
      usbDevices.assignAll(await _listUsbDevices());
      _loggedUsbError = null;
    } catch (error, stackTrace) {
      final message = '$error';
      if (message != _loggedUsbError) {
        _loggedUsbError = message;
        log.severe('刷新 USB 设备列表失败', error, stackTrace);
      }
      usbDevicesError.value = message;
    } finally {
      loadingUsbDevices.value = false;
    }
  }

  Future<void> refreshAdbDevices() async {
    if (!adbServerSupported.value || loadingAdbDevices.value) return;
    loadingAdbDevices.value = true;
    adbDevicesError.value = null;
    try {
      adbDevices.assignAll(await _hostClient.devices(long: true));
      _loggedAdbError = null;
      adbServerAbsent.value = false;
    } catch (error, stackTrace) {
      if (_isAdbServerAbsent(error)) {
        final recovered = await _restartLocalServer();
        if (recovered) return;
        adbServerAbsent.value = true;
        adbDevicesError.value = null;
        return;
      }
      adbServerAbsent.value = false;
      final message = '$error';
      if (message != _loggedAdbError) {
        _loggedAdbError = message;
        log.severe('刷新 ADB 设备列表失败', error, stackTrace);
      }
      adbDevicesError.value = message;
    } finally {
      loadingAdbDevices.value = false;
    }
  }

  Future<bool> _restartLocalServer() async {
    try {
      await manager.ensureLocalAdbServer(restart: true);
    } catch (error, stackTrace) {
      log.severe('启动本机 ADB Server 失败', error, stackTrace);
      return false;
    }
    if (!manager.ownsLocalAdbServer.value && !manager.usingSdkAdbServer.value) {
      return false;
    }
    try {
      adbDevices.assignAll(await _hostClient.devices(long: true));
      _loggedAdbError = null;
      adbServerAbsent.value = false;
      return true;
    } catch (_) {
      return false;
    }
  }

  bool _isAdbServerAbsent(Object error) {
    if (error is! SocketException) return false;
    const absentCodes = <int>{
      61, // macOS ECONNREFUSED
      110, // ETIMEDOUT
      111, // ECONNREFUSED
      10060, // Windows WSAETIMEDOUT
      10061, // Windows WSAECONNREFUSED
      1225, // Windows WSAECONNREFUSED
    };
    final code = error.osError?.errorCode;
    if (code != null && absentCodes.contains(code)) return true;
    final text = error.message.toLowerCase();
    return text.contains('timed out') ||
        text.contains('connection refused') ||
        text.contains('拒绝');
  }

  @override
  void onClose() {
    _devicesRefreshWorker?.dispose();
    _mdnsRefreshWorker?.dispose();
    _intervalWorker?.dispose();
    _adbDeviceRefreshTimer?.cancel();
    _mdnsRefreshGeneration++;
    _mdnsRefreshTimer?.cancel();
    hostController.dispose();
    portController.dispose();
    super.onClose();
  }
}
