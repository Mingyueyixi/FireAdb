import 'dart:math';

import 'package:fire_adb/home/adb_qr_pairing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libadb/libadb.dart';

void main() {
  test('二维码内容使用 studio 服务名和配对密码', () {
    final session = AdbQrPairing.generate(Random(1));

    expect(session.serviceName, startsWith(AdbQrPairing.servicePrefix));
    expect(
      session.serviceName.length,
      AdbQrPairing.servicePrefix.length + AdbQrPairing.nameLength,
    );
    expect(session.password, hasLength(AdbQrPairing.passwordLength));
    expect(
      session.payload,
      'WIFI:T:ADB;S:${session.serviceName};P:${session.password};;',
    );
    expect(
      RegExp(r'^studio-[A-Za-z0-9]+$').hasMatch(session.serviceName),
      isTrue,
    );
    expect(RegExp(r'^[A-Za-z0-9]+$').hasMatch(session.password), isTrue);
  });

  test('用 mDNS 实例名的第一段匹配二维码里的服务名', () {
    expect(
      qrInstanceMatches(
        'studio-abcdefghij._adb-tls-pairing._tcp.local',
        'studio-abcdefghij',
      ),
      isTrue,
    );
    expect(
      qrInstanceMatches(
        'studio-abcdefghij._adb-tls-pairing._tcp.local.',
        'studio-abcdefghij',
      ),
      isTrue,
    );
    expect(
      qrInstanceMatches(
        'other._adb-tls-pairing._tcp.local',
        'studio-abcdefghij',
      ),
      isFalse,
    );
    expect(
      qrInstanceMatches(
        'studio-abcdefghij._adb-tls-pairing._tcp.local.',
        'studio-AbCdEfGhIj',
      ),
      isTrue,
    );
  });

  test('扫到对应配对服务后配对并连接同一地址', () async {
    final session = AdbQrPairing(
      serviceName: 'studio-AbCdEfGhIj',
      password: 'password1234',
    );
    final pairing = MdnsService(
      instanceName: 'studio-abcdefghij._adb-tls-pairing._tcp.local',
      serviceType: adbServiceTypePairing,
      port: 37123,
      host: '192.0.2.8',
    );
    final connectService = MdnsService(
      instanceName: 'adb-serial._adb-tls-connect._tcp.local',
      serviceType: adbServiceTypeConnect,
      port: 5555,
      host: '192.0.2.8',
    );
    var polls = 0;
    String? paired;
    String? connected;

    final outcome = await watchQrPairing(
      session: session,
      discover: ({timeout, stopWhen, isCancelled}) async {
        polls++;
        if (polls < 2) return const <MdnsService>[];
        return <MdnsService>[pairing, connectService];
      },
      pair: (host, port, password) async {
        paired = '$host:$port:$password';
      },
      connect: (host, port) async {
        connected = '$host:$port';
        return 'SERIAL';
      },
      isCancelled: () => false,
      wait: (_) async {},
    );

    expect(outcome.kind, QrPairingOutcomeKind.connected);
    expect(outcome.serial, 'SERIAL');
    expect(paired, '192.0.2.8:37123:password1234');
    expect(connected, '192.0.2.8:5555');
  });

  test('配对成功但没有 TLS 端口时，超时后提示手动连接', () async {
    final session = AdbQrPairing(
      serviceName: 'studio-abcdefghij',
      password: 'password1234',
    );
    final pairing = MdnsService(
      instanceName: 'studio-abcdefghij._adb-tls-pairing._tcp.local',
      serviceType: adbServiceTypePairing,
      port: 37123,
      host: '192.0.2.8',
    );
    var nowCalls = 0;
    final start = DateTime(2020);
    var pairs = 0;

    final outcome = await watchQrPairing(
      session: session,
      timeout: const Duration(minutes: 2),
      now: () {
        nowCalls++;
        if (nowCalls < 4) return start;
        return start.add(const Duration(minutes: 3));
      },
      discover: ({timeout, stopWhen, isCancelled}) async => <MdnsService>[
        pairing,
      ],
      pair: (host, port, password) async {
        pairs++;
      },
      connect: (host, port) async => 'unused',
      isCancelled: () => false,
      wait: (_) async {},
    );

    expect(outcome.kind, QrPairingOutcomeKind.pairedOnly);
    expect(pairs, 1);
  });

  test('取消后不再继续查询', () async {
    var polls = 0;
    final outcome = await watchQrPairing(
      session: AdbQrPairing(serviceName: 'studio-abcdefghij', password: 'x'),
      discover: ({timeout, stopWhen, isCancelled}) async {
        polls++;
        return const <MdnsService>[];
      },
      pair: (host, port, password) async {},
      connect: (host, port) async => '',
      isCancelled: () => true,
      wait: (_) async {},
    );

    expect(outcome.kind, QrPairingOutcomeKind.cancelled);
    expect(polls, 0);
  });
}
