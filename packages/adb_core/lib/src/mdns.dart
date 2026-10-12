import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

/// AOSP adb mDNS 服务类型（对应 aosp-adb/adb_mdns.h 中的
/// `ADB_FULL_MDNS_SERVICE_TYPE`，即 `_adb-tls-pairing._tcp` 等）。
const String adbServiceTypeTransport = '_adb._tcp';
const String adbServiceTypePairing = '_adb-tls-pairing._tcp';
const String adbServiceTypeConnect = '_adb-tls-connect._tcp';

/// mDNS 组播地址与端口（RFC 6762）。
final InternetAddress kMdnsGroupV4 = InternetAddress('224.0.0.251');
final InternetAddress kMdnsGroupV6 = InternetAddress('ff02::fb');
const int kMdnsPort = 5353;
const String kMdnsDomain = 'local';

/// 每块网卡的查询超时。
///
/// 同一局域网里的 mDNS 会很快应答。各网卡同时发送，扫描只等这一段，
/// 不会按网卡数量累加。
const Duration kMdnsInterfaceTimeout = Duration(seconds: 3);

/// mDNS 发现到的 adb 服务。
///
/// 对应 AOSP `adb mdns services` 输出中的一行：
/// `instance_name \t service_type \t addr:port`。
class MdnsService {
  MdnsService({
    required this.instanceName,
    required this.serviceType,
    required this.port,
    this.host = '',
    this.address,
    this.txt = const {},
  });

  /// 实例名，例如 `adb-86VXQYJF-3A6B9C`（connect）或设备型号（pairing）。
  final String instanceName;

  /// 服务类型，例如 `_adb-tls-pairing._tcp`。
  final String serviceType;

  /// 端口（来自 SRV 记录）。pairing 服务即配对端口。
  final int port;

  /// SRV 目标主机名（可能为空字符串）。
  final String host;

  /// 解析到的地址（IPv4 优先，IPv6 兜底）。
  final InternetAddress? address;

  /// TXT 属性：`v`（服务版本）、`name`（ro.product.model）、`api`（SDK 版本）。
  final Map<String, String> txt;

  String get addressText => address?.address ?? host;

  /// 展示用的 `地址:端口`。IPv6 地址带方括号，避免和端口粘在一起。
  String get endpointText {
    final text = addressText;
    if (text.contains(':') && !text.startsWith('[')) return '[$text]:$port';
    return '$text:$port';
  }

  @override
  String toString() => '$instanceName\t$serviceType\t$endpointText';
}

/// 这些网卡上可以发出局域网组播查询。
///
/// 只保留带有该协议、且不是回环或链路本地地址的接口。Windows 不指定
/// 组播出口时，会从跃点数最小的虚拟网卡把 `224.0.0.251` 送出去。
List<NetworkInterface> multicastSendInterfaces(
  Iterable<NetworkInterface> interfaces,
  InternetAddressType type,
) {
  return <NetworkInterface>[
    for (final iface in interfaces)
      if (sendsLanMulticast(iface.addresses, type)) iface,
  ];
}

/// 有默认路由的网卡才能连上当前局域网里的其他设备。
///
/// [defaultRouteKeys] 来自路由表：Windows 用接口 IPv4，Linux / Android 用接口名。
/// 读不到路由，或路由和网卡对不上时，退回全部可发送的局域网网卡。
List<NetworkInterface> selectConnectableInterfaces(
  Iterable<NetworkInterface> interfaces,
  Set<String> defaultRouteKeys,
) {
  final lan = multicastSendInterfaces(interfaces, InternetAddressType.IPv4);
  if (defaultRouteKeys.isEmpty) return lan;
  final matched = <NetworkInterface>[
    for (final iface in lan)
      if (_matchesDefaultRoute(iface, defaultRouteKeys)) iface,
  ];
  return matched.isEmpty ? lan : matched;
}

bool _matchesDefaultRoute(NetworkInterface iface, Set<String> keys) {
  if (keys.contains(iface.name)) return true;
  for (final address in iface.addresses) {
    if (keys.contains(address.address)) return true;
  }
  return false;
}

/// 从 `route print -4` 里取出默认路由的接口地址。
Set<String> defaultRouteKeysFromRoutePrint(String text) {
  final keys = <String>{};
  final line = RegExp(
    r'^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+\d+\.\d+\.\d+\.\d+\s+(\d+\.\d+\.\d+\.\d+)\s+\d+\s*$',
    multiLine: true,
  );
  for (final match in line.allMatches(text)) {
    keys.add(match.group(1)!);
  }
  return keys;
}

