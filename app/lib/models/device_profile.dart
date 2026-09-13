/// 已连接设备或历史连接的概要信息。
class DeviceProfile {
  const DeviceProfile({
    required this.serial,
    this.host,
    this.port,
    this.label = '',
  });

  final String serial;
  final String? host;
  final int? port;
  final String label;

  String get displayName => label.isNotEmpty ? label : (host ?? serial);

  String get shortName => host ?? serial;

  String toHistoryKey() => '$host:$port';

  @override
  bool operator ==(Object other) =>
      other is DeviceProfile && other.serial == serial;

  @override
  int get hashCode => serial.hashCode;
}