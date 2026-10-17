import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:libadb/libadb.dart';

import '../apps/apps_controller.dart';
import '../capture/screenrecord_controller.dart';
import '../capture/screenshot_controller.dart';
import '../connection/connection_manager.dart';
import '../connection/model/device_profile.dart';
import '../files/files_controller.dart';
import '../home/discovered_devices.dart';
import '../home/home_controller.dart';
import '../log/app_log.dart';
import 'data/feature_spec.dart';
import 'workspace_reconnect.dart';

/// 工作区当前看哪台设备，以及每台设备各自停在哪个功能。
///
/// 宽屏和窄屏共用 [featureCacheKey] 指向的那一份页面，避免同一功能出现两套状态。
class WorkspaceController extends GetxController {
  WorkspaceController(String serial) : selectedSerial = serial.obs {
    if (serial.isNotEmpty) roster.add(serial);
  }

  final RxString selectedSerial;
  final GlobalKey featureCacheKey = GlobalKey();
  final RxBool narrowFeatureOpen = false.obs;
  final Map<String, String> _featureBySerial = <String, String>{};
  final RxString _currentFeature = kOverviewFeatureId.obs;

  /// 当前选中设备会话恢复（重连）后递增，用来刷新正在看的功能页。
  final RxInt sessionEpoch = 0.obs;

  /// 任意一台设备重连成功时写成它的序列号，离屏详情页据此刷新。
  final RxString restoredSerial = ''.obs;

  /// 本次工作区出现过的设备。断线后仍留在侧栏，不随已连接表摘掉。
  final RxList<String> roster = <String>[].obs;
  final Map<String, DeviceProfile> _rosterProfiles = <String, DeviceProfile>{};

  /// 意外掉线、等待重新上线的设备。不限于当前正在看的那一台。
  final Map<String, _PendingReconnect> _pending = <String, _PendingReconnect>{};
  var _autoConnecting = false;
  Worker? _adbDevicesWorker;
  Worker? _discoveredWorker;

  String get currentFeatureId => _currentFeature.value;

  bool get allowAutoReconnect => _pending.isNotEmpty;

  DeviceProfile? rosterProfile(String serial) => _rosterProfiles[serial];

  String? reconnectHostFor(String serial) =>
      _pending[serial]?.host ?? _rosterProfiles[serial]?.host;

  int? reconnectPortFor(String serial) =>
      _pending[serial]?.port ?? _rosterProfiles[serial]?.port;

  @override
  void onInit() {
    super.onInit();
    if (Get.isRegistered<ConnectionManager>()) {
      for (final profile in Get.find<ConnectionManager>().profiles) {
        rememberProfile(profile);
      }
    }
    if (Get.isRegistered<HomeController>()) {
      final home = Get.find<HomeController>();
      _adbDevicesWorker = ever<List<AdbDeviceInfo>>(
        home.adbDevices,
        (_) => unawaited(_tryAutoReconnect()),
      );
      _discoveredWorker = ever<List<MdnsService>>(
        home.discovered,
        (_) => unawaited(_tryAutoReconnect()),
      );
    }
  }

  @override
  void onClose() {
    _adbDevicesWorker?.dispose();
    _discoveredWorker?.dispose();
    _setReconnectProbe(false);
    super.onClose();
  }

  void selectSerial(String serial) {
    if (serial == selectedSerial.value) return;
    _featureBySerial[selectedSerial.value] = _currentFeature.value;
    selectedSerial.value = serial;
    _currentFeature.value = _featureBySerial[serial] ?? kOverviewFeatureId;
  }

  void selectFeature(String featureId) {
    if (featureId == _currentFeature.value) return;
    _featureBySerial[selectedSerial.value] = featureId;
    _currentFeature.value = featureId;
  }

  void openFeature(String featureId) {
    selectFeature(featureId);
    narrowFeatureOpen.value = true;
  }

  void closeFeature() => narrowFeatureOpen.value = false;

  void rememberProfile(DeviceProfile profile) {
    if (profile.serial.isEmpty) return;
    _rosterProfiles[profile.serial] = profile;
    if (roster.contains(profile.serial)) return;
    roster.add(profile.serial);
  }

