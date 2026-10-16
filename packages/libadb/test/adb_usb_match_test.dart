import 'dart:io';

import 'package:libadb/src/adb_usb_match.dart';
import 'package:libadb/src/adb_usb_session.dart'
    show usbBulkReadFailed, usbTransferLayout;
import 'package:libadb/src/libusb_loader.dart' show windowsLibusbCandidates;
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
      'libadb',
      'vendor',
      'windows',
      'x64',
      'libusb-1.0.dll',
    ].join(separator);
    expect(windowsLibusbCandidates(executable), contains(library));
    final armLibrary = [
      'C:',
      'repo',
      'packages',
      'libadb',
      'vendor',
      'windows',
      'arm64',
      'libusb-1.0.dll',
    ].join(separator);
    expect(
      windowsLibusbCandidates(executable, architecture: 'arm64'),
      contains(armLibrary),
    );
  });

  test('USB 读超时不是断线，设备离开才是', () {
    expect(usbBulkReadFailed(0), isFalse);
    expect(usbBulkReadFailed(2), isFalse);
    expect(usbBulkReadFailed(3), isFalse);
    expect(usbBulkReadFailed(5), isTrue);
  });

  test('包长整数倍的写入需要零长度包', () {
    expect(needsZeroLengthPacket(0, 512), isFalse);
    expect(needsZeroLengthPacket(24, 512), isFalse);
    expect(needsZeroLengthPacket(512, 512), isTrue);
    expect(needsZeroLengthPacket(1024, 512), isTrue);
  });

  test('异步传输结构与 libusb 1.0 的 64 位布局一致', () {
    final layout = usbTransferLayout();
    expect(layout['size'], 64);
    expect(layout['timeout'], 12);
    expect(layout['length'], 20);
    expect(layout['buffer'], 48);
  });
}