/// 从 `/proc/net/route` 里取出默认路由的接口名。
Set<String> defaultRouteKeysFromProcNetRoute(String text) {
  final keys = <String>{};
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final parts = raw.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    if (parts[1].toLowerCase() != '00000000') continue;
    if (parts[0].toLowerCase() == 'iface') continue;
    keys.add(parts[0]);
  }
  return keys;
}

/// 这块网卡上有可以发出局域网组播的地址。
bool sendsLanMulticast(
  Iterable<InternetAddress> addresses,
  InternetAddressType type,
) {
  return addresses.any(
    (address) =>
        address.type == type &&
        !address.isLoopback &&
        !address.isLinkLocal &&
        !address.isMulticast,
  );
}

/// 从一组地址里选出适合发起 adb 连接的那个。
///
/// 优先局域网 IPv4，其次全局 IPv6。链路本地的 `fe80::` 没有网卡标识时
/// 系统会直接拒绝连接，所以只在没有其他地址时才用它。
InternetAddress? preferReachableAddress(Iterable<InternetAddress> addresses) {
  InternetAddress? ipv4;
  InternetAddress? ipv6;
  InternetAddress? loopback;
  InternetAddress? linkLocalV4;
  InternetAddress? linkLocalV6;
  for (final address in addresses) {
    if (address.isMulticast || _isUnspecified(address)) continue;
    if (address.isLoopback) {
      loopback ??= address;
      continue;
    }
    if (address.isLinkLocal) {
      if (address.type == InternetAddressType.IPv4) {
        linkLocalV4 ??= address;
      } else {
        linkLocalV6 ??= address;
      }
      continue;
    }
    if (address.type == InternetAddressType.IPv4) {
      ipv4 ??= address;
    } else {
      ipv6 ??= address;
    }
  }
  return ipv4 ?? ipv6 ?? loopback ?? linkLocalV4 ?? linkLocalV6;
}

bool _isUnspecified(InternetAddress address) {
  if (address.type == InternetAddressType.IPv4) {
    return address.address == '0.0.0.0';
  }
  final raw = address.rawAddress;
  return raw.every((byte) => byte == 0);
}

/// mDNS 层错误。
class MdnsException implements Exception {
  final String message;
  MdnsException(this.message);
  @override
  String toString() => 'MdnsException: $message';
}

/// 纯 Dart 的 mDNS 服务浏览器（RFC 6762 / RFC 6763）。
///
/// 向 `224.0.0.251:5353` 和 `ff02::fb:5353` 发送 PTR 查询。查询 TTL 为 255。
/// 只从有默认路由的网卡发出，并指定组播出口。没有默认路由的虚拟网卡
/// 到不了当前局域网，上面的设备无法连接。
/// 同时监听 5353 上的组播应答。收集 PTR / SRV / TXT / A / AAAA 记录并聚合为 [MdnsService]。
///
/// ⚠️ 适用场景说明（给上层 UI / 用户文档参考）：
///
/// ✅ **能发现的设备**：
/// - 开启了 **Android 无线调试** 的设备（Android 11+）
///   - 设置路径：`开发者选项` → `无线调试` → 启用
///   - 设备会广播 `_adb-tls-pairing._tcp`（配对）和/或 `_adb-tls-connect._tcp`（连接）
/// - 执行过 `adb tcpip` 的设备会广播 `_adb._tcp`（经典明文端口）
///
/// ❌ **无法发现的设备**：
/// - 只在电脑上执行 `adb connect`、手机自己没有打开 tcpip 或无线调试的设备
/// - 未开启无线调试、仅开启 USB 调试的设备
/// - 旧版本 Android（< 11）或未实现 mDNS 广播的 ROM
///
/// 💡 **用户引导建议**：
/// - 如果扫描无结果，提示用户：
///   1. 确认手机已开启「无线调试」（非 USB 调试）
///   2. 手机与电脑在同一 Wi-Fi 网段（无 AP 隔离）
///   3. 仍无法发现 → 改用「手动输入 IP:端口」直连（调用 [adbConnectTcp]）
class MdnsBrowser {
  MdnsBrowser({
    InternetAddress? group,
    this.port = kMdnsPort,
    this.timeout = kMdnsInterfaceTimeout,
    this.ttl = 255,
  }) : group = group ?? kMdnsGroupV4;

  /// 查询目标（默认 mDNS 组播组）。
  final InternetAddress group;

  /// 查询目标端口（默认 5353）。
  final int port;

