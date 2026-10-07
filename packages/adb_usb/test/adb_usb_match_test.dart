import 'dart:io';

import 'package:adb_usb/adb_usb.dart';
import 'package:adb_usb/src/libusb_loader.dart' show windowsLibusbCandidates;
import 'package:test/test.dart';

void main() {
  test('识别 ADB 接口和 DbC 接口', () {
    expect(isAdbInterface(0xff, 0x42, 0x01), isTrue);
    expect(isAdbInterface(0xdc, 0x02, 0x01), isTrue);
    expect(isAdbInterface(0xff, 0x42, 0x00), isFalse);
    expect(isAdbInterface(0x08, 0x06, 0x50), isFalse);
  });

  test('在复合设备里找到批量 IN 和 OUT', () {
    final match = findAdbInterface(const <UsbInterfaceInfo>[
      UsbInterfaceInfo(
        interfaceNumber: 0,
        usbClass: 0x08,
        usbSubclass: 0x06,
        usbProtocol: 0x50,
        endpoints: <UsbEndpointInfo>[],
      ),
      UsbInterfaceInfo(
        interfaceNumber: 1,
        usbClass: 0xff,
        usbSubclass: 0x42,
        usbProtocol: 0x01,
        endpoints: <UsbEndpointInfo>[
          UsbEndpointInfo(address: 0x81, attributes: 2, maxPacketSize: 512),
          UsbEndpointInfo(address: 0x01, attributes: 2, maxPacketSize: 512),
        ],
      ),
    ]);
    expect(match?.interfaceNumber, 1);
    expect(match?.endpointIn, 0x81);
    expect(match?.endpointOut, 0x01);
    expect(match?.maxPacketSize, 512);
  });

  test('调试目录往上能找到工程里的 libusb', () {
    final separator = Platform.pathSeparator;
    final executable = [
      'C:',
      'repo',
      'app',
      'build',
      'windows',
      'x64',
      'runner',
      'Debug',
      'fire_adb.exe',
    ].join(separator);
    final library = [
      'C:',
      'repo',
      'packages',
      'adb_usb',
      'vendor',
      'windows',
      'libusb-1.0.dll',
    ].join(separator);
    expect(windowsLibusbCandidates(executable), contains(library));
  });

  test('包长整数倍的写入需要零长度包', () {
    expect(needsZeroLengthPacket(0, 512), isFalse);
    expect(needsZeroLengthPacket(24, 512), isFalse);
    expect(needsZeroLengthPacket(512, 512), isTrue);
    expect(needsZeroLengthPacket(1024, 512), isTrue);
  });
}
