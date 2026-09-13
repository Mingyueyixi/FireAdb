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
            timeout: const Duration(seconds: 3));

        final services = await browser.discover(
            serviceTypes: const {adbServiceTypePairing});

        expect(services, isNotEmpty);
        final service =
            services.singleWhere((s) => s.serviceType == adbServiceTypePairing);

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

    test('只查询 connect 服务时不返回配对结果', () async {
      final responder = await spawnFakeResponder(0);
      try {
        final browser = MdnsBrowser(
            group: InternetAddress.loopbackIPv4,
            port: responder.port,
            timeout: const Duration(seconds: 2));
        final services = await browser.discover(
            serviceTypes: const {adbServiceTypeConnect});
        expect(services, isEmpty);
      } finally {
        await responder.close();
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