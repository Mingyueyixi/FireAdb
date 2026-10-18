import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:libadb/libadb.dart';

import '../connection/connection_manager.dart';
import '../connection/model/connected_device.dart';
import '../log/app_log.dart';
import '../settings/app_settings_store.dart';
import 'device_scanner.dart';
import 'discovered_devices.dart';

class HomeController extends GetxController with WidgetsBindingObserver {
  static const Duration adbDeviceRefreshInterval = Duration(seconds: 3);

  /// 列表查询往往几十毫秒就结束，图标来不及转完一圈。
  static const Duration _refreshIndicatorHold = Duration(milliseconds: 900);
  final List<({Timer timer, Completer<void> done})> _indicatorHolds =
      <({Timer timer, Completer<void> done})>[];

  HomeController({AdbHostClient? hostClient, this.discoverServices})
    : _injectedHostClient = hostClient;

  final AdbHostClient? _injectedHostClient;

  AdbHostClient get _hostClient =>
      _injectedHostClient ??
      manager.hostClient(connectTimeout: const Duration(milliseconds: 400));

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
  final RxnString scanError = RxnString();
  final RxnString adbDevicesError = RxnString();

  /// 各平台都有本机 ADB Server。Android 没有 USB 传输，列表里不会出现插线设备。
  final RxBool adbServerSupported = true.obs;

  /// 本机 5037 没有 adb server。这是正常情况，不按异常记录。
  final RxBool adbServerAbsent = false.obs;
  String? _loggedAdbError;
  Timer? _adbDeviceRefreshTimer;
  StreamSubscription<List<AdbDeviceInfo>>? _adbTrack;
  Worker? _devicesRefreshWorker;
  Worker? _intervalWorker;
  Worker? _backgroundRefreshWorker;
  var _deviceRefreshGeneration = 0;
  final MdnsBrowser _wirelessBrowser = MdnsBrowser();
  late final DeviceScanner _deviceScanner;
  var _pageVisible = true;
  var _connectionPageOwner = 0;

  /// 窗口还在屏幕上。桌面端失去焦点只是 inactive，扫描继续。
  /// hidden / paused / detached 才算离开前台。
  var _appForeground = true;
  var _refreshing = true;

  /// 工作区等待自动重连时为 true：连接页虽在后台，仍继续扫列表 / mDNS。
  var _reconnectProbe = false;

  ConnectionManager get manager => Get.find<ConnectionManager>();

