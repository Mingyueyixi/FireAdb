/// 与浏览器同进程的假 mDNS 应答方（测试替身）。
///
/// 绑定 loopback 指定端口，收到查询后用一条**真实 DNS 报文**单播回请求方
/// （RFC 6762 对非 5353 源端口的应答即单播）。报文用手工编码器按真实应答方
/// 的顺序构造，并写名称压缩指针，确保被测解析器真正走压缩路径。
///
/// 与 `fake_adbd.dart` 一样：所有构造与身份信息都在本文件内，测试只负责断言。
/// 用法见 `mdns_test.dart`。
library;

import 'dart:io';
import 'dart:typed_data';

/// 假设备拓扑：一台配对服务的模拟器。
const String kFakeServiceFqdn = '_adb-tls-pairing._tcp.local.';
const String kFakeInstanceFqdn = 'my-emulator._adb-tls-pairing._tcp.local.';
const String kFakeHostFqdn = 'my-emulator.local.';
const int kFakePairPort = 39017;

/// DNS 名称编码（多标签、无压缩指针、尾零终止）。
///
/// 仅用于构造测试报文，自己带一份实现，不依赖库内私有编码器。
List<int> _encodeName(String name) {
  final clean = name.endsWith('.') ? name.substring(0, name.length - 1) : name;
  final out = <int>[];
  for (final label in clean.split('.')) {
    if (label.isEmpty) continue;
    out.add(label.length);
    out.addAll(label.codeUnits);
  }
  out.add(0);
  return out;
}

/// DNS 报文手工构造器：记录名称首现的报文内偏移，重复出现时写压缩指针
/// （0xC0 前导），与真实 mDNS 应答方一致。
class _Writer {
  final List<int> _buf = [];
  final Map<String, int> _offsets = {};

  List<int> get bytes => _buf;

  /// 追加一个名称：首次出现写完整标签序列，之后写压缩指针。
  void name(String name) {
    final key = name.toLowerCase();
    final offset = _offsets[key];
    if (offset != null) {
      _buf.add(0xC0 | (offset >> 8));
      _buf.add(offset & 0xff);
      return;
    }
    _offsets[key] = _buf.length;
    _buf.addAll(_encodeName(name));
  }

  /// 声明某个名称在报文中 [atOffset] 处已有完整编码（例如作为另一条记录的
  /// rdata 的一部分），后续 [name] 出现即可用压缩指针引用它。
  void nameAt(String name, int atOffset) {
    _offsets[name.toLowerCase()] = atOffset;
  }

  void u16(int value) {
    _buf.add((value >> 8) & 0xff);
    _buf.add(value & 0xff);
  }

  void u32(int value) {
    _buf.add((value >> 24) & 0xff);
    _buf.add((value >> 16) & 0xff);
    _buf.add((value >> 8) & 0xff);
    _buf.add(value & 0xff);
  }

  void addAll(List<int> values) => _buf.addAll(values);
}

List<int> _instanceRdata() => _encodeName(kFakeInstanceFqdn);

List<int> _txtRdata() {
  final entries = ['v=1', 'name=Emulator', 'api=31'];
  return [
    for (final entry in entries) ...[entry.length, ...entry.codeUnits],
  ];
}

/// 构造一条 mDNS 响应：AN = PTR + SRV + TXT，AR = A。
/// 名称按真实应答方的顺序出现：instance 首现于 PTR 的 rdata，
/// host 首现于 SRV 的 rdata，之后用压缩指针引用。
Uint8List buildPairingResponse({int port = kFakePairPort, List<int>? aaaa}) {
  final w = _Writer();
  w.addAll([0, 0, 0x84, 0x00]);
  w.addAll([0, 0]); // QDCOUNT
  w.addAll([0, 3]); // ANCOUNT
  w.addAll([0, 0]); // NSCOUNT
  w.addAll([0, aaaa == null ? 1 : 2]); // ARCOUNT

  // PTR：rname = service，rdata = instance（首现）
  w.addAll(_encodeName(kFakeServiceFqdn));
  w.u16(12);
  w.u16(0x0001);
  w.u32(4500);
  w.u16(_instanceRdata().length);
  final instanceAnchor = w.bytes.length;
  w.addAll(_instanceRdata());
  w.nameAt(kFakeInstanceFqdn, instanceAnchor);

  // SRV：instance rname 用压缩指针，host 在 rdata 首现
  w.name(kFakeInstanceFqdn);
  w.u16(33);
  w.u16(0x0001);
  w.u32(120);
  final srvFixed = [0, 0, 0, 0, (port >> 8) & 0xff, port & 0xff];
  final hostBytes = _encodeName(kFakeHostFqdn);
  final hostAnchor = w.bytes.length + 2 + srvFixed.length; // 2 = rdlen 字段
  w.u16(srvFixed.length + hostBytes.length);
  w.addAll(srvFixed);
  w.addAll(hostBytes);
  w.nameAt(kFakeHostFqdn, hostAnchor);

  // TXT：instance rname 用压缩指针
  w.name(kFakeInstanceFqdn);
  w.u16(16);
  w.u16(0x8001);
  w.u32(4500);
  w.u16(_txtRdata().length);
  w.addAll(_txtRdata());

  // A（附加区）：host rname 用压缩指针
  w.name(kFakeHostFqdn);
  w.u16(1);
  w.u16(0x0001);
  w.u32(120);
  w.u16(4);
  w.addAll([10, 0, 2, 2]);

  if (aaaa != null) {
    w.name(kFakeHostFqdn);
    w.u16(28);
    w.u16(0x0001);
    w.u32(120);
    w.u16(aaaa.length);
    w.addAll(aaaa);
  }

  return Uint8List.fromList(w.bytes);
}

/// 启动一个假应答方，返回其句柄；调用方应记得 [FakeMdnsResponder.close]。
///
/// [port] 为 loopback 监听端口，传 0 表示由系统分配（用 [FakeMdnsResponder.port]
/// 读取）。收到查询即回一条 [buildPairingResponse]。
Future<FakeMdnsResponder> spawnFakeResponder(
  int port, {
  Uint8List? response,
}) async {
  final socket = await RawDatagramSocket.bind(
    InternetAddress.loopbackIPv4,
    port,
    reuseAddress: true,
  );
  final packet = response ?? buildPairingResponse();
  socket.listen((event) {
    if (event == RawSocketEvent.read) {
      final datagram = socket.receive();
      if (datagram == null) return;
      socket.send(packet, datagram.address, datagram.port);
    }
  });
  return FakeMdnsResponder(socket);
}

class FakeMdnsResponder {
  FakeMdnsResponder(this.socket);

  final RawDatagramSocket socket;

  int get port => socket.port;

  Future<void> close() async => socket.close();
}
