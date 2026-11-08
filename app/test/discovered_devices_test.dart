import 'dart:io';

import 'package:fireadb/connection/model/device_profile.dart';
import 'package:fireadb/home/discovered_devices.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libadb/libadb.dart';

void main() {
  test('可连接的扫描结果并入设备列表，同一地址只留一行', () {
    final connect = MdnsService(
      instanceName: 'adb-phone',
      serviceType: adbServiceTypeConnect,
      port: 37055,
      address: InternetAddress('192.0.2.10'),
      txt: const <String, String>{'name': 'Pixel_8'},
    );
    final transport = MdnsService(
      instanceName: 'legacy',
      serviceType: adbServiceTypeTransport,
      port: 5555,
      address: InternetAddress('192.0.2.20'),
    );
    final sameAsAdb = MdnsService(
      instanceName: 'already-listed',
      serviceType: adbServiceTypeConnect,
      port: 5555,
      address: InternetAddress('192.0.2.30'),
    );
    final sameAsProfile = MdnsService(
      instanceName: 'already-connected',
      serviceType: adbServiceTypeConnect,
      port: 40000,
      address: InternetAddress('fe80::1'),
    );
    final pairing = MdnsService(
      instanceName: 'pair-me',
      serviceType: adbServiceTypePairing,
      port: 37123,
      address: InternetAddress('192.0.2.10'),
    );

    final listed = connectableDiscoveredServices(
      discovered: <MdnsService>[
        connect,
        transport,
        sameAsAdb,
        sameAsProfile,
        pairing,
      ],
      adbDevices: const <AdbDeviceInfo>[
        AdbDeviceInfo('192.0.2.30:5555', 'device'),
      ],
      profiles: const <DeviceProfile>[
        DeviceProfile(serial: 'connected', host: 'fe80::1', port: 40000),
      ],
    );

    expect(listed, <MdnsService>[connect, transport]);
    expect(discoveredServiceTitle(connect), 'Pixel 8');
    expect(adbSerialEndpoint('[fe80::1]:40000'), ('fe80::1', 40000));
  });

  test('本机地址等价：127.0.0.1 与本机接口 IP 是同一台设备', () {
    const local = <String>{'127.0.0.1', '192.168.3.45', '::1'};
    final discoveredWifiIp = MdnsService(
      instanceName: 'adb-self',
      serviceType: adbServiceTypeConnect,
      port: 40001,
      address: InternetAddress('192.168.3.45'),
    );
    final otherPort = MdnsService(
      instanceName: 'adb-self-other-port',
      serviceType: adbServiceTypeConnect,
      port: 40002,
      address: InternetAddress('192.168.3.45'),
    );
    final remoteDevice = MdnsService(
      instanceName: 'adb-remote',
      serviceType: adbServiceTypeConnect,
      port: 40003,
      address: InternetAddress('192.0.2.10'),
    );

    // 手动连接 127.0.0.1 后，同一端口的接口 IP 服务不再重复出现。
    final listed = connectableDiscoveredServices(
      discovered: <MdnsService>[discoveredWifiIp, otherPort, remoteDevice],
      adbDevices: const <AdbDeviceInfo>[],
      profiles: const <DeviceProfile>[
        DeviceProfile(serial: 'manual', host: '127.0.0.1', port: 40001),
      ],
      localAddresses: local,
    );
    expect(listed, <MdnsService>[otherPort, remoteDevice]);

    // 反向同理：本机服务 127.0.0.1 不会与远端设备地址混同。
    final loopbackService = MdnsService(
      instanceName: 'adb-self-loop',
      serviceType: adbServiceTypeConnect,
      port: 40001,
      address: InternetAddress('127.0.0.1'),
    );
    expect(
      connectableDiscoveredServices(
        discovered: <MdnsService>[loopbackService],
        adbDevices: const <AdbDeviceInfo>[],
        profiles: const <DeviceProfile>[
          DeviceProfile(serial: 'manual', host: '192.168.3.45', port: 40001),
        ],
        localAddresses: local,
      ),
      isEmpty,
    );
  });
}
