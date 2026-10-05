import 'dart:async';

import 'package:adb_core/adb_core.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app_feedback.dart';
import '../connection/connection_manager.dart';
import '../connection/model/connected_device.dart';

class HomeController extends GetxController {
  static const Duration adbDeviceRefreshInterval = Duration(seconds: 3);

  HomeController({AdbHostClient? hostClient})
    : _hostClient = hostClient ?? AdbHostClient();

  final AdbHostClient _hostClient;
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
  Timer? _adbDeviceRefreshTimer;

  ConnectionManager get manager => Get.find<ConnectionManager>();

  @override
  void onInit() {
    super.onInit();
    unawaited(refreshAdbDevices());
    _adbDeviceRefreshTimer = Timer.periodic(
      adbDeviceRefreshInterval,
      (_) => unawaited(refreshAdbDevices()),
    );
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

  Future<void> scan() async {
    scanning.value = true;
    scanError.value = null;
    try {
      discovered.assignAll(
        await discoverAdbServices(
          serviceTypes: const <String>{
            adbServiceTypeTransport,
            adbServiceTypeConnect,
            adbServiceTypePairing,
          },
        ),
      );
    } catch (error, stackTrace) {
      logAppError('mDNS 设备扫描失败', error, stackTrace);
      scanError.value = '$error';
    } finally {
      scanning.value = false;
    }
  }

  Future<void> refreshAdbDevices() async {
    if (loadingAdbDevices.value) return;
    loadingAdbDevices.value = true;
    adbDevicesError.value = null;
    try {
      adbDevices.assignAll(await _hostClient.devices(long: true));
    } catch (error, stackTrace) {
      logAppError('刷新 ADB 设备列表失败', error, stackTrace);
      adbDevicesError.value = '$error';
    } finally {
      loadingAdbDevices.value = false;
    }
  }

  @override
  void onClose() {
    _adbDeviceRefreshTimer?.cancel();
    hostController.dispose();
    portController.dispose();
    super.onClose();
  }
}
