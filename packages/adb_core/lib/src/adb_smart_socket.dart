/// 智能 socket（smartsocket）客户端协议，即 Host 侧 `adb server` 的 5037 端口协议。
///
/// 见 AOSP `docs/dev/services.md`：
/// ```text
/// client: <hex4> <service-name>
/// server: "OKAY"
/// client: <hex4> <service-name>
/// server: "FAIL" <hex4> <reason>
/// ```
library;

import 'dart:convert';
import 'dart:typed_data';

/// 4 位大写十六进制长度前缀（`%04x`）。
String encodeHex4(int length) =>
    length.toRadixString(16).toUpperCase().padLeft(4, '0');

/// 解析 4 位十六进制长度。
int decodeHex4(String hex4) => int.parse(hex4, radix: 16);

/// 编码一条客户端服务请求：`<hex4><service>`。
Uint8List encodeServiceRequest(String service) {
  final body = utf8.encode(service);
  final head = utf8.encode(encodeHex4(body.length));
  return Uint8List.fromList([...head, ...body]);
}

/// 解码服务请求（校验长度前缀）。
String decodeServiceRequest(Uint8List bytes) {
  if (bytes.length < 4) {
    throw const FormatException('服务请求至少需要 4 字节长度前缀');
  }
  final lenText = ascii.decode(bytes.sublist(0, 4));
  final body = utf8.decode(bytes.sublist(4));
  final expected = int.tryParse(lenText, radix: 16);
  if (expected == null) {
    throw FormatException('非法长度前缀: $lenText');
  }
  if (expected != body.length) {
    throw FormatException('长度前缀 $expected 与内容长度 ${body.length} 不符');
  }
  return body;
}

/// 服务请求响应：OKAY 或 FAIL。
class AdbServiceResponse {
  AdbServiceResponse._(this.ok, this.message);

  final bool ok;
  final String message;

  static AdbServiceResponse parse(Uint8List bytes) {
    if (bytes.length < 4) {
      throw const FormatException('响应至少 4 字节');
    }
    final status = ascii.decode(bytes.sublist(0, 4));
    if (status == 'OKAY') {
      return AdbServiceResponse._(true, '');
    }
    if (status == 'FAIL') {
      if (bytes.length < 8) {
        return AdbServiceResponse._(false, '');
      }
      final lenText = ascii.decode(bytes.sublist(4, 8));
      final len = int.tryParse(lenText, radix: 16) ?? 0;
      final rest = bytes.sublist(8);
      final msg = rest.length >= len
          ? utf8.decode(rest.sublist(0, len))
          : '';
      return AdbServiceResponse._(false, msg);
    }
    if (bytes.length < 8) {
      throw FormatException('非法响应状态: $status');
    }
    final lenText = ascii.decode(bytes.sublist(4, 8));
    final len = int.tryParse(lenText, radix: 16) ?? (bytes.length - 8);
    final msg = utf8.decode(bytes.sublist(8, 8 + len));
    return AdbServiceResponse._(false, msg);
  }
}