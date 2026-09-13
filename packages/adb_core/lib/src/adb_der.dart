import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// 极简 DER 编解码，用于 RSA 私钥的 PEM（PKCS#1 / PKCS#8）读写。
/// 不与 adb 协议直接交互，仅做本地密钥持久化。

const int derTagBool = 0x01;
const int derTagInteger = 0x02;
const int derTagBitString = 0x03;
const int derTagOctetString = 0x04;
const int derTagObjectIdentifier = 0x06;
const int derTagUtcTime = 0x17;
const int derTagPrintableString = 0x13;
const int derTagSequence = 0x30;
const int derTagSet = 0x31;
const int derTagContext0 = 0xa0;

Uint8List _derEncodeLength(int length) {
  if (length < 0x80) {
    return Uint8List.fromList([length]);
  }
  final bytes = <int>[];
  var remaining = length;
  while (remaining > 0) {
    bytes.insert(0, remaining & 0xff);
    remaining >>= 8;
  }
  if (bytes.length > 0x7f) {
    throw ArgumentError('DER length too large: $length');
  }
  return Uint8List.fromList([0x80 | bytes.length, ...bytes]);
}

Uint8List derEncodeTlv(int tag, Uint8List content) {
  return Uint8List.fromList(
      <int>[tag, ..._derEncodeLength(content.length), ...content]);
}

Uint8List derEncodeInteger(BigInt value) {
  final assertPositive = value >= BigInt.zero
      ? value
      : throw ArgumentError('DER INTEGER must be non-negative here');
  var bytes = bigIntToBigEndianBytes(assertPositive, minLength: 1);
  var start = 0;
  while (start < bytes.length - 1 && bytes[start] == 0) {
    start++;
  }
  bytes = bytes.sublist(start);
  if ((bytes[0] & 0x80) != 0) {
    bytes = Uint8List.fromList([0x00, ...bytes]);
  }
  return derEncodeTlv(derTagInteger, bytes);
}

Uint8List derEncodeSequence(List<Uint8List> children) {
  final content = Uint8List.fromList(
      children.expand((child) => child).toList());
  return derEncodeTlv(derTagSequence, content);
}

Uint8List derEncodeOctetString(Uint8List content) {
  return derEncodeTlv(derTagOctetString, content);
}

/// DER BOOLEAN。DER 中 TRUE 恒为 `0xff`，FALSE 恒为 `0x00`。
Uint8List derEncodeBool(bool value) {
  return derEncodeTlv(derTagBool, Uint8List.fromList([value ? 0xff : 0x00]));
}

/// DER BIT STRING，[content] 为首位字节后的位串内容（走在最前的 unused-bits 由
/// 调用方指定，默认 0）。
Uint8List derEncodeBitString(Uint8List content, {int unusedBits = 0}) {
  return derEncodeTlv(
      derTagBitString, Uint8List.fromList([unusedBits, ...content]));
}

/// DER SET OF，用于 X.501 Name 中的 RelativeDistinguishedName。
Uint8List derEncodeSet(List<Uint8List> children) {
  final content =
      Uint8List.fromList(children.expand((child) => child).toList());
  return derEncodeTlv(derTagSet, content);
}

/// DER OBJECT IDENTIFIER，[arcs] 为点分弧编号列表（如 `[1,2,840,113549,1,1,1]`）。
Uint8List derEncodeOid(List<int> arcs) {
  if (arcs.length < 2 || arcs[0] < 0 || arcs[1] < 0 || arcs[0] > 2 ||
      (arcs[0] < 2 && arcs[1] >= 40)) {
    throw ArgumentError('Invalid OID arcs: $arcs');
  }
  final body = <int>[];
  var first = arcs[0] * 40 + arcs[1];
  final stack = <int>[];
  stack.insert(0, first & 0x7f);
  var v = first >> 7;
  while (v > 0) {
    stack.insert(0, (v & 0x7f) | 0x80);
    v >>= 7;
  }
  body.addAll(stack);
  for (var i = 2; i < arcs.length; i++) {
    final arc = arcs[i];
    if (arc < 0) {
      throw ArgumentError('Invalid negative OID arc: $arc');
    }
    final parts = <int>[];
    parts.insert(0, arc & 0x7f);
    var rest = arc >> 7;
    while (rest > 0) {
      parts.insert(0, (rest & 0x7f) | 0x80);
      rest >>= 7;
    }
    body.addAll(parts);
  }
  return derEncodeTlv(derTagObjectIdentifier, Uint8List.fromList(body));
}

/// 解析 DER OBJECT IDENTIFIER 的内容字节（不含 tag 与长度）为弧编号列表。
List<int> derDecodeOid(List<int> content) {
  if (content.isEmpty) {
    throw FormatException('Empty OID content');
  }
  final arcs = <int>[];
  var value = 0;
  for (final b in content) {
    value = (value << 7) | (b & 0x7f);
    if ((b & 0x80) == 0) {
      arcs.add(value);
      value = 0;
    }
  }
  if (arcs.isEmpty) {
    throw FormatException('OID: no complete sub-identifier');
  }
  final first = arcs[0];
  final firstArc = first < 40 ? 0 : (first < 80 ? 1 : 2);
  final secondArc = first - 40 * firstArc;
  return [firstArc, secondArc, ...arcs.sublist(1)];
}

class DerElement {
  final int tag;
  final Uint8List content;

  const DerElement(this.tag, this.content);

