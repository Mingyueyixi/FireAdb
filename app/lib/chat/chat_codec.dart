import 'dart:typed_data';

import '../appservice/protocol/fire_app_message.dart';
import 'chat_message.dart';

/// 一条投递：先是 JSON，文件再跟一帧原始字节。请求号由调用方分配。
Uint8List encodeChatFrames({
  required int requestId,
  required ChatMessage message,
  Uint8List? fileBytes,
}) {
  final json = FireDataResponse.json(
    name: 'chat.deliver',
    id: requestId,
    body: message.wireJson(),
  ).bytes;
  if (fileBytes == null || fileBytes.isEmpty || message.isText) return json;
  final bytes = FireDataResponse.bytes(
    name: 'chat.bytes',
    id: requestId,
    body: fileBytes,
  ).bytes;
  final all = Uint8List(json.length + bytes.length);
  all.setRange(0, json.length, json);
  all.setRange(json.length, all.length, bytes);
  return all;
}

Uint8List encodeChatOk(int requestId) {
  return FireDataResponse.none(name: 'chat.ok', id: requestId).bytes;
}
