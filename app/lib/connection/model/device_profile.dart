/// 已连接设备或历史连接的概要信息。
class DeviceProfile {
  const DeviceProfile({
    required this.serial,
    this.host,
    this.port,
    this.label = '',
    this.adbSerial,
    this.usbAddress,
  });

  final String serial;
  final String? host;
  final int? port;
  final String label;
  final String? adbSerial;

  /// 直接打开的 USB 设备地址，例如 `usb:1-4.2`。
  final String? usbAddress;

  String get displayName => label.isNotEmpty ? label : (host ?? serial);

  String get shortName => host ?? serial;

  /// 用来区分同名设备的连接地址：网络是主机和端口，USB 是序列号或总线地址。
  String get connectionAddress {
    final endpointHost = host;
    final endpointPort = port;
    if (endpointHost != null && endpointPort != null) {
      final formattedHost = endpointHost.contains(':')
          ? '[$endpointHost]'
          : endpointHost;
      return '$formattedHost:$endpointPort';
    }
    final serialAddress = adbSerial;
    if (serialAddress != null && serialAddress.isNotEmpty) {
      return serialAddress;
    }
    final usb = usbAddress;
    if (usb != null && usb.isNotEmpty) return usb;
    return serial;
  }

  String get historyKey {
    if (host != null && port != null) return 'tcp:$host:$port';
    return 'adb:${adbSerial ?? serial}';
  }

  @override
  bool operator ==(Object other) =>
      other is DeviceProfile && other.serial == serial;

  @override
  int get hashCode => serial.hashCode;
}
