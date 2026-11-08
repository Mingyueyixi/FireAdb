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
        // A 记录 10.0.2.2（自报住址，非本机）解析并合并。应答源 127.0.0.1
        // 只是"应答方在本机"，不代表服务在本机，不参与本机判定。
        expect(service.address?.address, '10.0.2.2');
        expect(service.txt['v'], '1');
        expect(service.txt['name'], 'Emulator');
        expect(service.txt['api'], '31');
        expect(service.isLocal, isFalse);
      } finally {
        await responder.close();
      }
    });

    test('A 记录的 IPv4 优先于链路本地 IPv6 进入候选', () async {
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
        // 自报住址 10.0.2.2（IPv4）胜过链路本地 IPv6（优先级选择由
        // preferReachableAddress 的纯函数测试覆盖）。
        final service = services.single;
        expect(service.isLocal, isFalse);
        expect(service.address?.address, '10.0.2.2');
      } finally {
        await responder.close();
      }
    });

    test('组播之外还会单播探测 127.0.0.1（loopback 通道可达）', () async {
      // 组播场景（group 为 224.0.0.251），假应答方监听 loopback 的 mDNS
      // 端口：只有 loopback 单播探测能到达它。覆盖 loopback 探测通道。
      final responder = await spawnFakeResponder(0);
      try {
        final browser = MdnsBrowser(
          group: kMdnsGroupV4,
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
        // 经 loopback 单播通道发现；自报住址非本机，端点为 A 记录。
        expect(service.isLocal, isFalse);
        expect(service.address?.address, '10.0.2.2');
      } finally {
        await responder.close();
      }
    });

    test('自报住址是本机接口 IP 时：本机服务，端点合成回环', () async {
      // 真机场景：本机 mdnsd 组播应答，A 记录是自己的接口 IP（如
      // 192.168.x.x）。应答源与 A 记录都在本机 → 端点应合成 127.0.0.1，
      // 且给出局域网展示地址。应答源是 127.0.0.1 而 A 记录非本机时
      // （本机 server 代发远端设备）不得误判，由上面的测试覆盖。
      String? lanIp;
      for (final address in await localMachineAddresses()) {
        final parsed = InternetAddress(address);
        if (parsed.type == InternetAddressType.IPv4 &&
            !parsed.isLoopback &&
            !parsed.isLinkLocal) {
          lanIp = address;
          break;
        }
      }
      if (lanIp == null) {
        // 无局域网地址的环境（无网卡/离线 CI）没有可测的前提。
        return;
      }
      final responder = await spawnFakeResponder(
        0,
        response: buildPairingResponse(a: InternetAddress(lanIp).rawAddress),
      );
      try {
        final browser = MdnsBrowser(
          group: InternetAddress.loopbackIPv4,
          port: responder.port,
          timeout: const Duration(seconds: 3),
        );
        final services = await browser.discover(
          serviceTypes: const {adbServiceTypePairing},
        );
        final service = services.single;
        expect(service.isLocal, isTrue);
        expect(service.address?.address, '127.0.0.1');
        expect(service.interfaceAddress, lanIp);
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

    test('本机地址集合恒定并入回环（Android 枚举可能不含回环接口）', () {
      final set = localAddressSetWithLoopback(<String>['192.168.3.45']);
      expect(set.contains('127.0.0.1'), isTrue);
      expect(set.contains('::1'), isTrue);
      expect(set.contains('192.168.3.45'), isTrue);
      // 枚举失败（空结果）时回环判定仍然成立。
      final empty = localAddressSetWithLoopback(const <String>[]);
      expect(empty, <String>{'127.0.0.1', '::1'});
    });

    test('本机服务的局域网展示地址：只取本机非回环、非链路本地地址', () {
      const local = <String>{'127.0.0.1', '192.168.3.45'};
      expect(
        localInterfaceAddressOf(<InternetAddress>[
          InternetAddress('127.0.0.1'),
          InternetAddress('192.168.3.45'),
        ], local),
        '192.168.3.45',
      );
      // 链路本地址对用户无意义，不作为展示地址。
      expect(
        localInterfaceAddressOf(<InternetAddress>[
          InternetAddress('fe80::1'),
        ], local),
        isNull,
      );
      // 非本机地址（跨机服务）不产生展示地址。
      expect(
        localInterfaceAddressOf(<InternetAddress>[
          InternetAddress('10.0.2.2'),
        ], local),
        isNull,
      );
    });

    test('展示地址按接口选：WiFi 优先，其次以太网，蜂窝最后', () {
      InternetAddress ip(String value) => InternetAddress(value);
      final wlan = (
        name: 'wlan0',
        addresses: <InternetAddress>[ip('192.168.3.45')],
      );
      final eth = (name: 'eth0', addresses: <InternetAddress>[ip('10.0.0.8')]);
      final rmnet = (
        name: 'rmnet0',
        addresses: <InternetAddress>[ip('10.22.5.7')],
      );

      // WiFi 与蜂窝并存：显示 WiFi 的，蜂窝地址不抢占展示位。
      expect(wifiPreferredLanAddress([rmnet, wlan]), '192.168.3.45');
      // 无 WiFi 时用以太网。
      expect(wifiPreferredLanAddress([rmnet, eth]), '10.0.0.8');
      // 只有蜂窝时仍如实展示（总比没有好）。
      expect(wifiPreferredLanAddress([rmnet]), '10.22.5.7');
      // 回环 / 链路本地不作为展示地址。
      expect(
        wifiPreferredLanAddress([
          (
            name: 'lo',
            addresses: <InternetAddress>[ip('127.0.0.1'), ip('fe80::1')],
          ),
        ]),
        isNull,
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
      expect(browser.lastRoundExpiredEmpty, isFalse);
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
    });

    test('采集时间到且没有应答时，不算没有设备', () async {
      final browser = MdnsBrowser(
        group: InternetAddress.loopbackIPv4,
        port: 9,
        timeout: const Duration(milliseconds: 200),
      );
      final services = await browser.discover(
        serviceTypes: const {adbServiceTypePairing},
      );
      expect(services, isEmpty);
      expect(browser.lastRoundExpiredEmpty, isTrue);
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