  /// 每块网卡的查询超时。各网卡同时查询，全部无应答时扫描也只等到这里。
  final Duration timeout;

  /// 组播 TTL。
  final int ttl;

  /// 发现局域网内的 adb 服务。
  ///
  /// [serviceTypes] 默认查询所有三类 adb 服务（legacy 传输、TLS 配对、
  /// TLS 连接）。返回已解析出地址与端口的服务列表。
  ///
  /// [onUpdate] 在窗口结束前就会拿到当时已经解析出的服务，列表会随新应答增长。
  Future<List<MdnsService>> discover({
    Set<String> serviceTypes = const {
      adbServiceTypePairing,
      adbServiceTypeConnect,
      adbServiceTypeTransport,
    },
    void Function(List<MdnsService> services)? onUpdate,
    bool Function(List<MdnsService> services)? stopWhen,
    Duration? requeryInterval,
    bool Function()? isCancelled,
  }) async {
    if (!_isMdnsMulticast(group)) {
      final bind = group.type == InternetAddressType.IPv6
          ? InternetAddress.anyIPv6
          : InternetAddress.anyIPv4;
      return _discoverOn(
        bind,
        serviceTypes,
        onUpdate: onUpdate,
        stopWhen: stopWhen,
        requeryInterval: requeryInterval,
        isCancelled: isCancelled,
      );
    }
    var sockets = <_QuerySocket>[];
    try {
      sockets = await _openLanSockets(untilReady: stopWhen != null);
    } catch (error, stackTrace) {
      _mdnsLog('打开局域网套接字失败：$error\n$stackTrace');
      sockets = <_QuerySocket>[];
    }
    if (sockets.isEmpty) {
      return _discoverOn(
        InternetAddress.anyIPv4,
        serviceTypes,
        onUpdate: onUpdate,
        stopWhen: stopWhen,
        requeryInterval: requeryInterval,
        isCancelled: isCancelled,
      );
    }
    try {
      final found = await _collect(
        sockets,
        serviceTypes,
        lan: true,
        onUpdate: onUpdate,
        stopWhen: stopWhen,
        requeryInterval: requeryInterval,
        isCancelled: isCancelled,
      );
      _mdnsLog(
        found.isEmpty
            ? 'mDNS 扫描结束，没有发现设备'
            : 'mDNS 扫描到 ${found.length} 个：${found.map((service) => '${service.serviceType} ${service.endpointText}').join('；')}',
      );
      return found;
    } finally {
      for (final socket in sockets) {
        socket.socket.close();
      }
    }
  }

  /// 测试里会把查询发到 loopback 的假应答方，不走局域网组播。
  bool _isMdnsMulticast(InternetAddress address) =>
      address.address == kMdnsGroupV4.address ||
      address.address == kMdnsGroupV6.address;

  Future<List<_QuerySocket>> _openLanSockets({bool untilReady = false}) async {
    final sockets = <_QuerySocket>[];
    final interfaces = await NetworkInterface.list(
      includeLinkLocal: true,
      type: InternetAddressType.any,
    );
    final routeKeys = await _readDefaultRouteKeys();
    final outlets = selectConnectableInterfaces(interfaces, routeKeys);
    final skipped = multicastSendInterfaces(
      interfaces,
      InternetAddressType.IPv4,
    ).where((iface) => !outlets.contains(iface));
    final routeMatched = outlets.any(
      (iface) => _matchesDefaultRoute(iface, routeKeys),
    );
    if (routeKeys.isEmpty) {
      _mdnsLog('mDNS 没有读到默认路由，仍查询全部局域网网卡');
    } else if (!routeMatched && outlets.isNotEmpty) {
      _mdnsLog('mDNS 默认路由和网卡对不上，仍查询全部局域网网卡');
    } else if (skipped.isNotEmpty) {
      _mdnsLog(
        'mDNS 跳过网卡：${skipped.map(_ifaceLabel).join('；')}。这些网卡没有默认路由，上面的设备无法连接',
      );
    }
    _mdnsLog(
      outlets.isEmpty
          ? 'mDNS 没有可发送的 IPv4 网卡'
          : untilReady
          ? 'mDNS 发送网卡：${outlets.map(_ifaceLabel).join('；')}。持续监听，发现目标后立即返回'
          : 'mDNS 发送网卡：${outlets.map(_ifaceLabel).join('；')}。同时查询，等待 ${timeout.inMilliseconds} 毫秒',
    );

    final v4 = await _tryBind(InternetAddress.anyIPv4, port, shared: true);
    if (v4 != null) {
      _joinAll(v4, kMdnsGroupV4, outlets);
      sockets.add(_QuerySocket(v4, interfaces: outlets));
    }
    final v6 = await _tryBind(InternetAddress.anyIPv6, port, shared: true);
    if (v6 != null) {
      _joinAll(v6, kMdnsGroupV6, outlets);
      sockets.add(
        _QuerySocket(
          v6,
          interfaces: multicastSendInterfaces(
            outlets,
            InternetAddressType.IPv6,
          ),
        ),
      );
    }

    for (final iface in outlets) {
      for (final address in iface.addresses) {
        if (address.isLoopback || address.isLinkLocal) continue;
        final sender = await _tryBind(address, 0, shared: false);
        if (sender != null) {
          sockets.add(_QuerySocket(sender, interface: iface));
        }
      }
    }
    return sockets;
  }

