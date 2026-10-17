import 'package:get/get.dart';

import '../connection/connection_manager.dart';
import '../connection/model/connected_device.dart';
import '../home/discovered_devices.dart';
import '../home/home_controller.dart';

/// 按登记序列号 / host:port 重连。CNXN banner 序列号可能为空，不能拿它比对。
Future<ConnectedDevice> reconnectWorkspaceDevice(
  String serial, {
  String? host,
  int? port,
}) async {
  final home = Get.find<HomeController>();
  final manager = Get.find<ConnectionManager>();

  final existing = manager.deviceOf(serial);
  if (existing != null && existing.isConnected) return existing;

  await home.refreshListedDevices(includeWirelessScan: true);

  for (final info in home.adbDevices) {
    if (info.serial != serial || !info.isOnline) continue;
    return home.connectAdbDevice(info);
  }

  final endpoint = adbSerialEndpoint(serial);
  final targetHost = host ?? endpoint?.$1;
  final targetPort = port ?? endpoint?.$2;
  Object? lastError;

  if (targetHost != null && targetPort != null) {
    try {
      return await _connectHostSession(
        home,
        manager,
        host: targetHost,
        port: targetPort,
        expectedSerial: serial,
      );
    } catch (error) {
      lastError = error;
    }
  }

  final wireless = connectableDiscoveredServices(
    discovered: home.discovered,
    adbDevices: home.adbDevices,
    profiles: manager.profiles,
  );
  for (final service in wireless) {
    if (service.addressText.isEmpty || service.port <= 0) continue;
    if (targetHost != null &&
        targetPort != null &&
        !sameHostPort(
          service.addressText,
          service.port,
          targetHost,
          targetPort,
        )) {
      continue;
    }
    try {
      return await _connectHostSession(
        home,
        manager,
        host: service.addressText,
        port: service.port,
        expectedSerial: serial,
      );
    } catch (error) {
      lastError = error;
    }
  }

  throw lastError ??
      StateError('暂时无法重连 $serial，设备可能尚未重新上线');
}

Future<ConnectedDevice> _connectHostSession(
  HomeController home,
  ConnectionManager manager, {
  required String host,
  required int port,
  required String expectedSerial,
}) async {
  final connected = await home.connect(host, port);
  // connect 已返回登记序列号；再按期望键核对，避免连到别的地址。
  final matched = connectedDeviceForEndpoint(
    manager,
    expectedSerial: expectedSerial,
    host: host,
    port: port,
  );
  if (matched != null) return matched;
  if (connected.isConnected) return connected;
  throw StateError('已连上 $host:$port，但会话未登记');
}

/// 直连 TCP 后按登记键查找：期望序列号、host:port，或 profile 地址匹配。
ConnectedDevice? connectedDeviceForEndpoint(
  ConnectionManager manager, {
  required String expectedSerial,
  required String host,
  required int port,
}) {
  final byExpected = manager.deviceOf(expectedSerial);
  if (byExpected != null && byExpected.isConnected) return byExpected;

  final endpointSerial = '$host:$port';
  final byEndpoint = manager.deviceOf(endpointSerial);
  if (byEndpoint != null && byEndpoint.isConnected) return byEndpoint;

  for (final profile in manager.profiles) {
    final profileHost = profile.host;
    final profilePort = profile.port;
    if (profileHost == null || profilePort == null) continue;
    if (!sameHostPort(host, port, profileHost, profilePort)) continue;
    final device = manager.deviceOf(profile.serial);
    if (device != null && device.isConnected) return device;
  }
  return null;
}
