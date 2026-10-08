import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:libadb/libadb.dart';

import '../app_feedback.dart';
import '../connection/connection_manager.dart';
import '../connection/model/connected_device.dart';

class HomeController extends GetxController {
  static const Duration adbDeviceRefreshInterval = Duration(seconds: 3);

  HomeController({
    AdbHostClient? hostClient,
    Future<List<UsbAdbDevice>> Function()? listUsbDevices,
    bool? usbSupported,
  }) : _hostClient =
           hostClient ??
           AdbHostClient(connectTimeout: const Duration(milliseconds: 400)),
       _listUsbDevices = listUsbDevices ?? listUsbAdbDevices,
       usbSupported = usbSupported ?? libadbUsbSupported;

  final AdbHostClient _hostClient;
  final Future<List<UsbAdbDevice>> Function() _listUsbDevices;
  final bool usbSupported;

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

  ConnectionManager get manager => Get.find<ConnectionManager>();

  @override
  void onInit() {
    super.onInit();
    if (!adbServerSupported.value && !usbSupported) return;
    _adbDeviceRefreshTimer = Timer.periodic(adbDeviceRefreshInterval, (_) {
      _refreshListedDevices();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (isClosed) return;
      _refreshListedDevices();
    });
  }

  bool get showDirectUsbList =>
      usbSupported && !manager.ownsLocalAdbServer.value;

  void _refreshListedDevices() {
    if (adbServerSupported.value) unawaited(refreshAdbDevices());
    if (showDirectUsbList) unawaited(refreshUsbDevices());
  }

  Future<AdbDevice> connectUsb(UsbAdbDevice device) async {
    connecting.value = true;
    try {
      return await manager.connectUsb(device);
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
        logAppError('刷新 USB 设备列表失败', error, stackTrace);
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
        logAppError('刷新 ADB 设备列表失败', error, stackTrace);
      }
      adbDevicesError.value = message;
    } finally {
      loadingAdbDevices.value = false;
    }
  }

  Future<bool> _restartLocalServer() async {
    try {
      await manager.ensureLocalAdbServer();
    } catch (error, stackTrace) {
      logAppError('启动本机 ADB Server 失败', error, stackTrace);
      return false;
    }
    if (!manager.ownsLocalAdbServer.value) return false;
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
    _adbDeviceRefreshTimer?.cancel();
    hostController.dispose();
    portController.dispose();
    super.onClose();
  }
}
