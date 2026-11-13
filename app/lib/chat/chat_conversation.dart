const String kChatChannel = 'channel';
const String kChatDirect = 'dm';
const String kChatGroup = 'group';
const String kChatOwner = 'owner';
const String kChatMemberRole = 'member';

/// 我主持的频道。同一台 FireAdb 上稳定不变。
String myChannelId(String selfId) => 'channel:$selfId';

/// 本机和某一台设备的私聊。
String directChatId(String selfId, String serial) => 'dm:$selfId:$serial';

/// 频道或私聊。成员单独存放。
class ChatConversation {
  const ChatConversation({
    required this.id,
    required this.kind,
    required this.title,
    required this.ownerId,
    required this.createdAt,
    required this.updatedAt,
    this.peerSerial,
    this.lastBody,
    this.lastSender,
    this.lastAt = 0,
    this.lastKind,
    this.unread = 0,
    this.closed = false,
  });

  final String id;

  /// [kChatChannel]、[kChatDirect]。较早的记录里还有 [kChatGroup]，界面上同样当作频道。
  final String kind;
  final String title;
  final String ownerId;

  /// 私聊对方的设备序列号。
  final String? peerSerial;
  final int createdAt;
  final int updatedAt;
  final String? lastBody;
  final String? lastSender;
  final int lastAt;
  final String? lastKind;
  final int unread;

  /// 频道主已经解散。记录还留在本机，但不能再发帖。
  final bool closed;

  bool ownedBy(String selfId) => ownerId == selfId && kind != kChatDirect;

  bool isMyChannel(String selfId) => id == myChannelId(selfId);

  ChatConversation copyWith({int? updatedAt}) {
    return ChatConversation(
      id: id,
      kind: kind,
      title: title,
      ownerId: ownerId,
      peerSerial: peerSerial,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastBody: lastBody,
      lastSender: lastSender,
      lastAt: lastAt,
      lastKind: lastKind,
      unread: unread,
      closed: closed,
    );
  }

  Map<String, Object?> toRow() {
    return <String, Object?>{
      'id': id,
      'kind': kind,
      'title': title,
      'owner_id': ownerId,
      'peer_serial': peerSerial,
      'created_at': createdAt,
      'updated_at': updatedAt,
    };
  }

  factory ChatConversation.fromRow(Map<String, Object?> row) {
    return ChatConversation(
      id: '${row['id']}',
      kind: '${row['kind']}',
      title: '${row['title'] ?? ''}',
      ownerId: '${row['owner_id'] ?? ''}',
      peerSerial: _optional(row['peer_serial']),
      createdAt: _asInt(row['created_at']),
      updatedAt: _asInt(row['updated_at']),
      lastBody: _optional(row['last_body']),
      lastSender: _optional(row['last_sender']),
      lastAt: _asInt(row['last_at']),
      lastKind: _optional(row['last_kind']),
      unread: _asInt(row['unread']),
      closed: _asInt(row['closed']) > 0,
    );
  }
}

/// 会话里的一个人。设备成员的 [id] 是 adb 序列号，本机是自己的标识。
class ChatPerson {
  const ChatPerson({required this.id, required this.name, required this.role});

  final String id;
  final String name;
  final String role;

  bool get isOwner => role == kChatOwner;

  Map<String, Object?> toJson() {
    return <String, Object?>{'id': id, 'name': name, 'role': role};
  }

  factory ChatPerson.fromJson(Map<dynamic, dynamic> json) {
    final role = '${json['role'] ?? ''}';
    return ChatPerson(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      role: role.isEmpty ? kChatMemberRole : role,
    );
  }

  factory ChatPerson.fromRow(Map<String, Object?> row) {
    return ChatPerson(
      id: '${row['member_id']}',
      name: '${row['name'] ?? ''}',
      role: '${row['role'] ?? kChatMemberRole}',
    );
  }
}

String? _optional(Object? value) {
  final text = value?.toString() ?? '';
  return text.isEmpty ? null : text;
}

int _asInt(Object? value) {
  if (value is int) return value;
  return int.tryParse('$value') ?? 0;
}
