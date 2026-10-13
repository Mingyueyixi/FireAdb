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

  /// 已经有设备名。地址、序列号、USB 路径不算。
  bool get hasDeviceName {
    final name = label.trim();
    if (name.isEmpty) return false;
    if (name == host || name == serial) return false;
    final listedSerial = adbSerial;
    if (listedSerial != null && name == listedSerial) return false;
    final usb = usbAddress;
    if (usb != null && name == usb) return false;
    return name != connectionAddress;
  }

  /// 界面上的设备名。没有名称时先用地址，读到型号后会换成型号。
  String get displayName {
    if (hasDeviceName) return label.trim();
    final endpointHost = host;
    if (endpointHost != null && endpointHost.isNotEmpty) return endpointHost;
    return serial;
  }

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