  /// 掉线后留下这台设备，并排队等它重新上线。不改当前正在看的设备。
  void noteUnexpectedDisconnect(String serial, {DeviceProfile? profile}) {
    if (serial.isEmpty) return;
    if (profile != null) {
      rememberProfile(profile);
    } else if (!roster.contains(serial)) {
      roster.add(serial);
    }
    final endpoint = adbSerialEndpoint(serial);
    final host = profile?.host ?? endpoint?.$1;
    final port = profile?.port ?? endpoint?.$2;
    final listedOnline = Get.isRegistered<HomeController>() &&
        Get.find<HomeController>().adbDevices.any(
          (device) => device.serial == serial && device.isOnline,
        );
    _pending[serial] = _PendingReconnect(
      host: host,
      port: port,
      waitUntilAbsent: listedOnline,
    );
    if (Get.isRegistered<HomeController>() && host != null && port != null) {
      final home = Get.find<HomeController>();
      home.discovered.removeWhere(
        (service) =>
            isConnectableAdbService(service) &&
            service.addressText.isNotEmpty &&
            service.port > 0 &&
            sameHostPort(service.addressText, service.port, host, port),
      );
    }
    if (listedOnline) {
      log.info('工作区等待重连：先等 $serial 从设备列表消失');
    } else if (host != null) {
      log.info('工作区等待重连：等待 mDNS 再次发现 $host:$port');
    }
    _setReconnectProbe(true);
    unawaited(_tryAutoReconnect());
  }

  void disarmAutoReconnect() {
    _pending.clear();
    _setReconnectProbe(false);
  }

  /// 某台设备重连成功后刷新它自己的功能页，其它等待中的设备继续重连。
  void notifySessionRestored(String serial) {
    if (serial.isEmpty) return;
    _dropPending(serial);
    if (Get.isRegistered<ConnectionManager>()) {
      final profile = Get.find<ConnectionManager>().profileOf(serial);
      if (profile != null) rememberProfile(profile);
    }
    final selected = selectedSerial.value;
    if (selected != serial && _sameEndpoint(selected, serial)) {
      _retargetRoster(selected, serial);
      selectSerial(serial);
    }
    if (restoredSerial.value == serial) restoredSerial.value = '';
    restoredSerial.value = serial;
    if (selectedSerial.value == serial) sessionEpoch.value++;
    if (Get.isRegistered<AppsController>(tag: serial)) {
      unawaited(Get.find<AppsController>(tag: serial).reload());
    }
    if (Get.isRegistered<FilesController>(tag: serial)) {
      unawaited(Get.find<FilesController>(tag: serial).reload());
    }
    if (Get.isRegistered<ScreenshotController>(tag: serial)) {
      unawaited(Get.find<ScreenshotController>(tag: serial).reload());
    }
    if (Get.isRegistered<ScreenrecordController>(tag: serial)) {
      unawaited(Get.find<ScreenrecordController>(tag: serial).reload());
    }
    if (_pending.isEmpty) _setReconnectProbe(false);
  }

  Future<void> _tryAutoReconnect() async {
    if (_autoConnecting || _pending.isEmpty) return;
    if (!Get.isRegistered<HomeController>()) return;
    final home = Get.find<HomeController>();
    final manager = Get.find<ConnectionManager>();

    String? serial;
    _PendingReconnect? pending;
    for (final entry in _pending.entries.toList()) {
      if (_alreadyConnected(manager, entry.key, entry.value)) {
        _pending.remove(entry.key);
        continue;
      }
      if (_readyToReconnect(home, entry.key, entry.value)) {
        serial = entry.key;
        pending = entry.value;
        break;
      }
    }
    if (serial == null || pending == null) return;

    _autoConnecting = true;
    try {
      log.info(
        '工作区自动重连 $serial'
        '${pending.host != null ? ' (${pending.host}:${pending.port})' : ''}',
      );
      final connected = await reconnectWorkspaceDevice(
        serial,
        host: pending.host,
        port: pending.port,
      );
      if (connected.serial != serial) {
        _retargetRoster(serial, connected.serial);
        if (selectedSerial.value == serial) selectSerial(connected.serial);
      }
      _pending.remove(serial);
    } catch (error, stackTrace) {
      log.info('工作区自动重连失败 $serial', error, stackTrace);
      return;
    } finally {
      _autoConnecting = false;
    }
    if (_pending.isEmpty) {
      _setReconnectProbe(false);
      return;
    }
    unawaited(_tryAutoReconnect());
  }

