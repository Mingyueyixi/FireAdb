import 'package:libadb/libadb.dart';

import '../connection/model/device_profile.dart';

/// 扫描到、并且点一下就能连接的 ADB 服务。配对服务不在这里。
bool isConnectableAdbService(MdnsService service) {
  return service.serviceType == adbServiceTypeConnect ||
      service.serviceType == adbServiceTypeTransport;
}

/// 设备列表里还没有的可连接服务。地址和端口相同的只留已有的那一行。
List<MdnsService> connectableDiscoveredServices({
  required Iterable<MdnsService> discovered,
  required Iterable<AdbDeviceInfo> adbDevices,
  required Iterable<DeviceProfile> profiles,
}) {
  return <MdnsService>[
    for (final service in discovered)
      if (isConnectableAdbService(service) &&
          service.addressText.isNotEmpty &&
          service.port > 0 &&
          !discoveredServiceAlreadyListed(
            service,
            adbDevices: adbDevices,
            profiles: profiles,
          ))
        service,
  ];
}

bool discoveredServiceAlreadyListed(
  MdnsService service, {
  required Iterable<AdbDeviceInfo> adbDevices,
  required Iterable<DeviceProfile> profiles,
}) {
  for (final device in adbDevices) {
    final endpoint = adbSerialEndpoint(device.serial);
    if (endpoint != null &&
        sameHostPort(
          service.addressText,
          service.port,
          endpoint.$1,
          endpoint.$2,
        )) {
      return true;
    }
  }
  for (final profile in profiles) {
    final host = profile.host;
    final port = profile.port;
    if (host != null &&
        port != null &&
        sameHostPort(service.addressText, service.port, host, port)) {
      return true;
    }
  }
  return false;
}

/// `host:port` 或 `[ipv6]:port`。端口不合法时返回空。
(String, int)? adbSerialEndpoint(String serial) {
  final separator = serial.lastIndexOf(':');
  if (separator < 1 || separator == serial.length - 1) return null;
  final port = int.tryParse(serial.substring(separator + 1));
  if (port == null || port <= 0 || port > 65535) return null;
  return (normalizeHost(serial.substring(0, separator)), port);
}

bool sameHostPort(String host, int port, String otherHost, int otherPort) {
  return port == otherPort && normalizeHost(host) == normalizeHost(otherHost);
}

String normalizeHost(String host) {
  var value = host.trim();
  if (value.startsWith('[') && value.endsWith(']') && value.length > 2) {
    value = value.substring(1, value.length - 1);
  }
  return value.toLowerCase();
}

/// 刷新过程中把已经显示的服务留在列表里，避免新扫描还没应答时整行消失。
List<MdnsService> mergeDiscoveredServices(
  Iterable<MdnsService> kept,
  Iterable<MdnsService> incoming,
) {
  final seen = <String>{
    for (final service in incoming) discoveredServiceKey(service),
  };
  return <MdnsService>[
    ...incoming,
    for (final service in kept)
      if (seen.add(discoveredServiceKey(service))) service,
  ];
}

String discoveredServiceKey(MdnsService service) =>
    '${service.serviceType}\n${normalizeHost(service.addressText)}\n${service.port}';

/// 一轮查询里再次出现的服务留下。
///
/// [heard] 为真时，这一轮的结果就是当前列表，没再出现的服务马上去掉。
/// 采集时间到且没有应答时，连续 [goneAfter] 轮没再出现才去掉，避免一包丢失就把还在的设备抹掉。
List<MdnsService> settleDiscoveredServices({
  required Iterable<MdnsService> current,
  required Iterable<MdnsService> confirmed,
  required Map<String, int> misses,
  required bool heard,
  int goneAfter = 2,
}) {
  if (heard) {
    misses.clear();
    return List<MdnsService>.of(confirmed);
  }
  final confirmedKeys = <String>{
    for (final service in confirmed) discoveredServiceKey(service),
  };
  final next = <MdnsService>[];
  final live = <String>{};
  for (final service in current) {
    final key = discoveredServiceKey(service);
    if (confirmedKeys.contains(key)) {
      misses.remove(key);
      next.add(service);
      live.add(key);
      continue;
    }
    final count = (misses[key] ?? 0) + 1;
    if (count >= goneAfter) {
      misses.remove(key);
      continue;
    }
    misses[key] = count;
    next.add(service);
    live.add(key);
  }
  misses.removeWhere((key, _) => !live.contains(key));
  return next;
}

String discoveredServiceTitle(MdnsService service) {
  final name = service.txt['name']?.replaceAll('_', ' ');
  if (name != null && name.isNotEmpty) return name;
  if (service.instanceName.isNotEmpty) return service.instanceName;
  return service.endpointText;
}
