import 'dart:io';

import 'package:fire_adb/connection/model/device_profile.dart';
import 'package:fire_adb/home/discovered_devices.dart';
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
    expect(
      mergeDiscoveredServices(
        <MdnsService>[connect, pairing],
        <MdnsService>[transport],
      ).map(discoveredServiceKey),
      <String>[
        discoveredServiceKey(transport),
        discoveredServiceKey(connect),
        discoveredServiceKey(pairing),
      ],
    );
  });

  test('一次扫描没发现设备时，10 秒内仍留着，再久就去掉', () {
    final service = MdnsService(
      instanceName: 'adb-phone',
      serviceType: adbServiceTypeTransport,
      port: 6666,
      address: InternetAddress('192.168.3.45'),
    );
    final seenAt = <String, DateTime>{
      discoveredServiceKey(service): DateTime(2026, 10, 13, 18, 10, 50),
    };

    final kept = retainRecentDiscoveries(
      previous: <MdnsService>[service],
      found: const <MdnsService>[],
      seenAt: seenAt,
      now: DateTime(2026, 10, 13, 18, 10, 58),
    );
    expect(kept, <MdnsService>[service]);

    final dropped = retainRecentDiscoveries(
      previous: <MdnsService>[service],
      found: const <MdnsService>[],
      seenAt: seenAt,
      now: DateTime(2026, 10, 13, 18, 11, 5),
    );
    expect(dropped, isEmpty);
  });
}
