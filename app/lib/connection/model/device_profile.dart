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

  String get historyKey {
    if (host != null && port != null) return 'tcp:$host:$port';
    return 'adb:${adbSerial ?? serial}';
  }

  String toHistoryKey() {
    if (host != null && port != null) {
      final formattedHost = host!.contains(':') ? '[$host]' : host!;
      return '$formattedHost:$port';
    }
    return displayName;
  }

  @override
  bool operator ==(Object other) =>
      other is DeviceProfile && other.serial == serial;

  @override
  int get hashCode => serial.hashCode;
}
