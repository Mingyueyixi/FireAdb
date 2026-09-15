import 'dart:async';
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

  @override
  String toString() => '$instanceName\t$serviceType\t$addressText:$port';
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
/// 通过向 `224.0.0.251:5353` 发送 PTR 查询（QU bit 置位，从临时端口发出，
/// 应答方会单播回源端口，无需加入组播组），收集 PTR / SRV / TXT / A / AAAA
/// 记录并聚合为 [MdnsService]。
///
/// ⚠️ 适用场景说明（给上层 UI / 用户文档参考）：
///
/// ✅ **能发现的设备**：
/// - 开启了 **Android 无线调试** 的设备（Android 11+）
///   - 设置路径：`开发者选项` → `无线调试` → 启用
///   - 设备会广播 `_adb-tls-pairing._tcp`（配对）和/或 `_adb-tls-connect._tcp`（连接）
/// - 部分自定义固件/模拟器主动广播 `_adb._tcp`（legacy 传输）
///
/// ❌ **无法发现的设备**：
/// - 通过 `adb connect 192.168.x.x:5555` 手动连接的设备（纯 TCP，无 mDNS 广播）
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
    this.timeout = const Duration(seconds: 8),
    this.ttl = 1,
  }) : group = group ?? kMdnsGroupV4;

  /// 查询目标（默认 mDNS 组播组）。
  final InternetAddress group;

  /// 查询目标端口（默认 5353）。
  final int port;

  /// 采集窗口时长。
  final Duration timeout;

  /// 组播 TTL。
  final int ttl;

  /// 发现局域网内的 adb 服务。
  ///
  /// [serviceTypes] 默认查询所有三类 adb 服务（legacy 传输、TLS 配对、
  /// TLS 连接）。返回已解析出地址与端口的服务列表。
  Future<List<MdnsService>> discover({
    Set<String> serviceTypes = const {
      adbServiceTypePairing,
      adbServiceTypeConnect,
      adbServiceTypeTransport,
    },
  }) async {
    final results = <MdnsService>[];
    
    // 使用配置的 group 地址进行发现
    results.addAll(await _discoverOn(InternetAddress.anyIPv4, group, serviceTypes));
    
    // 如果 group 是 IPv6，也尝试 IPv6 发现
    if (group.type == InternetAddressType.IPv6) {
      try {
        results.addAll(await _discoverOn(InternetAddress.anyIPv6, group, serviceTypes));
      } catch (_) {
        // 忽略 IPv6 不可用的情况
      }
    }
    
    // 去重
    final seen = <String>{};
    return results.where((s) => seen.add(s.instanceName)).toList();
  }

  Future<List<MdnsService>> _discoverOn(
    InternetAddress bindAddr,
    InternetAddress groupAddr,
    Set<String> serviceTypes,
  ) async {
    final socket = await RawDatagramSocket.bind(
        bindAddr, 0, reuseAddress: true, ttl: ttl);
    try {
      final resolver =
          _MdnsResolver(serviceTypes: _queryTypes(serviceTypes));
      final subscription = socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = socket.receive();
          if (datagram != null) {
            resolver.handleDatagram(datagram.data);
          }
        }
      });

      final completer = Completer<void>();
      final timer = Timer(timeout, () {
        if (!completer.isCompleted) completer.complete();
      });
      try {
        for (final type in serviceTypes) {
          final qname = _encodeName('$type.$kMdnsDomain');
          socket.send(_buildPtrQuery(qname), groupAddr, port);
        }
        await completer.future;
      } finally {
        timer.cancel();
        subscription.cancel();
      }
      return resolver.services();
    } finally {
      socket.close();
    }
  }
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
  Duration timeout = const Duration(seconds: 8),
}) {
  return MdnsBrowser(timeout: timeout).discover(serviceTypes: serviceTypes);
}

// ---------------------------------------------------------------------------
// DNS 报文编解码（仅需要 mDNS 浏览器相关的子集）。
// ---------------------------------------------------------------------------