  int get integer =>
      bigIntFromBigEndianBytes(content).remainder(BigInt.from(1 << 31)).toInt();

  /// 将 (tag, content) 重新打包为完整 DER 元素。对 DER 编码（最小编码长度，
  /// definite length）而言，与原字节精确一致，可用于还原 tbsCertificate 原文。
  Uint8List get reencoded => derEncodeTlv(tag, content);
}

class DerParser {
  final Uint8List _bytes;
  int _offset = 0;

  DerParser(this._bytes);

  bool get isNotEmpty => _offset < _bytes.length;

  DerElement read() {
    final tag = _bytes[_offset++];
    final lengthByte = _bytes[_offset++];
    var length = lengthByte;
    if (lengthByte & 0x80 != 0) {
      var count = lengthByte & 0x7f;
      length = 0;
      while (count > 0) {
        length = (length << 8) | _bytes[_offset++];
        count--;
      }
    }
    if (_offset + length > _bytes.length) {
      throw FormatException('DER element exceeds buffer');
    }
    final content = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return DerElement(tag, content);
  }
}

/// 解析一个 SEQUENCE 的内容为字节切片。
Uint8List derReadSequence(Uint8List der) {
  final parser = DerParser(der);
  final element = parser.read();
  if (element.tag != derTagSequence) {
    throw FormatException('Expected DER SEQUENCE, got 0x${element.tag.toRadixString(16)}');
  }
  if (parser.isNotEmpty) {
    throw FormatException('Trailing bytes after DER SEQUENCE');
  }
  return element.content;
}

String encodePem(String label, Uint8List der) {
  final base64Body = base64.encode(der);
  const lineLength = 64;
  final lines = <String>[];
  for (var i = 0; i < base64Body.length; i += lineLength) {
    lines.add(base64Body.substring(i, min(i + lineLength, base64Body.length)));
  }
  return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
}

/// 从 PEM 文本中提取第一个块的内容（DER 字节）与其标签。
({String label, Uint8List der}) decodePem(String pem) {
  final labelMatch =
      RegExp(r'-----BEGIN ([A-Z0-9 ]+)-----\r?\n([\s\S]*?)-----END \1-----\r?\n?')
          .firstMatch(pem);
  if (labelMatch == null) {
    throw FormatException('PEM block not found');
  }
  final label = labelMatch.group(1)!;
  final body = labelMatch.group(2)!.replaceAll(RegExp(r'\s+'), '');
  return (label: label, der: base64.decode(body));
}

/// BigInt -> 大端字节序（无符号）。[minLength] 不足时高位补零。
Uint8List bigIntToBigEndianBytes(BigInt value, {int minLength = 0}) {
  if (value.isNegative) {
    throw ArgumentError('only non-negative BigInt supported');
  }
  final bytes = <int>[];
  if (value == BigInt.zero) {
    bytes.add(0);
  }
  var v = value;
  while (v > BigInt.zero) {
    bytes.insert(0, (v & BigInt.from(0xff)).toInt());
    v = v >> 8;
  }
  var out = Uint8List.fromList(bytes);
  if (out.length < minLength) {
    final padded = Uint8List.fromList(List.filled(minLength - out.length, 0));
    out = Uint8List.fromList([...padded, ...out]);
  }
  return out;
}

/// BigInt -> 小端字节序（无符号）。
Uint8List bigIntToLittleEndianBytes(BigInt value, {int minLength = 0}) {
  final be = bigIntToBigEndianBytes(value, minLength: minLength);
  final le = Uint8List(be.length);
  for (var i = 0; i < be.length; i++) {
    le[i] = be[be.length - 1 - i];
  }
  return le;
}

/// 大端字节序（无符号）-> BigInt。
BigInt bigIntFromBigEndianBytes(List<int> bytes) {
  var result = BigInt.zero;
  for (final b in bytes) {
    result = (result << 8) | BigInt.from(b & 0xff);
  }
  return result;
}

/// 小端字节序（无符号）-> BigInt。
BigInt bigIntFromLittleEndianBytes(List<int> bytes) {
  var result = BigInt.zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    result = (result << 8) | BigInt.from(bytes[i] & 0xff);
  }
  return result;
}

/// 大端字节序（有符号，二进制补码）-> BigInt。
BigInt bigIntFromSignedBigEndianBytes(List<int> bytes) {
  final unsigned = bigIntFromBigEndianBytes(bytes);
  if (bytes.isNotEmpty && (bytes[0] & 0x80) != 0) {
    return unsigned - (BigInt.one << (8 * bytes.length));
  }
  return unsigned;
}

/// 从大端整数其中截取长度固定的字节（用于已存在 buffer，尺寸固有）。
Uint8List fixedBigIntToBigEndian(BigInt value, int length) {
  final raw = bigIntToBigEndianBytes(value);
  if (raw.length > length) {
    throw ArgumentError('value too large for $length bytes');
  }
  final out = Uint8List(length);
  out.setRange(length - raw.length, length, raw);
  return out;
}

/// 从大端整数其中截取长度固定的字节（小端序输出）。
Uint8List fixedBigIntToLittleEndian(BigInt value, int length) {
  final raw = bigIntToLittleEndianBytes(value, minLength: length);
  if (raw.length > length) {
    throw ArgumentError('value too large for $length bytes');
  }
  final out = Uint8List(length);
  out.setAll(0, raw);
  return out;
}