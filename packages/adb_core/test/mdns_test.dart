import 'dart:io';
import 'dart:typed_data';

import 'package:adb_core/adb_core.dart';
import 'package:test/test.dart';

import 'fake_mdns_responder.dart';

/// 断言测试用应答报文确实用了名称压缩指针（否则压缩路径根本没被测到）。
void _checkPointersUsed(Uint8List packet) {
  var count = 0;
  for (var i = 12; i + 1 < packet.length; i++) {
    if (packet[i] == 0xC0) count++;
  }
  expect(count, greaterThanOrEqualTo(2), reason: '应答应使用名称压缩指针');
}

void main() {
  group('mDNS 发现（6g：_adb-tls-pairing._tcp）', () {
    test('查询配对服务并聚合 PTR/SRV/TXT/A（含压缩指针）', () async {
      final responder = await spawnFakeResponder(0);
      try {
        _checkPointersUsed(buildPairingResponse());
        final browser = MdnsBrowser(
          group: InternetAddress.loopbackIPv4,
          port: responder.port,
          timeout: const Duration(seconds: 3),
        );

        final services = await browser.discover(
          serviceTypes: const {adbServiceTypePairing},
        );

        expect(services, isNotEmpty);
        final service = services.singleWhere(
          (s) => s.serviceType == adbServiceTypePairing,
        );

        expect(service.instanceName, kFakeInstanceFqdn);
        expect(service.port, kFakePairPort);
        expect(service.host, kFakeHostFqdn);
        expect(service.address?.address, '10.0.2.2');
        expect(service.txt['v'], '1');
        expect(service.txt['name'], 'Emulator');
        expect(service.txt['api'], '31');
      } finally {
        await responder.close();
      }
    });

    test('同时有 IPv4 和链路本地 IPv6 时使用 IPv4', () async {
      final responder = await spawnFakeResponder(
        0,
        response: buildPairingResponse(
          aaaa: <int>[0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],
        ),
      );
      try {
        final browser = MdnsBrowser(
          group: InternetAddress.loopbackIPv4,
          port: responder.port,
          timeout: const Duration(seconds: 2),
        );
        final services = await browser.discover(
          serviceTypes: const {adbServiceTypePairing},
        );
        expect(services.single.address?.address, '10.0.2.2');
      } finally {
        await responder.close();
      }
    });

    test('可连接地址优先局域网 IPv4，只有链路本地时仍保留', () {
      expect(
        preferReachableAddress(<InternetAddress>[
          InternetAddress('fe80::4ce5:66ff:fe22:614'),
          InternetAddress('192.168.3.45'),
        ])?.address,
        '192.168.3.45',
      );
      expect(
        preferReachableAddress(<InternetAddress>[
          InternetAddress('fe80::4ce5:66ff:fe22:614'),
        ])?.isLinkLocal,
        isTrue,
      );
    });

    test('链路本地地址连接时带上网卡标识', () {
      expect(
        linkLocalConnectHosts('fe80::1', <({String name, int index})>[
          (name: 'wlan0', index: 12),
        ]),
        <String>['fe80::1%wlan0', 'fe80::1%12'],
      );
      expect(
        linkLocalConnectHosts('192.168.3.45', <({String name, int index})>[
          (name: 'wlan0', index: 12),
        ]),
        <String>['192.168.3.45'],
      );
      expect(
        linkLocalConnectHosts('fe80::1%wlan0', <({String name, int index})>[
          (name: 'wlan0', index: 12),
        ]),
        <String>['fe80::1%wlan0'],
      );
    });

    test('应答到达时先回调，扫描仍等到采集窗口结束', () async {
      final responder = await spawnFakeResponder(0);
      try {
        final browser = MdnsBrowser(
          group: InternetAddress.loopbackIPv4,
          port: responder.port,
          timeout: const Duration(milliseconds: 700),
        );
        final updates = <List<MdnsService>>[];
        Duration? firstUpdate;
        final watch = Stopwatch()..start();
        final services = await browser.discover(
          serviceTypes: const {adbServiceTypePairing},
          onUpdate: (found) {
            firstUpdate ??= watch.elapsed;
            updates.add(found);
          },
        );
        watch.stop();
        expect(updates, isNotEmpty);
        expect(firstUpdate!, lessThan(const Duration(milliseconds: 400)));
        expect(updates.last.single.port, services.single.port);
        expect(
          watch.elapsed,
          greaterThanOrEqualTo(const Duration(milliseconds: 700)),
        );
      } finally {
        await responder.close();
      }
    });

    test('目标服务一到就返回，不再等满窗口', () async {
      final responder = await spawnFakeResponder(0);
      try {
        final browser = MdnsBrowser(
          group: InternetAddress.loopbackIPv4,
          port: responder.port,
          timeout: const Duration(seconds: 2),
        );
        final watch = Stopwatch()..start();
        final services = await browser.discover(
          serviceTypes: const {adbServiceTypePairing},
          stopWhen: (found) => found.any(
            (service) => service.serviceType == adbServiceTypePairing,
          ),
        );
        watch.stop();
        expect(services, isNotEmpty);
        expect(watch.elapsed, lessThan(const Duration(milliseconds: 900)));
      } finally {
        await responder.close();
      }
    });

    test('取消后不再等满窗口', () async {
      final browser = MdnsBrowser(
        group: InternetAddress.loopbackIPv4,
        port: 9,
        timeout: const Duration(seconds: 2),
      );
      final watch = Stopwatch()..start();
      final services = await browser.discover(
        serviceTypes: const {adbServiceTypePairing},
        isCancelled: () => true,
      );
      watch.stop();
      expect(services, isEmpty);
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
    });

    test('只查询 connect 服务时不返回配对结果', () async {
      final responder = await spawnFakeResponder(0);
      try {
        final browser = MdnsBrowser(
          group: InternetAddress.loopbackIPv4,
          port: responder.port,
          timeout: const Duration(seconds: 2),
        );
        final services = await browser.discover(
          serviceTypes: const {adbServiceTypeConnect},
        );
        expect(services, isEmpty);
      } finally {
        await responder.close();
      }
    });

    test('只把有默认路由的网卡当作可连接网络', () async {
      expect(
        defaultRouteKeysFromRoutePrint('''
          0.0.0.0          0.0.0.0      192.168.3.1     192.168.3.27     35
        192.168.56.0    255.255.255.0      On-link       192.168.56.1    281
'''),
        {'192.168.3.27'},
      );
      expect(
        defaultRouteKeysFromProcNetRoute('''
Iface Destination Gateway Flags
wlan0 0003A8C0 0101A8C0 0003
wlan0 00000000 0101A8C0 0003
'''),
        {'wlan0'},
      );

      final interfaces = await NetworkInterface.list();
      final selected = selectConnectableInterfaces(interfaces, {
        '192.168.3.27',
      });
      final hasTarget = interfaces.any(
        (iface) =>
            iface.addresses.any((address) => address.address == '192.168.3.27'),
      );
      if (!hasTarget) return;
      expect(
        selected.every(
          (iface) => iface.addresses.any(
            (address) => address.address == '192.168.3.27',
          ),
        ),
        isTrue,
      );
      expect(
        selectConnectableInterfaces(interfaces, {}),
        multicastSendInterfaces(interfaces, InternetAddressType.IPv4),
      );
    });

    test('组播出口保留无线网卡和虚拟网卡，跳过回环与链路本地', () {
      expect(
        sendsLanMulticast(<InternetAddress>[
          InternetAddress.loopbackIPv4,
        ], InternetAddressType.IPv4),
        isFalse,
      );
      expect(
        sendsLanMulticast(<InternetAddress>[
          InternetAddress('169.254.128.172'),
        ], InternetAddressType.IPv4),
        isFalse,
      );
      expect(
        sendsLanMulticast(<InternetAddress>[
          InternetAddress('192.168.248.2'),
        ], InternetAddressType.IPv4),
        isTrue,
      );
      expect(
        sendsLanMulticast(<InternetAddress>[
          InternetAddress('192.168.3.27'),
        ], InternetAddressType.IPv4),
        isTrue,
      );
    });

    test('可以为每块局域网网卡设置组播出口', () async {
      final interfaces = multicastSendInterfaces(
        await NetworkInterface.list(),
        InternetAddressType.IPv4,
      );
      expect(interfaces, isNotEmpty);
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      try {
        for (final iface in interfaces) {
          expect(
            selectMulticastInterface(socket, iface),
            isTrue,
            reason: iface.name,
          );
        }
      } finally {
        socket.close();
      }
    });

    test('真实网络发现（可选；无局域网设备时不报错）', () async {
      final services = await discoverAdbServices();
      for (final service in services) {
        // ignore: avoid_print
        print('  ${service.toString()}');
      }
    });
  });
}
