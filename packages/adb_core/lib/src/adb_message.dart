/// ADB 传输层消息与校验。
///
/// 消息 = 24 字节头 + 可选 payload：
/// ```text
/// struct amessage {
///     uint32_t command;      /* 命令常量（SYNC/CNXN/AUTH/OPEN/OKAY/CLSE/WRTE/STLS） */
///     uint32_t arg0;         /* 参数 0（如 AUTH type / local-id） */
///     uint32_t arg1;         /* 参数 1（如 remote-id） */
///     uint32_t data_length;  /* payload 长度（可为 0） */
///     uint32_t data_check;   /* payload 字节求和；协商版本>=SKIP_CHECKSUM 时置 0 */
///     uint32_t magic;        /* command ^ 0xffffffff */
/// };
/// ```
/// 全部字段小端序。参考 AOSP `docs/dev/protocol.md` 与 `transport.cpp:send_packet`。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'adb_commands.dart' as cmd;
import 'adb_exceptions.dart';
import 'adb_stream_reader.dart';

/// payload 校验和：所有字节求和，取低 32 位。
int calculateChecksum(List<int> data) {
  var sum = 0;
  for (final b in data) {
    sum = (sum + (b & 0xff)) & 0xffffffff;
  }
  return sum;
}

/// 解析后的消息头。
class AdbMessageHeader {
  AdbMessageHeader({
    required this.command,
    required this.arg0,
    required this.arg1,
    required this.dataLength,
    required this.dataCheck,
    required this.magic,
  });

  final int command;
  final int arg0;
  final int arg1;
  final int dataLength;
  final int dataCheck;
  final int magic;

  /// magic 必须等于 command ^ 0xffffffff，否则视为无效头。
  bool get isValidMagic => magic == (command ^ 0xffffffff);

  /// 人类可读命令名，未知命令返回十六进制。
  String get commandName => cmd.commandNames[command] ?? command.toRadixString(16);

  /// 从 24 字节解析消息头（小端）。
  factory AdbMessageHeader.parse(Uint8List bytes) {
    if (bytes.length != cmd.messageHeaderSize) {
      throw const FormatException(
          'ADB 消息头必须为 ${cmd.messageHeaderSize} 字节');
    }
    final b = ByteData.sublistView(bytes);
    return AdbMessageHeader(
      command: b.getUint32(0, Endian.little),
      arg0: b.getUint32(4, Endian.little),
      arg1: b.getUint32(8, Endian.little),
      dataLength: b.getUint32(12, Endian.little),
      dataCheck: b.getUint32(16, Endian.little),
      magic: b.getUint32(20, Endian.little),
    );
  }

  @override
  String toString() =>
      '$commandName(arg0=$arg0, arg1=$arg1, len=$dataLength, check=$dataCheck)';
}

/// 一条 ADB 传输层消息。
class AdbMessage {
  AdbMessage(this.command, this.arg0, this.arg1, [List<int>? data])
      : data = Uint8List.fromList(data ?? const []);

  final int command;
  final int arg0;
  final int arg1;
  final Uint8List data;

  /// 本消息 payload 的校验和。
  int get checksum => calculateChecksum(data);

  int get magic => command ^ 0xffffffff;

  /// 编码为线上字节流（头 + payload）。
  ///
  /// [skipChecksum] 为 true 时 data_check 置 0（协议版本协商后 AOSP 的发送行为）。
  Uint8List pack({bool skipChecksum = false}) {
    final head = packHeader(skipChecksum: skipChecksum);
    if (data.isEmpty) {
      return head;
    }
    final out = Uint8List(head.length + data.length);
    out.setAll(0, head);
    out.setAll(head.length, data);
    return out;
  }

  /// 仅编码 24 字节消息头。
  Uint8List packHeader({bool skipChecksum = false}) {
    final b = ByteData(cmd.messageHeaderSize);
    b.setUint32(0, command, Endian.little);
    b.setUint32(4, arg0, Endian.little);
    b.setUint32(8, arg1, Endian.little);
    b.setUint32(12, data.length, Endian.little);
    b.setUint32(16, skipChecksum ? 0 : checksum, Endian.little);
    b.setUint32(20, magic, Endian.little);
    return b.buffer.asUint8List();
  }

  @override
  String toString() {
    final name = cmd.commandNames[command] ?? command.toRadixString(16);
    return 'AdbMessage($name, arg0=$arg0, arg1=$arg1, len=${data.length})';
  }
}

/// 从 [reader] 读取一条完整消息。
///
/// - 校验 magic；
/// - [verifyChecksum] 为 true 时校验 payload 求和（data_check==0 视为跳过）；
/// - 形成 payload 分多段到达，这里负责读满 [dataLength] 字节。
Future<AdbMessage> readAdbMessage(
  AdbSizedReader reader, {
  bool verifyChecksum = true,
}) async {
  final headerBytes = await reader.readExactly(cmd.messageHeaderSize);
  final header = AdbMessageHeader.parse(headerBytes);
  if (!header.isValidMagic) {
    throw AdbInvalidCommandError('无效的消息头（magic 不匹配）',
        header: headerBytes);
  }
  final payload = header.dataLength > 0
      ? await reader.readExactly(header.dataLength)
      : Uint8List(0);
  if (verifyChecksum &&
      header.dataCheck != 0 &&
      calculateChecksum(payload) != header.dataCheck) {
    throw AdbInvalidChecksumError(
        '校验和不匹配：期望 ${header.dataCheck}，实际 ${calculateChecksum(payload)}');
  }
  return AdbMessage(header.command, header.arg0, header.arg1, payload);
}

/// CNXN 系统标识串编码：`<type>:<serial>:<banner>\0`。
Uint8List encodeConnectPayload({
  required String type,
  required String serial,
  required String banner,
}) {
  final body = utf8.encode('$type:$serial:$banner');
  return Uint8List.fromList([...body, 0]);
}