  Future<RawDatagramSocket?> _tryBind(
    InternetAddress address,
    int bindPort, {
    required bool shared,
  }) async {
    try {
      return await RawDatagramSocket.bind(
        address,
        bindPort,
        reuseAddress: true,
        reusePort: shared && !Platform.isWindows,
        ttl: ttl,
      );
    } on SocketException {
      if (!shared) return null;
      try {
        return await RawDatagramSocket.bind(
          address,
          bindPort,
          reuseAddress: true,
          ttl: ttl,
        );
      } on SocketException {
        return null;
      }
    }
  }

  void _joinAll(
    RawDatagramSocket socket,
    InternetAddress groupAddress,
    List<NetworkInterface> interfaces,
  ) {
    var joined = false;
    final candidates = groupAddress.type == InternetAddressType.IPv4
        ? multicastSendInterfaces(interfaces, InternetAddressType.IPv4)
        : interfaces.where(
            (iface) => iface.addresses.any(
              (address) => address.type == InternetAddressType.IPv6,
            ),
          );
    for (final iface in candidates) {
      try {
        socket.joinMulticast(groupAddress, iface);
        joined = true;
      } catch (error) {
        if (error is! SocketException && error is! OSError) rethrow;
        _mdnsLog('加入组播失败：${iface.name}（$error）');
      }
    }
    if (joined) return;
    try {
      socket.joinMulticast(groupAddress);
    } catch (error) {
      if (error is! SocketException && error is! OSError) rethrow;
      _mdnsLog('加入默认组播失败：$error');
    }
  }

  Future<List<MdnsService>> _discoverOn(
    InternetAddress bindAddr,
    Set<String> serviceTypes, {
    void Function(List<MdnsService> services)? onUpdate,
    bool Function(List<MdnsService> services)? stopWhen,
    Duration? requeryInterval,
    bool Function()? isCancelled,
  }) async {
    final socket = await RawDatagramSocket.bind(
      bindAddr,
      0,
      reuseAddress: true,
      ttl: ttl,
    );
    try {
      return await _collect(
        <_QuerySocket>[_QuerySocket(socket)],
        serviceTypes,
        lan: false,
        onUpdate: onUpdate,
        stopWhen: stopWhen,
        requeryInterval: requeryInterval,
        isCancelled: isCancelled,
      );
    } finally {
      socket.close();
    }
  }