List<int> _encodeName(String name) {
  final clean =
      name.endsWith('.') ? name.substring(0, name.length - 1) : name;
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

/// PTR 查询（ID=0，QDCOUNT=1，QTYPE=PTR，QCLASS=IN|QU）。
List<int> _buildPtrQuery(List<int> qname) {
  final out = <int>[];
  out.addAll([0, 0]); // ID
  out.addAll([0, 0]); // Flags（QR=0，标准查询）
  out.addAll([0, 1]); // QDCOUNT
  out.addAll([0, 0]); // ANCOUNT
  out.addAll([0, 0]); // NSCOUNT
  out.addAll([0, 0]); // ARCOUNT
  out.addAll(qname);
  out.addAll([0, 12]); // QTYPE = PTR
  out.addAll([0x80, 0x01]); // QCLASS = IN(1) | QU(1<<15)
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
    message.records.add(_DnsRecord(
      rname: name.name,
      rtype: rtype,
      rclass: rclass,
      ttl: ttl,
      data: data,
      rdataStart: rdataStart,
      rdlen: rdlen,
    ));
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
  InternetAddress? v4;
  InternetAddress? v6;
}

class _MdnsResolver {
  _MdnsResolver({Set<String>? serviceTypes}) : serviceTypes = serviceTypes?.toSet();

  /// 本次查询的服务类型集合（`_type._tcp` 形式）；非空时只返回这些类型的服务，
  /// 用于滤掉无关应答（例如应答方对别的查询顺手回带了全部记录）。
  final Set<String>? serviceTypes;

  final Map<String, _ServiceState> _services = {};
  final Map<String, InternetAddress> _hostAddresses = {};

  void handleDatagram(List<int> data) {
    final response = _parseDnsResponse(data);
    if (response == null) return;

    for (final record in response.records) {
      switch (record.rtype) {
        case _dnsTypePtr:
          final target = _readName(record.data, record.rdataStart);
          if (target != null) {
            final state = _services.putIfAbsent(
                target.name, _ServiceState.new);
            state.serviceType = _serviceTypeFrom(record.rname);
          }
        case _dnsTypeSrv:
          if (record.rdlen < 6) continue;
          final port = _u16(record.data, record.rdataStart + 4);
          final targetName = _readName(record.data, record.rdataStart + 6);
          if (targetName == null) continue;
          final state =
              _services.putIfAbsent(record.rname, _ServiceState.new);
          state.port = port;
          state.hostName = targetName.name;
        case _dnsTypeTxt:
          _services
              .putIfAbsent(record.rname, _ServiceState.new)
              .txt
              .addAll(_parseTxt(record.rdata));
        case _dnsTypeA:
          if (record.rdlen != 4) continue;
          _hostAddresses[record.rname] = InternetAddress.fromRawAddress(
              Uint8List.fromList(record.rdata));
        case _dnsTypeAaaa:
          if (record.rdlen != 16) continue;
          _hostAddresses[record.rname] = InternetAddress.fromRawAddress(
              Uint8List.fromList(record.rdata));
      }
    }

    _attachAddresses();
  }

  /// A/AAAA 记录归属主机名，把解析出的地址倒灌回对应实例。
  void _attachAddresses() {
    for (final instance in _services.keys) {
      final state = _services[instance]!;
      final candidates = <String>[
        if (state.hostName != null) state.hostName!,
        instance,
      ];
      for (final name in candidates) {
        final addr = _hostAddresses[name];
        if (addr == null) continue;
        if (addr.type == InternetAddressType.IPv4) {
          state.v4 ??= addr;
        } else {
          state.v6 ??= addr;
        }
      }
    }
  }

  List<MdnsService> services() {
    final result = <MdnsService>[];
    _services.forEach((instance, state) {
      final address = state.v4 ?? state.v6;
      final serviceType = state.serviceType ?? _serviceTypeFrom(instance);
      if (address == null || state.port == null || serviceType == null) {
        return;
      }
      final wanted = serviceTypes;
      if (wanted != null && !wanted.contains(serviceType)) {
        return;
      }
      result.add(MdnsService(
        instanceName: instance,
        serviceType: serviceType,
        host: state.hostName ?? '',
        port: state.port!,
        address: address,
        txt: Map.unmodifiable(state.txt),
      ));
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