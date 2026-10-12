import 'dart:math';

import 'package:libadb/libadb.dart';

/// Android Studio 使用的无线调试二维码。
///
/// 内容是 `WIFI:T:ADB;S:studio-<名字>;P:<密码>;;`。手机的「使用二维码配对设备」
/// 扫到后，会用这个名字登记 `_adb-tls-pairing._tcp`，密码就是配对口令。
class AdbQrPairing {
  AdbQrPairing({required this.serviceName, required this.password});

  static const String servicePrefix = 'studio-';
  static const int nameLength = 10;
  static const int passwordLength = 12;

  /// 不含 `;`、`:`、`\`、`,`、`"`，避免 Wi-Fi 二维码转义。
  static const String alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

  final String serviceName;
  final String password;

  factory AdbQrPairing.generate([Random? random]) {
    final rng = random ?? Random.secure();
    String token(int length) {
      final units = List<int>.generate(
        length,
        (_) => alphabet.codeUnitAt(rng.nextInt(alphabet.length)),
      );
      return String.fromCharCodes(units);
    }

    return AdbQrPairing(
      serviceName: '$servicePrefix${token(nameLength)}',
      password: token(passwordLength),
    );
  }

  String get payload => 'WIFI:T:ADB;S:$serviceName;P:$password;;';
}

/// mDNS 实例名的第一段是否就是二维码里请求的服务名。
///
/// DNS 解析会把名字转成小写，二维码里的 `studio-` 名字仍保留原来的大小写。
bool qrInstanceMatches(String instanceName, String serviceName) {
  var name = instanceName;
  if (name.endsWith('.')) name = name.substring(0, name.length - 1);
  final first = name.split('.').first;
  return first.toLowerCase() == serviceName.toLowerCase();
}

enum QrPairingPhase { waiting, pairing, connecting }

enum QrPairingOutcomeKind { connected, pairedOnly, timedOut, cancelled }

class QrPairingOutcome {
  const QrPairingOutcome.connected(this.serial)
    : kind = QrPairingOutcomeKind.connected;

  const QrPairingOutcome.pairedOnly()
    : kind = QrPairingOutcomeKind.pairedOnly,
      serial = null;

  const QrPairingOutcome.timedOut()
    : kind = QrPairingOutcomeKind.timedOut,
      serial = null;

  const QrPairingOutcome.cancelled()
    : kind = QrPairingOutcomeKind.cancelled,
      serial = null;

  final QrPairingOutcomeKind kind;
  final String? serial;
}

typedef QrPairingDiscover = Future<List<MdnsService>> Function({
  Duration? timeout,
  bool Function(List<MdnsService> services)? stopWhen,
  bool Function()? isCancelled,
});

/// 监听配对服务。发现对应的 `studio-` 名字后立刻配对，并连接同一地址上的 TLS 端口。
Future<QrPairingOutcome> watchQrPairing({
  required AdbQrPairing session,
  required QrPairingDiscover discover,
  required Future<void> Function(String host, int port, String password) pair,
  required Future<String> Function(String host, int port) connect,
  required bool Function() isCancelled,
  Duration timeout = const Duration(minutes: 2),
  Duration pause = const Duration(milliseconds: 300),
  DateTime Function() now = DateTime.now,
  Future<void> Function(Duration delay) wait = Future<void>.delayed,
  void Function(QrPairingPhase phase)? onPhase,
}) async {
  final deadline = now().add(timeout);
  MdnsService? pairedFrom;
  while (!isCancelled() && now().isBefore(deadline)) {
    final remaining = deadline.difference(now());
    final services = await discover(
      timeout: remaining,
      isCancelled: isCancelled,
      stopWhen: (found) {
        if (pairedFrom == null) {
          return found.any(
            (service) =>
                service.serviceType == adbServiceTypePairing &&
                qrInstanceMatches(service.instanceName, session.serviceName),
          );
        }
        return _matchingConnect(found, pairedFrom!) != null;
      },
    );
    if (isCancelled()) return const QrPairingOutcome.cancelled();
    if (pairedFrom == null) {
      final pairing = services.where(
        (service) =>
            service.serviceType == adbServiceTypePairing &&
            qrInstanceMatches(service.instanceName, session.serviceName),
      );
      if (pairing.isNotEmpty) {
        onPhase?.call(QrPairingPhase.pairing);
        final service = pairing.first;
        await pair(service.addressText, service.port, session.password);
        if (isCancelled()) return const QrPairingOutcome.cancelled();
        pairedFrom = service;
      }
    }
    if (pairedFrom != null) {
      final connectService = _matchingConnect(services, pairedFrom);
      if (connectService != null) {
        onPhase?.call(QrPairingPhase.connecting);
        try {
          final serial = await connect(
            connectService.addressText,
            connectService.port,
          );
          if (isCancelled()) return const QrPairingOutcome.cancelled();
          return QrPairingOutcome.connected(serial);
        } catch (_) {
          return const QrPairingOutcome.pairedOnly();
        }
      }
    }
    await wait(pause);
  }
  if (isCancelled()) return const QrPairingOutcome.cancelled();
  if (pairedFrom != null) return const QrPairingOutcome.pairedOnly();
  return const QrPairingOutcome.timedOut();
}

MdnsService? _matchingConnect(List<MdnsService> services, MdnsService paired) {
  final address = paired.addressText;
  if (address.isEmpty) return null;
  for (final service in services) {
    if (service.serviceType != adbServiceTypeConnect) continue;
    if (service.addressText == address) return service;
  }
  return null;
}