  Future<List<MdnsService>> _collect(
    List<_QuerySocket> sockets,
    Set<String> serviceTypes, {
    required bool lan,
    void Function(List<MdnsService> services)? onUpdate,
    bool Function(List<MdnsService> services)? stopWhen,
    Duration? requeryInterval,
    bool Function()? isCancelled,
  }) async {
    final resolver = _MdnsResolver(serviceTypes: _queryTypes(serviceTypes));
    final subscriptions = <StreamSubscription<RawSocketEvent>>[];
    final completer = Completer<void>();
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete();
    });
    var snapshot = '';
    void finish() {
      if (!completer.isCompleted) completer.complete();
    }

    void noteProgress() {
      final services = resolver.services();
      final next = _serviceSnapshot(services);
      if (next.isEmpty || next == snapshot) return;
      snapshot = next;
      onUpdate?.call(services);
      if (stopWhen?.call(services) ?? false) {
        scheduleMicrotask(finish);
      }
    }

    for (final entry in sockets) {
      final socket = entry.socket;
      subscriptions.add(
        socket.listen((event) {
          if (event != RawSocketEvent.read) return;
          while (true) {
            final datagram = socket.receive();
            if (datagram == null) break;
            resolver.handleDatagram(datagram.data, datagram.address);
          }
          noteProgress();
        }),
      );
    }
    try {
      void sendQueries() {
        for (final entry in sockets) {
          final socket = entry.socket;
          final ipv6 = socket.address.type == InternetAddressType.IPv6;
          final destination = lan
              ? (ipv6 ? kMdnsGroupV6 : kMdnsGroupV4)
              : group;
          final destinationPort = port;
          final unicastResponse = !lan || socket.port != port;
          final outlets = lan
              ? (entry.interface != null
                    ? <NetworkInterface>[entry.interface!]
                    : entry.interfaces)
              : const <NetworkInterface>[];
          if (lan && outlets.isEmpty) continue;
          final rounds = lan ? outlets.length : 1;
          for (var i = 0; i < rounds; i++) {
            if (lan && !selectMulticastInterface(socket, outlets[i])) {
              _mdnsLog('指定组播出口失败：${outlets[i].name}');
              continue;
            }
            for (final type in serviceTypes) {
              final qname = _encodeName('$type.$kMdnsDomain');
              try {
                socket.send(
                  _buildPtrQuery(qname, unicastResponse: unicastResponse),
                  destination,
                  destinationPort,
                );
              } on SocketException {
                _mdnsLog('发送查询失败：$type ${lan ? outlets[i].name : ''}');
              }
            }
          }
        }
      }

      sendQueries();
      final requery = requeryInterval == null
          ? null
          : Timer.periodic(requeryInterval, (_) {
              if (!completer.isCompleted) sendQueries();
            });
      final cancelWatch = isCancelled == null
          ? null
          : Timer.periodic(const Duration(milliseconds: 200), (_) {
              if (isCancelled()) finish();
            });
      if (isCancelled?.call() ?? false) finish();
      try {
        await completer.future;
      } finally {
        requery?.cancel();
        cancelWatch?.cancel();
      }
    } finally {
      timer.cancel();
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    }
    return resolver.services();
  }
}

/// 监听或发送用的一个 UDP 套接字，以及它的组播出口。
class _QuerySocket {
  _QuerySocket(this.socket, {this.interface, this.interfaces = const []});

  final RawDatagramSocket socket;

  /// 绑在某个单播地址上时，查询只从这块网卡出去。
  final NetworkInterface? interface;

  /// 绑在任意地址上的监听套接字：每块网卡各发一次。
  final List<NetworkInterface> interfaces;
}

/// `IPPROTO_IP` / `IPPROTO_IPV6`。
const int _ipprotoIp = 0;
const int _ipprotoIpv6 = 41;

/// Linux 与 Android 的取值和 Windows、macOS 不同。
int _multicastIfOption(InternetAddressType type) {
  final ipv6 = type == InternetAddressType.IPv6;
  if (Platform.isLinux || Platform.isAndroid) return ipv6 ? 17 : 32;
  return 9;
}

/// 把后续组播发送钉在 [iface] 上。失败时返回 false，调用方改试下一块网卡。
bool selectMulticastInterface(
  RawDatagramSocket socket,
  NetworkInterface iface,
) {
  final ipv6 = socket.address.type == InternetAddressType.IPv6;
  try {
    if (ipv6) {
      final data = Uint8List(4);
      ByteData.sublistView(data).setUint32(0, iface.index, Endian.host);
      socket.setRawOption(
        RawSocketOption(
          _ipprotoIpv6,
          _multicastIfOption(InternetAddressType.IPv6),
          data,
        ),
      );
    } else {
      InternetAddress? address;
      for (final candidate in iface.addresses) {
        if (candidate.type != InternetAddressType.IPv4 ||
            candidate.isLoopback ||
            candidate.isLinkLocal ||
            candidate.isMulticast) {
          continue;
        }
        address = candidate;
        break;
      }
      if (address == null) return false;
      socket.setRawOption(
        RawSocketOption(
          _ipprotoIp,
          _multicastIfOption(InternetAddressType.IPv4),
          address.rawAddress,
        ),
      );
    }
    return true;
  } on SocketException {
    return false;
  } on OSError {
    return false;
  }
}

void _mdnsLog(String message) {
  developer.log(message, name: 'fire_adb', level: 1000);
}

String _ifaceLabel(NetworkInterface iface) {
  final addresses = iface.addresses
      .where(
        (address) =>
            address.type == InternetAddressType.IPv4 && !address.isLinkLocal,
      )
      .map((address) => address.address)
      .join(',');
  return '${iface.name} $addresses';
}

