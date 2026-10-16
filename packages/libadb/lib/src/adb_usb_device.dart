/// 一台插在本机、带有 ADB 接口的 USB 设备。
class UsbAdbDevice {
  const UsbAdbDevice({
    required this.address,
    required this.portPath,
    required this.vendorId,
    required this.productId,
    required this.interfaceNumber,
    required this.endpointIn,
    required this.endpointOut,
    required this.maxPacketSize,
    this.manufacturer,
    this.productName,
    this.serialNumber,
  });

  /// 稳定地址，例如 `usb:1-4.2`。
  final String address;

  /// 总线和端口路径，例如 `1-4.2`。重新枚举后用它找回同一台设备。
  final String portPath;

  final int vendorId;
  final int productId;
  final int interfaceNumber;
  final int endpointIn;
  final int endpointOut;
  final int maxPacketSize;
  final String? manufacturer;
  final String? productName;
  final String? serialNumber;

  String get title {
    final name = productName?.trim();
    if (name != null && name.isNotEmpty) return name;
    return 'USB ${_hex(vendorId)}:${_hex(productId)}';
  }

  Map<String, Object?> toRow() {
    return <String, Object?>{
      'address': address,
      'portPath': portPath,
      'vendorId': vendorId,
      'productId': productId,
      'interfaceNumber': interfaceNumber,
      'endpointIn': endpointIn,
      'endpointOut': endpointOut,
      'maxPacketSize': maxPacketSize,
      'manufacturer': manufacturer,
      'productName': productName,
      'serialNumber': serialNumber,
    };
  }

  static UsbAdbDevice fromRow(Map<String, Object?> row) {
    return UsbAdbDevice(
      address: row['address']! as String,
      portPath: row['portPath']! as String,
      vendorId: row['vendorId']! as int,
      productId: row['productId']! as int,
      interfaceNumber: row['interfaceNumber']! as int,
      endpointIn: row['endpointIn']! as int,
      endpointOut: row['endpointOut']! as int,
      maxPacketSize: row['maxPacketSize']! as int,
      manufacturer: row['manufacturer'] as String?,
      productName: row['productName'] as String?,
      serialNumber: row['serialNumber'] as String?,
    );
  }
}

String _hex(int value) => value.toRadixString(16).padLeft(4, '0');

class AdbUsbException implements Exception {
  AdbUsbException(this.message);

  final String message;

  @override
  String toString() => message;
}
