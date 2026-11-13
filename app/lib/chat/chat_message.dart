import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

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
    this.parentSeq = 0,
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

  /// `text`、`image`、`file`、`post` 或 `revise`。
  final String kind;
  final String body;
  final String? filePath;
  final String? mime;
  final int size;
  final int createdAt;

  /// 属于哪一篇帖子。0 表示本身就是一条独立消息或帖子。
  final int parentSeq;

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
    int? parentSeq,
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
      parentSeq: parentSeq ?? this.parentSeq,
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
      parentSeq: parentSeq,
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
      'parentSeq': parentSeq,
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
      parentSeq: _asInt(json['parentSeq']),
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
      parentSeq: _asInt(row['parent_seq']),
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
      'parent_seq': parentSeq,
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
    this.dropped = const <ChatDropped>[],
  });

  final int head;
  final int cursor;
  final List<ChatMessage> messages;
  final List<ChatDropped> dropped;

  Map<String, Object?> toJson({String senderId = ''}) {
    return <String, Object?>{
      'head': head,
      'cursor': cursor,
      'senderId': senderId,
      'messages': <Object?>[for (final message in messages) message.wireJson()],
      if (dropped.isNotEmpty)
        'dropped': <Object?>[for (final item in dropped) item.toJson()],
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
      dropped: ChatDropped.list(json['dropped']),
    );
  }
}

class ChatDropped {
  const ChatDropped(this.senderId, this.seq);

  final String senderId;
  final int seq;

  Map<String, Object?> toJson() {
    return <String, Object?>{'senderId': senderId, 'seq': seq};
  }

  static List<ChatDropped> list(Object? raw) {
    if (raw is! List) return const <ChatDropped>[];
    final items = <ChatDropped>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final seq = _asInt(item['seq']);
      final senderId = '${item['senderId'] ?? ''}';
      if (senderId.isEmpty || seq <= 0) continue;
      items.add(ChatDropped(senderId, seq));
    }
    return items;
  }
}

/// 图片和附件的正文编号。形式是 `chat-img:发送者/内容摘要.后缀`，
/// 不用 file://，以免和本机文件地址撞上。
const chatImageMark = 'chat-img:';
const chatFileMark = 'chat-file:';

bool chatMediaMarked(String body) {
  return body.startsWith(chatImageMark) ||
      body.startsWith(chatFileMark) ||
      body.startsWith('img://') ||
      body.startsWith('file://');
}

/// 只有图片和附件才认编号。普通正文里出现同样的字也不当文件。
/// 编号相对聊天目录，例如 `发送者/md5.jpg`。旧消息仍是 `发送者-序号`。
String? chatMediaId(ChatMessage message) {
  if (message.kind != 'image' && message.kind != 'file') return null;
  final marked = _markedParts(message.body);
  if (marked != null) return marked.$1;
  return '${message.senderId}-${message.seq}';
}

String chatMediaName(ChatMessage message) {
  if (message.kind != 'file') {
    if (message.kind == 'image' && chatMediaMarked(message.body)) return '';
    return message.body;
  }
  final marked = _markedParts(message.body);
  if (marked != null) return marked.$2 ?? '';
  if (chatMediaMarked(message.body)) return '';
  return message.body;
}

String chatMediaRef({
  required bool image,
  required String id,
  String name = '',
}) {
  if (image || name.isEmpty) {
    return '${image ? chatImageMark : chatFileMark}$id';
  }
  return '$chatFileMark$id/$name';
}

String chatMediaHash(List<int> bytes) => md5.convert(bytes).toString();

String chatMediaExt(String name, String? mime) {
  final dot = name.lastIndexOf('.');
  var ext = dot >= 0 && dot + 1 < name.length ? name.substring(dot + 1) : '';
  ext = ext.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (ext.length > 8) ext = ext.substring(0, 8);
  if (ext.isNotEmpty) return ext;
  switch (mime?.toLowerCase()) {
    case 'image/jpeg':
      return 'jpg';
    case 'image/png':
      return 'png';
    case 'image/gif':
      return 'gif';
    case 'image/webp':
      return 'webp';
    default:
      return 'bin';
  }
}

/// 内容没变时编号不变，所以本地有这份文件就不必再向频道主要。
String chatContentId({
  required String senderId,
  required List<int> bytes,
  required String ext,
}) {
  return '$senderId/${chatMediaHash(bytes)}.$ext';
}

(String, String?)? _markedParts(String body) {
  for (final mark in <String>[chatImageMark, chatFileMark, 'img://', 'file://']) {
    if (!body.startsWith(mark)) continue;
    return _splitMedia(body.substring(mark.length));
  }
  return null;
}

(String, String?) _splitMedia(String rest) {
  final parts = rest.split('/');
  if (parts.length >= 2 && _isHashName(parts[1])) {
    final name = parts.length > 2 ? parts.sublist(2).join('/') : null;
    return ('${parts[0]}/${parts[1]}', name);
  }
  final slash = rest.indexOf('/');
  if (slash < 0) return (rest, null);
  final name = rest.substring(slash + 1);
  return (rest.substring(0, slash), name.isEmpty ? null : name);
}

bool _isHashName(String part) {
  final dot = part.lastIndexOf('.');
  if (dot != 32) return false;
  final hash = part.substring(0, dot);
  return RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(hash);
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