Future<Set<String>> _readDefaultRouteKeys() async {
  try {
    if (Platform.isWindows) {
      final result = await Process.run('route', [
        'print',
        '-4',
      ], stdoutEncoding: latin1);
      if (result.exitCode != 0) return <String>{};
      return defaultRouteKeysFromRoutePrint('${result.stdout}');
    }
    if (Platform.isLinux || Platform.isAndroid) {
      final file = File('/proc/net/route');
      if (!await file.exists()) return <String>{};
      return defaultRouteKeysFromProcNetRoute(await file.readAsString());
    }
  } catch (error) {
    _mdnsLog('读取默认路由失败：$error');
  }
  return <String>{};
}

/// 用来判断这轮扫描的结果有没有变，避免同一批应答重复通知界面。
String _serviceSnapshot(List<MdnsService> services) {
  return services
      .map(
        (service) =>
            '${service.serviceType}\t${service.instanceName}\t${service.endpointText}\t${service.txt.entries.map((entry) => '${entry.key}=${entry.value}').join(',')}',
      )
      .join('\n');
}

/// 便捷函数：发现局域网内的 adb 服务（默认查所有三类 adb 服务）。
///
/// 返回通过 mDNS 广播的设备（Android 无线调试）。
///
/// ⚠️ **仅适用于开启「无线调试」的 Android 11+ 设备**。
/// 普通 `adb connect IP:PORT` 建立的连接**不会**被发现。
/// 如需直连已知 IP:PORT，请使用 [adbConnectTcp]。
Future<List<MdnsService>> discoverAdbServices({
  Set<String> serviceTypes = const {
    adbServiceTypeTransport,
    adbServiceTypePairing,
    adbServiceTypeConnect,
  },
  Duration timeout = kMdnsInterfaceTimeout,
  void Function(List<MdnsService> services)? onUpdate,
  bool Function(List<MdnsService> services)? stopWhen,
  Duration? requeryInterval,
  bool Function()? isCancelled,
}) {
  return MdnsBrowser(timeout: timeout).discover(
    serviceTypes: serviceTypes,
    onUpdate: onUpdate,
    stopWhen: stopWhen,
    requeryInterval: requeryInterval,
    isCancelled: isCancelled,
  );
}

// ---------------------------------------------------------------------------
// DNS 报文编解码（仅需要 mDNS 浏览器相关的子集）。
// ---------------------------------------------------------------------------

List<int> _encodeName(String name) {
  final clean = name.endsWith('.') ? name.substring(0, name.length - 1) : name;
  final out = <int>[];
  for (final label in clean.split('.')) {
    if (label.isEmpty) continue;
    out.add(label.length);
    for (final code in label.codeUnits) {
      out.add(code);
    }
  }
  out.add(0);
  return out;
}

/// PTR 查询（ID=0，QDCOUNT=1，QTYPE=PTR）。
///
/// [unicastResponse] 置位 QU，请应答方单播回源端口。从 5353 发出的查询不置位，
/// 应答走组播，由监听 5353 的 socket 接收。
List<int> _buildPtrQuery(List<int> qname, {bool unicastResponse = true}) {
  final out = <int>[];
  out.addAll([0, 0]); // ID
  out.addAll([0, 0]); // Flags（QR=0，标准查询）
  out.addAll([0, 1]); // QDCOUNT
  out.addAll([0, 0]); // ANCOUNT
  out.addAll([0, 0]); // NSCOUNT
  out.addAll([0, 0]); // ARCOUNT
  out.addAll(qname);
  out.addAll([0, 12]); // QTYPE = PTR
  out.addAll(unicastResponse ? [0x80, 0x01] : [0x00, 0x01]);
  return out;
}

const int _dnsTypeA = 1;
const int _dnsTypePtr = 12;
const int _dnsTypeTxt = 16;
const int _dnsTypeAaaa = 28;
const int _dnsTypeSrv = 33;

class _DnsRecord {
  _DnsRecord({
    required this.rname,
    required this.rtype,
    required this.rclass,
    required this.ttl,
    required this.data,
    required this.rdataStart,
    required this.rdlen,
  });

  /// 记录拥有者名称（小写、以 `.` 结尾）。
  final String rname;
  final int rtype;
  final int rclass;
  final int ttl;

  /// 完整报文（用于名称压缩指针的定位）。
  final List<int> data;

  /// rdata 在报文中的绝对偏移。
  final int rdataStart;
  final int rdlen;

