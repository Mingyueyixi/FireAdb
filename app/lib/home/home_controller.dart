import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:libadb/libadb.dart';

import '../connection/connection_manager.dart';
import '../connection/model/connected_device.dart';
import '../log/app_log.dart';
import '../settings/app_settings_store.dart';
import 'discovered_devices.dart';

class HomeController extends GetxController with WidgetsBindingObserver {
  static const Duration adbDeviceRefreshInterval = Duration(seconds: 3);

  /// 列表查询往往几十毫秒就结束，图标来不及转完一圈。
  static const Duration _refreshIndicatorHold = Duration(milliseconds: 900);
  final List<({Timer timer, Completer<void> done})> _indicatorHolds =
      <({Timer timer, Completer<void> done})>[];

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
  Worker? _devicesRefreshWorker;
  Worker? _intervalWorker;
  Worker? _backgroundRefreshWorker;
  var _deviceRefreshGeneration = 0;
  final Map<String, DateTime> _discoveredSeenAt = <String, DateTime>{};
  final MdnsBrowser _wirelessBrowser = MdnsBrowser();
  var _pageVisible = true;
  var _appResumed = true;
  var _refreshing = true;

  ConnectionManager get manager => Get.find<ConnectionManager>();

  AppSettingsStore get _settings => Get.find<AppSettingsStore>();

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
    _restoreManualConnection();
    final canListDevices = adbServerSupported.value || usbSupported;
    if (canListDevices) {
      _applyDeviceAutoRefresh(_settings.autoRefreshDevices.value);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (isClosed) return;
        unawaited(_refreshNowAndReschedule());
      });
    }
    _devicesRefreshWorker = ever<bool>(
      _settings.autoRefreshDevices,
      _applyDeviceAutoRefresh,
    );
    _intervalWorker = ever<int>(_settings.autoRefreshIntervalSeconds, (_) {
      _applyDeviceAutoRefresh(_settings.autoRefreshDevices.value);
    });
    _backgroundRefreshWorker = ever<bool>(
      _settings.refreshInBackground,
      (_) => _syncRefreshGate(),
    );
  }

  /// 连接页在树上且是当前路由时为 true。
  void setConnectionPageVisible(bool visible) {
    if (isClosed || _pageVisible == visible) return;
    _pageVisible = visible;
    _syncRefreshGate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (_appResumed == resumed) return;
    _appResumed = resumed;
    _syncRefreshGate();
  }

  bool get _allowsAutoRefresh =>
      _settings.refreshInBackground.value || (_pageVisible && _appResumed);

  void _syncRefreshGate() {
    final allow = _allowsAutoRefresh;
    if (allow == _refreshing) return;
    _refreshing = allow;
    _applyDeviceAutoRefresh(_settings.autoRefreshDevices.value);
    if (!allow || !_settings.autoRefreshDevices.value || isClosed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (isClosed || !_allowsAutoRefresh) return;
      unawaited(_refreshNowAndReschedule());
    });
  }

  Duration get _refreshInterval =>
      Duration(seconds: _settings.autoRefreshIntervalSeconds.value);

  void _applyDeviceAutoRefresh(bool enabled) {
    _adbDeviceRefreshTimer?.cancel();
    _adbDeviceRefreshTimer = null;
    _deviceRefreshGeneration++;
    if (!enabled || !_allowsAutoRefresh || isClosed) return;
    if (!adbServerSupported.value && !usbSupported) return;
    // 固定周期会从本轮开始计时。扫描要数秒，转圈一停下一轮就到了。
    // 这里改成上一轮结束后再等设定的间隔。
    _scheduleDeviceRefresh(_deviceRefreshGeneration);
  }

  void _scheduleDeviceRefresh(int generation) {
    _adbDeviceRefreshTimer?.cancel();
    _adbDeviceRefreshTimer = Timer(_refreshInterval, () {
      unawaited(_runScheduledRefresh(generation));
    });
  }

  Future<void> _runScheduledRefresh(int generation) async {
    if (!_deviceRefreshCurrent(generation)) return;
    await refreshListedDevices(includeWirelessScan: true);
    if (!_deviceRefreshCurrent(generation)) return;
    _scheduleDeviceRefresh(generation);
  }

  Future<void> _refreshNowAndReschedule() async {
    final generation = _deviceRefreshGeneration;
    _adbDeviceRefreshTimer?.cancel();
    _adbDeviceRefreshTimer = null;
    await refreshListedDevices(includeWirelessScan: true);
    if (!_deviceRefreshCurrent(generation)) return;
    _scheduleDeviceRefresh(generation);
  }

  bool _deviceRefreshCurrent(int generation) {
    return generation == _deviceRefreshGeneration &&
        !isClosed &&
        _settings.autoRefreshDevices.value &&
        _allowsAutoRefresh &&
        (adbServerSupported.value || usbSupported);
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

  Future<void> refreshListedDevices({bool includeWirelessScan = false}) {
    final pending = <Future<void>>[];
    if (adbServerSupported.value) pending.add(refreshAdbDevices());
    if (showDirectUsbList) {
      pending.add(refreshUsbDevices());
    } else {
      usbDevices.clear();
    }
    if (includeWirelessScan && !scanning.value) {
      pending.add(scan(automatic: true));
    }
    return Future.wait(pending);
  }

  /// 手动刷新设备列表：adb server、USB，以及无线服务。
  Future<void> refreshDeviceList() async {
    final generation = _deviceRefreshGeneration;
    _adbDeviceRefreshTimer?.cancel();
    _adbDeviceRefreshTimer = null;
    await refreshListedDevices();
    await scan();
    if (!_deviceRefreshCurrent(generation)) return;
    _scheduleDeviceRefresh(generation);
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
    final kept = List<MdnsService>.of(discovered);
    var cancelled = false;
    if (!automatic) log.info('开始扫描无线设备');
    try {
      final found = await _discover(
        (services) {
          discovered.assignAll(mergeDiscoveredServices(kept, services));
          if (!automatic) {
            log.info(
              '扫描到 ${services.length} 个：${services.map((service) => service.endpointText).join('，')}',
            );
          }
        },
        isCancelled: automatic
            ? () {
                final stop = isClosed || !_allowsAutoRefresh;
                if (stop) cancelled = true;
                return stop;
              }
            : null,
      );
      final expiredEmpty =
          discoverServices == null && _wirelessBrowser.lastRoundExpiredEmpty;
      if (cancelled || isClosed || expiredEmpty) {
        discovered.assignAll(kept);
      } else {
        discovered.assignAll(
          retainRecentDiscoveries(
            previous: kept,
            found: found,
            seenAt: _discoveredSeenAt,
            now: DateTime.now(),
          ),
        );
      }
      if (!automatic && !cancelled && !expiredEmpty) {
        log.info(found.isEmpty ? '扫描结束，没有发现无线设备' : '扫描结束，共 ${found.length} 个');
      }
    } catch (error, stackTrace) {
      log.severe('mDNS 设备扫描失败', error, stackTrace);
      scanError.value = '$error';
      discovered.assignAll(kept);
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
    final browser = stopWhen == null
        ? _wirelessBrowser
        : MdnsBrowser(timeout: timeout ?? kMdnsInterfaceTimeout);
    return browser.discover(
      serviceTypes: const <String>{
        adbServiceTypeTransport,
        adbServiceTypeConnect,
        adbServiceTypePairing,
      },
      onUpdate: onUpdate,
      stopWhen: stopWhen,
      requeryInterval: const Duration(seconds: 1),
      isCancelled: isCancelled,
      reuseLanSockets: stopWhen == null,
    );
  }

  Future<void> refreshUsbDevices() async {
    if (!showDirectUsbList || loadingUsbDevices.value) return;
    loadingUsbDevices.value = true;
    final started = DateTime.now();
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
      await _keepRefreshIndicator(started);
      if (!isClosed) loadingUsbDevices.value = false;
    }
  }

  Future<void> refreshAdbDevices() async {
    if (!adbServerSupported.value || loadingAdbDevices.value) return;
    loadingAdbDevices.value = true;
    final started = DateTime.now();
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
      await _keepRefreshIndicator(started);
      if (!isClosed) loadingAdbDevices.value = false;
    }
  }

  Future<void> _keepRefreshIndicator(DateTime started) {
    final remaining =
        _refreshIndicatorHold - DateTime.now().difference(started);
    if (remaining <= Duration.zero || isClosed) return Future<void>.value();
    final done = Completer<void>();
    late final ({Timer timer, Completer<void> done}) hold;
    final timer = Timer(remaining, () {
      _indicatorHolds.remove(hold);
      if (!done.isCompleted) done.complete();
    });
    hold = (timer: timer, done: done);
    _indicatorHolds.add(hold);
    return done.future;
  }

  void _cancelIndicatorHolds() {
    for (final hold in List<({Timer timer, Completer<void> done})>.of(
      _indicatorHolds,
    )) {
      hold.timer.cancel();
      if (!hold.done.isCompleted) hold.done.complete();
    }
    _indicatorHolds.clear();
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
    WidgetsBinding.instance.removeObserver(this);
    _devicesRefreshWorker?.dispose();
    _intervalWorker?.dispose();
    _backgroundRefreshWorker?.dispose();
    _deviceRefreshGeneration++;
    _adbDeviceRefreshTimer?.cancel();
    _wirelessBrowser.close();
    hostController.dispose();
    portController.dispose();
    super.onClose();
    _cancelIndicatorHolds();
  }
}
