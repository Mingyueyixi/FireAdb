import 'package:libadb/libadb.dart';

import '../connection/model/device_profile.dart';

/// 扫描到、并且点一下就能连接的 ADB 服务。配对服务不在这里。
bool isConnectableAdbService(MdnsService service) {
  return service.serviceType == adbServiceTypeConnect ||
      service.serviceType == adbServiceTypeTransport;
}

/// 设备列表里还没有的可连接服务。地址和端口相同的只留已有的那一行。
///
/// [localAddresses] 为本机网卡地址集合：127.0.0.1 与本机任一接口 IP
/// 是同一台设备（同一 adb server），带端口相同即去重，避免手动连接
/// 127.0.0.1 后设备列表出现两行同一设备。
List<MdnsService> connectableDiscoveredServices({
  required Iterable<MdnsService> discovered,
  required Iterable<AdbDeviceInfo> adbDevices,
  required Iterable<DeviceProfile> profiles,
  Set<String> localAddresses = const {},
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
            localAddresses: localAddresses,
          ))
        service,
  ];
}

bool discoveredServiceAlreadyListed(
  MdnsService service, {
  required Iterable<AdbDeviceInfo> adbDevices,
  required Iterable<DeviceProfile> profiles,
  Set<String> localAddresses = const {},
}) {
  for (final device in adbDevices) {
    final endpoint = adbSerialEndpoint(device.serial);
    if (endpoint != null &&
        sameHostPort(
          service.addressText,
          service.port,
          endpoint.$1,
          endpoint.$2,
          localAddresses: localAddresses,
        )) {
      return true;
    }
  }
  for (final profile in profiles) {
    final host = profile.host;
    final port = profile.port;
    if (host != null &&
        port != null &&
        sameHostPort(
          service.addressText,
          service.port,
          host,
          port,
          localAddresses: localAddresses,
        )) {
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

bool sameHostPort(
  String host,
  int port,
  String otherHost,
  int otherPort, {
  Set<String> localAddresses = const {},
}) {
  if (port != otherPort) return false;
  final a = normalizeHost(host);
  final b = normalizeHost(otherHost);
  if (a == b) return true;
  // 本机地址等价：127.0.0.1 与本机任一接口 IP 指向同一台设备。
  return localAddresses.isNotEmpty &&
      localAddresses.contains(a) &&
      localAddresses.contains(b);
}

String normalizeHost(String host) {
  var value = host.trim();
  if (value.startsWith('[') && value.endsWith(']') && value.length > 2) {
    value = value.substring(1, value.length - 1);
  }
  return value.toLowerCase();
}

/// 窗口结束后迟到的应答并进列表；正式扫描结束时会整表替换。
List<MdnsService> mergeDiscoveredServices(
  Iterable<MdnsService> current,
  Iterable<MdnsService> incoming,
) {
  final seen = <String>{
    for (final service in incoming) _discoveredServiceKey(service),
  };
  return <MdnsService>[
    ...incoming,
    for (final service in current)
      if (seen.add(_discoveredServiceKey(service))) service,
  ];
}

String _discoveredServiceKey(MdnsService service) =>
    '${service.serviceType}\n${normalizeHost(service.addressText)}\n${service.port}';

String discoveredServiceTitle(MdnsService service) {
  final name = service.txt['name']?.replaceAll('_', ' ');
  if (name != null && name.isNotEmpty) return name;
  if (service.instanceName.isNotEmpty) return service.instanceName;
  return service.endpointText;
}