  Uint8List get rdata =>
      Uint8List.fromList(data.sublist(rdataStart, rdataStart + rdlen));
}

class _ParsedResponse {
  int flags = 0;
  final List<_DnsRecord> records = [];
}

_ParsedResponse? _parseDnsResponse(List<int> data) {
  if (data.length < 12) return null;
  final message = _ParsedResponse();
  message.flags = _u16(data, 2);
  if ((message.flags & 0x8000) == 0) return null; // 只处理响应（QR=1）

  final qd = _u16(data, 4);
  final an = _u16(data, 6);
  final ns = _u16(data, 8);
  final ar = _u16(data, 10);

  var p = 12;
  for (var i = 0; i < qd; i++) {
    final question = _readName(data, p);
    if (question == null) return null;
    p = question.end + 4; // QTYPE + QCLASS
  }

  final total = an + ns + ar;
  for (var i = 0; i < total; i++) {
    final name = _readName(data, p);
    if (name == null) return null;
    final rtype = _u16(data, name.end);
    final rclass = _u16(data, name.end + 2);
    final ttl = _u32(data, name.end + 4);
    final rdlen = _u16(data, name.end + 8);
    final rdataStart = name.end + 10;
    if (rdataStart + rdlen > data.length) return null;
    message.records.add(
      _DnsRecord(
        rname: name.name,
        rtype: rtype,
        rclass: rclass,
        ttl: ttl,
        data: data,
        rdataStart: rdataStart,
        rdlen: rdlen,
      ),
    );
    p = rdataStart + rdlen;
  }
  return message;
}

class _Name {
  _Name(this.name, this.end);
  final String name;
  final int end;
}

/// 解析 DNS 名称（支持压缩指针），返回小写全名与扫描结束位置。
///
/// [start] 与压缩指针的偏移量都相对整个报文 [data]。
_Name? _readName(List<int> data, int start) {
  final labels = <List<int>>[];
  var p = start;
  var jumped = false;
  var end = -1;
  var hops = 0;
  while (true) {
    if (p >= data.length) return null;
    final len = data[p];
    if (len == 0) {
      p += 1;
      if (!jumped) end = p;
      break;
    }
    if ((len & 0xC0) == 0xC0) {
      if (p + 1 >= data.length) return null;
      final offset = ((len & 0x3F) << 8) | data[p + 1];
      if (offset >= data.length) return null;
      if (!jumped) {
        end = p + 2;
        jumped = true;
      }
      if (++hops > 64) return null; // 防循环
      p = offset;
      continue;
    }
    if ((len & 0xC0) != 0) return null; // 0x40/0x80 保留位
    if (p + 1 + len > data.length) return null;
    labels.add(data.sublist(p + 1, p + 1 + len));
    p += 1 + len;
  }

  final buffer = StringBuffer();
  for (final label in labels) {
    buffer.write(String.fromCharCodes(label));
    buffer.write('.');
  }
  return _Name(buffer.toString().toLowerCase(), end < 0 ? p : end);
}

int _u16(List<int> d, int p) => (d[p] << 8) | d[p + 1];
int _u32(List<int> d, int p) =>
    ((d[p] << 24) | (d[p + 1] << 16) | (d[p + 2] << 8) | d[p + 3]) & 0xffffffff;

Map<String, String> _parseTxt(List<int> data) {
  final properties = <String, String>{};
  var p = 0;
  while (p < data.length) {
    final length = data[p];
    p += 1;
    if (p + length > data.length) break;
    final text = String.fromCharCodes(data.sublist(p, p + length));
    p += length;
    final eq = text.indexOf('=');
    if (eq >= 0) {
      properties[text.substring(0, eq)] = text.substring(eq + 1);
    } else if (text.isNotEmpty) {
      properties[text] = '';
    }
  }
  return properties;
}

// ---------------------------------------------------------------------------
// 记录聚合。
// ---------------------------------------------------------------------------

class _ServiceState {
  String? serviceType;
  String? hostName;
  int? port;
  final Map<String, String> txt = {};
  final List<InternetAddress> addresses = <InternetAddress>[];
}

class _MdnsResolver {
  _MdnsResolver({Set<String>? serviceTypes})
    : serviceTypes = serviceTypes?.toSet();

  /// 本次查询的服务类型集合（`_type._tcp` 形式）；非空时只返回这些类型的服务，
  /// 用于滤掉无关应答（例如应答方对别的查询顺手回带了全部记录）。
  final Set<String>? serviceTypes;

  final Map<String, _ServiceState> _services = {};
  final Map<String, List<InternetAddress>> _hostAddresses = {};

