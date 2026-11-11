import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'chat_conversation.dart';

const String kDefaultChatGroup = 'default';

/// 一条消息。编号 [seq] 由记录的持有方按会话自增，删除不回收。
class ChatMessage {
  const ChatMessage({
    required this.seq,
    required this.groupId,
    required this.senderId,
    required this.senderName,
    required this.kind,
    required this.body,
    required this.createdAt,
    this.filePath,
    this.mime,
    this.size = 0,
    this.pending = false,
    this.deleted = false,
    this.conversation,
    this.people = const <ChatPerson>[],
    this.bytes,
  });

  final int seq;
  final String groupId;
  final String senderId;
  final String senderName;

  /// `text`、`image` 或 `file`。
  final String kind;
  final String body;
  final String? filePath;
  final String? mime;
  final int size;
  final int createdAt;

  /// 私聊里对方还没拉到。
  final bool pending;
  final bool deleted;

  /// 随消息带上的会话资料。只走线路，不进消息表。
  final ChatConversation? conversation;

  /// 随消息带上的成员。只走线路，不进消息表。
  final List<ChatPerson> people;

  /// 线路上带的文件字节。入库前写成文件。
  final Uint8List? bytes;

  String get id => '$senderId:$seq';

  bool get isText => kind == 'text';

  ChatMessage copyWith({
    String? filePath,
    bool? pending,
    int? size,
    bool? deleted,
    Uint8List? bytes,
  }) {
    return ChatMessage(
      seq: seq,
      groupId: groupId,
      senderId: senderId,
      senderName: senderName,
      kind: kind,
      body: body,
      createdAt: createdAt,
      filePath: filePath ?? this.filePath,
      mime: mime,
      size: size ?? this.size,
      pending: pending ?? this.pending,
      deleted: deleted ?? this.deleted,
      conversation: conversation,
      people: people,
      bytes: bytes ?? this.bytes,
    );
  }

  ChatMessage withRoom(ChatConversation? room, List<ChatPerson> roster) {
    return ChatMessage(
      seq: seq,
      groupId: groupId,
      senderId: senderId,
      senderName: senderName,
      kind: kind,
      body: body,
      createdAt: createdAt,
      filePath: filePath,
      mime: mime,
      size: size,
      pending: pending,
      deleted: deleted,
      conversation: room ?? conversation,
      people: roster.isEmpty ? people : roster,
      bytes: bytes,
    );
  }

  Map<String, Object?> wireJson() {
    final room = conversation;
    return <String, Object?>{
      'seq': seq,
      'groupId': groupId,
      'senderId': senderId,
      'senderName': senderName,
      'kind': kind,
      'body': body,
      'mime': mime ?? '',
      'size': size,
      'createdAt': createdAt,
      'conversationKind': room?.kind ?? '',
      'conversationTitle': room?.title ?? '',
      'ownerId': room?.ownerId ?? '',
      'peerSerial': room?.peerSerial ?? '',
      'members': <Object?>[for (final person in people) person.toJson()],
      if (bytes != null && bytes!.isNotEmpty) 'data': base64Encode(bytes!),
    };
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final seq = _asInt(json['seq'] ?? json['id']);
    final groupId = '${json['groupId'] ?? kDefaultChatGroup}';
    final createdAt = _asInt(json['createdAt']);
    final roomKind = '${json['conversationKind'] ?? ''}';
    final encoded = '${json['data'] ?? ''}';
    return ChatMessage(
      seq: seq,
      groupId: groupId,
      senderId: '${json['senderId'] ?? ''}',
      senderName: '${json['senderName'] ?? ''}',
      kind: '${json['kind'] ?? 'text'}',
      body: '${json['body'] ?? ''}',
      filePath: _optional(json['filePath']),
      mime: _optional(json['mime']),
      size: _asInt(json['size']),
      createdAt: createdAt,
      deleted: json['deleted'] == true || _asInt(json['deleted']) != 0,
      conversation: roomKind.isEmpty
          ? null
          : ChatConversation(
              id: groupId,
              kind: roomKind,
              title: '${json['conversationTitle'] ?? ''}',
              ownerId: '${json['ownerId'] ?? ''}',
              peerSerial: _optional(json['peerSerial']),
              createdAt: createdAt,
              updatedAt: createdAt,
            ),
      people: _people(json['members']),
      bytes: encoded.isEmpty ? null : Uint8List.fromList(base64Decode(encoded)),
    );
  }

  factory ChatMessage.fromRow(Map<String, Object?> row) {
    return ChatMessage(
      seq: _asInt(row['seq']),
      groupId: '${row['group_id']}',
      senderId: '${row['sender_id']}',
      senderName: '${row['sender_name']}',
      kind: '${row['kind']}',
      body: '${row['body']}',
      filePath: _optional(row['file_path']),
      mime: _optional(row['mime']),
      size: _asInt(row['size']),
      createdAt: _asInt(row['created_at']),
      pending: _asInt(row['pending']) != 0,
      deleted: _asInt(row['deleted']) != 0,
    );
  }

  Map<String, Object?> toRow() {
    return <String, Object?>{
      'group_id': groupId,
      'sender_id': senderId,
      'seq': seq,
      'sender_name': senderName,
      'kind': kind,
      'body': body,
      'file_path': filePath,
      'mime': mime,
      'size': size,
      'created_at': createdAt,
      'deleted': deleted ? 1 : 0,
    };
  }
}

/// 一次拉取：活着的消息，以及调用方应拨到的位置。
class ChatSlice {
  const ChatSlice({
    required this.head,
    required this.cursor,
    required this.messages,
  });

  final int head;
  final int cursor;
  final List<ChatMessage> messages;

  Map<String, Object?> toJson({String senderId = ''}) {
    return <String, Object?>{
      'head': head,
      'cursor': cursor,
      'senderId': senderId,
      'messages': <Object?>[for (final message in messages) message.wireJson()],
    };
  }

  factory ChatSlice.fromJson(Map<String, dynamic> json) {
    final raw = json['messages'];
    final messages = <ChatMessage>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          messages.add(ChatMessage.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return ChatSlice(
      head: _asInt(json['head']),
      cursor: _asInt(json['cursor']),
      messages: messages,
    );
  }
}

String newChatId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

List<ChatPerson> _people(Object? value) {
  if (value is! List) return const <ChatPerson>[];
  final people = <ChatPerson>[];
  for (final item in value) {
    if (item is Map) people.add(ChatPerson.fromJson(item));
  }
  return people;
}

String? _optional(Object? value) {
  final text = value?.toString() ?? '';
  return text.isEmpty ? null : text;
}

int _asInt(Object? value) {
  if (value is int) return value;
  return int.tryParse('$value') ?? 0;
}
