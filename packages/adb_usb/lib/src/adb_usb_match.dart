/// ADB 在 USB 接口上的固定标识，对应 AOSP `adb.h` 与 `is_adb_interface`。
const int kAdbUsbClass = 0xff;
const int kAdbUsbSubclass = 0x42;
const int kAdbUsbProtocol = 0x01;

/// Debug Capability 使用同一套 ADB 协议，类别不同。
const int kAdbDbcClass = 0xdc;
const int kAdbDbcSubclass = 0x02;

const int kUsbTransferTypeMask = 0x03;
const int kUsbTransferTypeBulk = 2;
const int kUsbEndpointIn = 0x80;

/// 批量端点 `wMaxPacketSize` 的低 11 位才是包长。
const int kUsbMaxPacketSizeMask = 0x07ff;

/// 一条 USB 端点的描述，供接口匹配使用，不依赖 libusb。
class UsbEndpointInfo {
  const UsbEndpointInfo({
    required this.address,
    required this.attributes,
    required this.maxPacketSize,
  });

  final int address;
  final int attributes;
  final int maxPacketSize;

  bool get isBulk =>
      (attributes & kUsbTransferTypeMask) == kUsbTransferTypeBulk;

  bool get isIn => (address & kUsbEndpointIn) != 0;
}

/// 一个接口的第 0 个备用设置。
class UsbInterfaceInfo {
  const UsbInterfaceInfo({
    required this.interfaceNumber,
    required this.usbClass,
    required this.usbSubclass,
    required this.usbProtocol,
    required this.endpoints,
  });

  final int interfaceNumber;
  final int usbClass;
  final int usbSubclass;
  final int usbProtocol;
  final List<UsbEndpointInfo> endpoints;
}

/// 找到的 ADB 批量接口。
class AdbUsbInterfaceMatch {
  const AdbUsbInterfaceMatch({
    required this.interfaceNumber,
    required this.endpointIn,
    required this.endpointOut,
    required this.maxPacketSize,
  });

  final int interfaceNumber;
  final int endpointIn;
  final int endpointOut;
  final int maxPacketSize;
}

bool isAdbInterface(int usbClass, int usbSubclass, int usbProtocol) {
  if (usbProtocol != kAdbUsbProtocol) return false;
  if (usbClass == kAdbUsbClass && usbSubclass == kAdbUsbSubclass) return true;
  return usbClass == kAdbDbcClass && usbSubclass == kAdbDbcSubclass;
}

/// 在配置描述符里找第一个同时具备批量 IN 和 OUT 的 ADB 接口。
AdbUsbInterfaceMatch? findAdbInterface(List<UsbInterfaceInfo> interfaces) {
  for (final interface in interfaces) {
    if (!isAdbInterface(
      interface.usbClass,
      interface.usbSubclass,
      interface.usbProtocol,
    )) {
      continue;
    }
    int? endpointIn;
    int? endpointOut;
    var maxPacketSize = 0;
    for (final endpoint in interface.endpoints) {
      if (!endpoint.isBulk) continue;
      final packetSize = endpoint.maxPacketSize & kUsbMaxPacketSizeMask;
      if (packetSize == 0) continue;
      if (endpoint.isIn && endpointIn == null) {
        endpointIn = endpoint.address;
        maxPacketSize = packetSize;
      } else if (!endpoint.isIn && endpointOut == null) {
        endpointOut = endpoint.address;
        if (maxPacketSize == 0) maxPacketSize = packetSize;
      }
    }
    if (endpointIn != null && endpointOut != null && maxPacketSize > 0) {
      return AdbUsbInterfaceMatch(
        interfaceNumber: interface.interfaceNumber,
        endpointIn: endpointIn,
        endpointOut: endpointOut,
        maxPacketSize: maxPacketSize,
      );
    }
  }
  return null;
}

/// 写出的长度恰好是批量包长的整数倍时，需要再发一个零长度包。
/// 空写入本身不补零长度包。
bool needsZeroLengthPacket(int length, int maxPacketSize) {
  if (length <= 0 || maxPacketSize <= 0) return false;
  return length % maxPacketSize == 0;
}