  void handleDatagram(List<int> data, [InternetAddress? sender]) {
    final response = _parseDnsResponse(data);
    if (response == null) return;

    for (final record in response.records) {
      switch (record.rtype) {
        case _dnsTypePtr:
          final target = _readName(record.data, record.rdataStart);
          if (target != null) {
            final state = _services.putIfAbsent(target.name, _ServiceState.new);
            state.serviceType = _serviceTypeFrom(record.rname);
            _noteSender(target.name, sender);
          }
        case _dnsTypeSrv:
          if (record.rdlen < 6) continue;
          final port = _u16(record.data, record.rdataStart + 4);
          final targetName = _readName(record.data, record.rdataStart + 6);
          if (targetName == null) continue;
          final state = _services.putIfAbsent(record.rname, _ServiceState.new);
          state.port = port;
          state.hostName = targetName.name;
          _noteSender(record.rname, sender);
          _noteSender(targetName.name, sender);
        case _dnsTypeTxt:
          _services
              .putIfAbsent(record.rname, _ServiceState.new)
              .txt
              .addAll(_parseTxt(record.rdata));
          _noteSender(record.rname, sender);
        case _dnsTypeA:
          if (record.rdlen != 4) continue;
          _addHostAddress(
            record.rname,
            InternetAddress.fromRawAddress(Uint8List.fromList(record.rdata)),
          );
          _noteSender(record.rname, sender);
        case _dnsTypeAaaa:
          if (record.rdlen != 16) continue;
          _addHostAddress(
            record.rname,
            InternetAddress.fromRawAddress(Uint8List.fromList(record.rdata)),
          );
          _noteSender(record.rname, sender);
      }
    }

    _attachAddresses();
  }

  void _addHostAddress(String name, InternetAddress address) {
    final list = _hostAddresses.putIfAbsent(name, () => <InternetAddress>[]);
    if (list.any((item) => item.address == address.address)) return;
    list.add(address);
  }

  void _noteSender(String name, InternetAddress? sender) {
    if (sender == null || sender.isMulticast || _isUnspecified(sender)) return;
    _addHostAddress(name, sender);
  }

  /// A/AAAA 和报文源地址都挂到对应实例上，再选出可连接的地址。
  void _attachAddresses() {
    for (final instance in _services.keys) {
      final state = _services[instance]!;
      final names = <String>[
        if (state.hostName != null) state.hostName!,
        instance,
      ];
      for (final name in names) {
        for (final address
            in _hostAddresses[name] ?? const <InternetAddress>[]) {
          if (state.addresses.any((item) => item.address == address.address)) {
            continue;
          }
          state.addresses.add(address);
        }
      }
    }
  }

  List<MdnsService> services() {
    final result = <MdnsService>[];
    _services.forEach((instance, state) {
      final address = preferReachableAddress(state.addresses);
      final serviceType = state.serviceType ?? _serviceTypeFrom(instance);
      if (address == null || state.port == null || serviceType == null) {
        return;
      }
      final wanted = serviceTypes;
      if (wanted != null && !wanted.contains(serviceType)) {
        return;
      }
      result.add(
        MdnsService(
          instanceName: instance,
          serviceType: serviceType,
          host: state.hostName ?? '',
          port: state.port!,
          address: address,
          txt: Map.unmodifiable(state.txt),
        ),
      );
    });

    result.sort((a, b) {
      final byType = a.serviceType.compareTo(b.serviceType);
      return byType != 0 ? byType : a.instanceName.compareTo(b.instanceName);
    });
    return result;
  }
}

/// 把服务类型集合归一化为 `_type._tcp` 形式（供查询与过滤使用）。
Set<String>? _queryTypes(Iterable<String> serviceTypes) {
  final normalized = <String>{};
  for (final type in serviceTypes) {
    final clean = type.endsWith('.$kMdnsDomain') ? type : '$type.$kMdnsDomain';
    final st = _serviceTypeFrom(clean);
    if (st != null) normalized.add(st);
  }
  return normalized.isEmpty ? null : normalized;
}

/// 从实例/service 全名 `xxx._adb-tls-pairing._tcp.local.` 中提取 `_type._tcp`。
String? _serviceTypeFrom(String name) {
  final labels = name.split('.');
  for (var i = 0; i + 1 < labels.length; i++) {
    if (labels[i].startsWith('_') && labels[i + 1] == '_tcp') {
      return '${labels[i]}.${labels[i + 1]}';
    }
  }
  return null;
}