  AppSettingsStore get _settings => Get.find<AppSettingsStore>();

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
    _deviceScanner = DeviceScanner(
      queryAdb: _queryAdb,
      queryUsb: (_) async {},
      discoverMdns: _discoverRound,
    );
    _wirelessBrowser.onUnsolicited = _onUnsolicitedDiscovery;
    _restoreManualConnection();
    final canListDevices = adbServerSupported.value;
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
    manager.listenLocalMdns((services) {
      if (isClosed || !manager.ownsLocalAdbServer.value) return;
      discovered.assignAll(services);
    });
    manager.listenLocalMdnsError((error, stackTrace) {
      if (isClosed || !manager.ownsLocalAdbServer.value) return;
      if (error == null) {
        scanError.value = null;
        return;
      }
      log.severe('mDNS 设备扫描失败', error, stackTrace);
      scanError.value = '$error';
    });
  }

  /// 连接页在树上且是当前路由时为 true。
  ///
  /// [owner] 用来忽略已经卸下的那一页。新页面先报可见，旧页面再报不可见时，
  /// 不能把还在屏幕上的连接页标成离开。
  void setConnectionPageVisible(bool visible, {int? owner}) {
    if (isClosed) return;
    if (visible && owner != null) _connectionPageOwner = owner;
    if (!visible && owner != null && owner != _connectionPageOwner) return;
    if (_pageVisible == visible) return;
    _pageVisible = visible;
    _syncRefreshGate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = switch (state) {
      AppLifecycleState.resumed || AppLifecycleState.inactive => true,
      AppLifecycleState.hidden ||
      AppLifecycleState.paused ||
      AppLifecycleState.detached => false,
    };
    if (state == AppLifecycleState.detached) {
      unawaited(manager.shutdownLocalAdb());
    }
    if (_appForeground == foreground) return;
    _appForeground = foreground;
    _syncRefreshGate();
  }

  bool get _allowsAutoRefresh =>
      _settings.refreshInBackground.value ||
      _reconnectProbe ||
      (_pageVisible && _appForeground);

  /// 工作区掉线等待重连时打开：即使离开连接页也继续刷新 / mDNS。
  void setReconnectProbe(bool active) {
    if (isClosed) return;
    if (_reconnectProbe == active) return;
    _reconnectProbe = active;
    _syncRefreshGate();
  }

  void _syncRefreshGate() {
    final allow = _allowsAutoRefresh;
    // 等待重连时即使关掉了「自动刷新」，仍要扫列表 / mDNS。
    final refreshEnabled =
        _settings.autoRefreshDevices.value || _reconnectProbe;
    final gateChanged = allow != _refreshing;
    _refreshing = allow;
    _applyDeviceAutoRefresh(refreshEnabled);
    if (!allow || !refreshEnabled || isClosed) return;
    if (!gateChanged && !_reconnectProbe) return;
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
    if (!adbServerSupported.value) return;
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
        adbServerSupported.value;
  }

  void _restoreManualConnection() {
    final endpoint = manager.manualEndpoint();
    if (endpoint == null) return;
    hostController.text = endpoint.$1;
    portController.text = '${endpoint.$2}';
  }

  Future<void> refreshListedDevices({bool includeWirelessScan = false}) {
    return _runDeviceScan(includeMdns: includeWirelessScan);
  }

  /// 手动刷新设备列表：adb server 和无线服务同一轮进行。
  Future<void> refreshDeviceList() async {
    final generation = _deviceRefreshGeneration;
    _adbDeviceRefreshTimer?.cancel();
    _adbDeviceRefreshTimer = null;
    await _runDeviceScan(includeMdns: true, manual: true);
    if (!_deviceRefreshCurrent(generation)) return;
    _scheduleDeviceRefresh(generation);
  }

  Future<void> _runDeviceScan({
    required bool includeMdns,
    bool manual = false,
  }) {
    // 本机 server 的 mDNS 扩展已经在扫，并经 listenLocalMdns 回调。
    // 首页再扫一轮会和它抢结果，设备会在「离线」和发现列表之间跳。
    final homeScansMdns = includeMdns && !manager.ownsLocalAdbServer.value;
    if (includeMdns && manager.ownsLocalAdbServer.value) {
      unawaited(manager.refreshLocalMdns());
    }
    return _deviceScanner.run(
      includeAdb: adbServerSupported.value,
      // USB 由 adb server 扫进 host:devices，首页不再单独枚举。
      includeUsb: false,
      includeMdns: homeScansMdns,
      onStart: (mdnsStarted) {
        if (!mdnsStarted) return;
        scanning.value = true;
        scanError.value = null;
        if (manual) log.info('开始扫描无线设备');
      },
      onListed: _applyListed,
      onMdns: (services) {
        if (isClosed) return;
        discovered.assignAll(services);
      },
      onRoundComplete: (round) => _finishDeviceScan(round, manual: manual),
      isCancelled: () => isClosed,
    );
  }

  void _applyListed(ListedDeviceScan scan) {
    if (isClosed) return;
    if (scan.adbDevices != null) adbDevices.assignAll(scan.adbDevices!);
    if (scan.adbServerAbsent != null) {
      adbServerAbsent.value = scan.adbServerAbsent!;
    }
    if (scan.clearAdbError || scan.adbError != null) {
      adbDevicesError.value = scan.adbError;
    }
    if (scan.adbServerAbsent == false && scan.adbDevices != null) {
      _ensureAdbTrack();
    }
  }

  /// 设备列表只含已经握上手的传输。mDNS 走 [ConnectionManager.listenLocalMdns]。
  Future<List<AdbDeviceInfo>> _listedDevices() {
    return _hostClient.devices(long: true);
  }

  /// `host:track-devices` 推送的是当前完整列表。USB 断线后不用等下一轮轮询。
  void _ensureAdbTrack() {
    if (_adbTrack != null || isClosed || !adbServerSupported.value) return;
    _adbTrack = _hostClient
        .trackDevices(long: true)
        .listen(
          (devices) {
            if (isClosed) return;
            adbDevices.assignAll(devices);
            adbServerAbsent.value = false;
            adbDevicesError.value = null;
          },
          onError: (Object error, StackTrace stackTrace) {
            _adbTrack = null;
            if (isClosed) return;
            if (_isAdbServerAbsent(error)) {
              adbDevices.clear();
              adbServerAbsent.value = true;
              adbDevicesError.value = null;
              return;
            }
            final message = '$error';
            if (message != _loggedAdbError) {
              _loggedAdbError = message;
              log.severe('跟踪 ADB 设备列表失败', error, stackTrace);
            }
          },
          onDone: () {
            _adbTrack = null;
          },
        );
  }

  void _finishDeviceScan(DeviceScanRound round, {required bool manual}) {
    if (!round.includedMdns) return;
    if (round.mdnsError != null) {
      log.severe('mDNS 设备扫描失败', round.mdnsError, round.mdnsStackTrace);
      scanError.value = '${round.mdnsError}';
    } else if (!round.cancelled && !isClosed) {
      discovered.assignAll(round.services);
    }
    if (manual &&
        !round.cancelled &&
        !isClosed &&
        round.mdnsError == null &&
        !round.timedOut) {
      log.info(
        round.services.isEmpty
            ? '扫描结束，没有发现无线设备'
            : '扫描结束，共 ${round.services.length} 个',
      );
    }
    scanning.value = false;
  }

  Future<void> pair(String host, int port, String code) async {
    connecting.value = true;
    try {
      await manager.pairWireless(host, port, code);
    } finally {
      connecting.value = false;
    }
  }

  Future<ConnectedDevice> connect(String host, int port) async {
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

  void _onUnsolicitedDiscovery(List<MdnsService> services) {
    if (isClosed || services.isEmpty) return;
    discovered.assignAll(
      mergeDiscoveredServices(discovered.toList(), services),
    );
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

  Future<MdnsDiscoverResult> _discoverRound(
    void Function(List<MdnsService> services) onUpdate, {
    bool Function()? isCancelled,
  }) async {
    final found = await _discover(onUpdate, isCancelled: isCancelled);
    final timedOut =
        discoverServices == null && _wirelessBrowser.lastRoundExpiredEmpty;
    return MdnsDiscoverResult(services: found, timedOut: timedOut);
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

  Future<void> _queryAdb(void Function(ListedDeviceScan scan) publish) async {
    if (!adbServerSupported.value || loadingAdbDevices.value) return;
    loadingAdbDevices.value = true;
    final started = DateTime.now();
    try {
      final devices = await _listedDevices();
      _loggedAdbError = null;
      publish(
        ListedDeviceScan(
          adbDevices: devices,
          adbServerAbsent: false,
          clearAdbError: true,
        ),
      );
    } catch (error, stackTrace) {
      if (_isAdbServerAbsent(error)) {
        final recovered = await _restartLocalServer();
        if (recovered != null) {
          publish(
            ListedDeviceScan(
              adbDevices: recovered,
              adbServerAbsent: false,
              clearAdbError: true,
            ),
          );
          return;
        }
        publish(
          const ListedDeviceScan(
            adbDevices: <AdbDeviceInfo>[],
            adbServerAbsent: true,
            clearAdbError: true,
          ),
        );
        return;
      }
      final message = '$error';
      if (message != _loggedAdbError) {
        _loggedAdbError = message;
        log.severe('刷新 ADB 设备列表失败', error, stackTrace);
      }
      publish(ListedDeviceScan(adbError: message, adbServerAbsent: false));
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

  Future<List<AdbDeviceInfo>?> _restartLocalServer() async {
    try {
      await manager.ensureLocalAdbServer(restart: true);
    } catch (error, stackTrace) {
      log.severe('启动本机 ADB Server 失败', error, stackTrace);
      return null;
    }
    if (!manager.ownsLocalAdbServer.value && !manager.usingSdkAdbServer.value) {
      return null;
    }
    try {
      return await _listedDevices();
    } catch (_) {
      return null;
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
    unawaited(_adbTrack?.cancel());
    _adbTrack = null;
    _wirelessBrowser.close();
    hostController.dispose();
    portController.dispose();
    unawaited(manager.shutdownLocalAdb());
    super.onClose();
    _cancelIndicatorHolds();
  }
}