  bool _readyToReconnect(
    HomeController home,
    String serial,
    _PendingReconnect pending,
  ) {
    final listedOnline = home.adbDevices.any(
      (device) => device.serial == serial && device.isOnline,
    );
    final discoveredOnline = _endpointVisible(
      home,
      host: pending.host,
      port: pending.port,
    );
    if (pending.waitUntilAbsent) {
      if (!listedOnline && !discoveredOnline) {
        pending.waitUntilAbsent = false;
        log.info('工作区等待重连：设备已离开列表 $serial');
      }
      return false;
    }
    if (listedOnline) return true;
    if (pending.host != null && pending.port != null && discoveredOnline) {
      return true;
    }
    return false;
  }

  bool _alreadyConnected(
    ConnectionManager manager,
    String serial,
    _PendingReconnect pending,
  ) {
    final current = manager.deviceOf(serial);
    if (current != null && current.isConnected) return true;
    final host = pending.host;
    final port = pending.port;
    if (host == null || port == null) return false;
    return connectedDeviceForEndpoint(
          manager,
          expectedSerial: serial,
          host: host,
          port: port,
        ) !=
        null;
  }

  bool _endpointVisible(
    HomeController home, {
    required String? host,
    required int? port,
  }) {
    if (host == null || port == null) return false;
    for (final service in home.discovered) {
      if (!isConnectableAdbService(service)) continue;
      if (service.addressText.isEmpty || service.port <= 0) continue;
      if (sameHostPort(service.addressText, service.port, host, port)) {
        return true;
      }
    }
    for (final device in home.adbDevices) {
      final endpoint = adbSerialEndpoint(device.serial);
      if (endpoint == null || !device.isOnline) continue;
      if (sameHostPort(host, port, endpoint.$1, endpoint.$2)) return true;
    }
    return false;
  }

  void _dropPending(String serial) {
    _pending.remove(serial);
    final restored = adbSerialEndpoint(serial);
    if (restored == null) return;
    _pending.removeWhere((key, pending) {
      if (_sameEndpoint(key, serial)) return true;
      final host = pending.host;
      final port = pending.port;
      return host != null &&
          port != null &&
          sameHostPort(host, port, restored.$1, restored.$2);
    });
  }

  bool _sameEndpoint(String left, String right) {
    final a = adbSerialEndpoint(left);
    final b = adbSerialEndpoint(right);
    if (a == null || b == null) return false;
    return sameHostPort(a.$1, a.$2, b.$1, b.$2);
  }

  void _retargetRoster(String from, String to) {
    if (from == to || to.isEmpty) return;
    final profile = _rosterProfiles.remove(from);
    if (profile != null) {
      _rosterProfiles[to] = DeviceProfile(
        serial: to,
        host: profile.host,
        port: profile.port,
        label: profile.label,
        adbSerial: profile.adbSerial,
        usbAddress: profile.usbAddress,
      );
    }
    final index = roster.indexOf(from);
    if (index >= 0) {
      roster[index] = to;
    } else if (!roster.contains(to)) {
      roster.add(to);
    }
    final feature = _featureBySerial.remove(from);
    if (feature != null) _featureBySerial[to] = feature;
  }

  void _setReconnectProbe(bool active) {
    if (!Get.isRegistered<HomeController>()) return;
    Get.find<HomeController>().setReconnectProbe(active);
  }
}

class _PendingReconnect {
  _PendingReconnect({
    required this.host,
    required this.port,
    required this.waitUntilAbsent,
  });

  final String? host;
  final int? port;
  var waitUntilAbsent = false;
}
