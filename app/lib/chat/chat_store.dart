import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'chat_conversation.dart';
import 'chat_message.dart';

const int _keep = 300;
const int chatPullLimit = 50;
const int chatDatabaseVersion = 3;

Future<void> ensureChatDatabase() async {
  if (Platform.isAndroid) return;
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}

class ChatStore {
  ChatStore(this._database, this.filesDir);

  final Database _database;
  final String filesDir;

  static Future<ChatStore> open() async {
    await ensureChatDatabase();
    final directory = await getDatabasesPath();
    final filesDir = p.join(directory, 'chat-files');
    await Directory(filesDir).create(recursive: true);
    final database = await openDatabase(
      p.join(directory, 'fireadb_chat.db'),
      version: chatDatabaseVersion,
      onCreate: (database, version) => _create(database),
      onUpgrade: (database, oldVersion, newVersion) =>
          _upgrade(database, oldVersion),
    );
    return ChatStore(database, filesDir);
  }

  /// 测试用内存库。调用前要先 [ensureChatDatabase]。
  static Future<ChatStore> memory() async {
    final database = await openDatabase(
      inMemoryDatabasePath,
      version: chatDatabaseVersion,
      onCreate: (database, version) => _create(database),
    );
    return ChatStore(database, '');
  }

  static Future<void> _create(Database database) async {
    await _createMessages(database);
    await _createRooms(database);
    await _createSync(database);
  }

  static Future<void> _upgrade(Database database, int oldVersion) async {
    if (oldVersion < 2) await _createRooms(database);
    if (oldVersion < 3) {
      await _migrateMessages(database);
      await _createSync(database);
    }
  }

  static Future<void> _createMessages(Database database) async {
    await database.execute('''
      CREATE TABLE chat_message (
        group_id TEXT NOT NULL,
        sender_id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        sender_name TEXT NOT NULL,
        kind TEXT NOT NULL,
        body TEXT NOT NULL,
        file_path TEXT,
        mime TEXT,
        size INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (group_id, sender_id, seq)
      )
    ''');
    await database.execute(
      'CREATE INDEX IF NOT EXISTS chat_message_group_time ON chat_message(group_id, created_at)',
    );
  }

  static Future<void> _migrateMessages(Database database) async {
    final exists = await database.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'chat_message'",
    );
    if (exists.isEmpty) {
      await _createMessages(database);
      return;
    }
    final columns = await database.rawQuery('PRAGMA table_info(chat_message)');
    final names = <String>[for (final column in columns) '${column['name']}'];
    if (names.contains('seq')) return;
    await database.execute(
      'ALTER TABLE chat_message RENAME TO chat_message_old',
    );
    await database.execute('DROP INDEX IF EXISTS chat_message_group_time');
    await _createMessages(database);
    final rows = await database.query(
      'chat_message_old',
      orderBy: 'created_at ASC',
    );
    final counters = <String, int>{};
    for (final row in rows) {
      final key = '${row['group_id']}\n${row['sender_id']}';
      final seq = (counters[key] ?? 0) + 1;
      counters[key] = seq;
      await database.insert('chat_message', <String, Object?>{
        'group_id': row['group_id'],
        'sender_id': row['sender_id'],
        'seq': seq,
        'sender_name': row['sender_name'],
        'kind': row['kind'],
        'body': row['body'],
        'file_path': row['file_path'],
        'mime': row['mime'],
        'size': row['size'] ?? 0,
        'created_at': row['created_at'],
        'deleted': 0,
      });
    }
    await database.execute('DROP TABLE chat_message_old');
  }

  static Future<void> _createRooms(Database database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS chat_conversation (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        title TEXT NOT NULL,
        owner_id TEXT NOT NULL,
        peer_serial TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS chat_member (
        conversation_id TEXT NOT NULL,
        member_id TEXT NOT NULL,
        name TEXT NOT NULL,
        role TEXT NOT NULL,
        PRIMARY KEY (conversation_id, member_id)
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS chat_route (
        conversation_id TEXT NOT NULL,
        serial TEXT NOT NULL,
        PRIMARY KEY (conversation_id, serial)
      )
    ''');
  }

  static Future<void> _createSync(Database database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS chat_cursor (
        conversation_id TEXT NOT NULL,
        peer TEXT NOT NULL,
        cursor INTEGER NOT NULL,
        PRIMARY KEY (conversation_id, peer)
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS chat_hidden (
        conversation_id TEXT NOT NULL,
        sender_id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        PRIMARY KEY (conversation_id, sender_id, seq)
      )
    ''');
  }

  /// 已有同号消息时不再插入。返回是否是新的。
  Future<bool> insert(ChatMessage message) async {
    final rowId = await _database.insert(
      'chat_message',
      message.toRow(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return rowId != 0;
  }

  Future<int> nextSeq(String conversationId, {String? senderId}) async {
    return await head(conversationId, senderId: senderId) + 1;
  }

  /// 含已删除号在内的最大编号。没有消息时是 0。
  Future<int> head(String conversationId, {String? senderId}) async {
    final rows = await _database.rawQuery(
      senderId == null
          ? '''
            SELECT COALESCE(MAX(seq), 0) AS head
            FROM chat_message WHERE group_id = ?
            '''
          : '''
            SELECT COALESCE(MAX(seq), 0) AS head
            FROM chat_message WHERE group_id = ? AND sender_id = ?
            ''',
      senderId == null
          ? <Object>[conversationId]
          : <Object>[conversationId, senderId],
    );
    final value = rows.single['head'];
    if (value is int) return value;
    return int.tryParse('$value') ?? 0;
  }

  /// 跳过已删除的号。[cursor] 是这次拨到的位置，可能比最后一条活消息更大。
  Future<ChatSlice> page(
    String conversationId, {
    required int after,
    String? senderId,
    int limit = chatPullLimit,
  }) async {
    final top = await head(conversationId, senderId: senderId);
    final where = StringBuffer(
      'group_id = ? AND seq > ? AND deleted = 0',
    );
    final args = <Object>[conversationId, after];
    if (senderId != null) {
      where.write(' AND sender_id = ?');
      args.add(senderId);
    }
    args.add(limit);
    final rows = await _database.rawQuery(
      '''
      SELECT * FROM chat_message
      WHERE $where
      ORDER BY seq ASC
      LIMIT ?
      ''',
      args,
    );
    final messages = rows.map(ChatMessage.fromRow).toList();
    final cursor = messages.length >= limit ? messages.last.seq : top;
    return ChatSlice(head: top, cursor: cursor, messages: messages);
  }

  Future<void> markDeleted(
    String conversationId,
    String senderId,
    int seq,
  ) {
    return _database.update(
      'chat_message',
      <String, Object>{'deleted': 1},
      where: 'group_id = ? AND sender_id = ? AND seq = ?',
      whereArgs: <Object>[conversationId, senderId, seq],
    );
  }

  Future<void> hide(String conversationId, String senderId, int seq) {
    return _database.insert('chat_hidden', <String, Object>{
      'conversation_id': conversationId,
      'sender_id': senderId,
      'seq': seq,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<bool> isHidden(String conversationId, String senderId, int seq) async {
    final rows = await _database.query(
      'chat_hidden',
      where: 'conversation_id = ? AND sender_id = ? AND seq = ?',
      whereArgs: <Object>[conversationId, senderId, seq],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<int> cursor(String conversationId, String peer) async {
    final rows = await _database.query(
      'chat_cursor',
      columns: <String>['cursor'],
      where: 'conversation_id = ? AND peer = ?',
      whereArgs: <Object>[conversationId, peer],
      limit: 1,
    );
    if (rows.isEmpty) return 0;
    final value = rows.single['cursor'];
    if (value is int) return value;
    return int.tryParse('$value') ?? 0;
  }

  Future<void> setCursor(String conversationId, String peer, int cursor) async {
    if (cursor < 0) return;
    final current = await this.cursor(conversationId, peer);
    if (cursor < current) return;
    await _database.insert('chat_cursor', <String, Object>{
      'conversation_id': conversationId,
      'peer': peer,
      'cursor': cursor,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> retarget(String from, String to) async {
    if (from == to) return;
    await _database.update(
      'chat_message',
      <String, Object>{'group_id': to},
      where: 'group_id = ?',
      whereArgs: <Object>[from],
    );
  }

  Future<List<ChatMessage>> latest({
    String groupId = kDefaultChatGroup,
    String selfId = '',
  }) async {
    final rows = await _database.rawQuery(
      '''
      SELECT m.*,
        CASE
          WHEN c.cursor IS NOT NULL AND m.sender_id = ? AND m.seq > c.cursor
          THEN 1 ELSE 0
        END AS pending
      FROM chat_message m
      LEFT JOIN chat_cursor c
        ON c.conversation_id = m.group_id AND c.peer = 'ack'
      WHERE m.group_id = ?
        AND NOT EXISTS (
          SELECT 1 FROM chat_hidden h
          WHERE h.conversation_id = m.group_id
            AND h.sender_id = m.sender_id
            AND h.seq = m.seq
        )
      ORDER BY m.created_at DESC, m.seq DESC
      LIMIT ?
      ''',
      <Object>[selfId, groupId, _keep],
    );
    return rows.reversed.map(ChatMessage.fromRow).toList();
  }

  Future<void> ensureConversation(
    ChatConversation conversation, {
    bool overwrite = false,
  }) async {
    final rows = await _database.query(
      'chat_conversation',
      where: 'id = ?',
      whereArgs: <Object>[conversation.id],
    );
    if (rows.isEmpty) {
      await _database.insert('chat_conversation', conversation.toRow());
      return;
    }
    if (!overwrite) return;
    await _database.update(
      'chat_conversation',
      <String, Object?>{
        'kind': conversation.kind,
        'title': conversation.title,
        'owner_id': conversation.ownerId,
        'peer_serial': conversation.peerSerial,
        'updated_at': conversation.updatedAt,
      },
      where: 'id = ?',
      whereArgs: <Object>[conversation.id],
    );
  }

  Future<void> renameConversation(String id, String title, int updatedAt) {
    return _database.update(
      'chat_conversation',
      <String, Object>{'title': title, 'updated_at': updatedAt},
      where: 'id = ?',
      whereArgs: <Object>[id],
    );
  }

  Future<void> touch(String id, int updatedAt) {
    return _database.update(
      'chat_conversation',
      <String, Object>{'updated_at': updatedAt},
      where: 'id = ?',
      whereArgs: <Object>[id],
    );
  }

  Future<ChatConversation?> conversation(String id) async {
    final rows = await _database.query(
      'chat_conversation',
      where: 'id = ?',
      whereArgs: <Object>[id],
    );
    if (rows.isEmpty) return null;
    return ChatConversation.fromRow(rows.single);
  }

  Future<List<ChatConversation>> conversations() async {
    final rows = await _database.rawQuery('''
      SELECT c.*,
        (
          SELECT body FROM chat_message m
          WHERE m.group_id = c.id
            AND NOT EXISTS (
              SELECT 1 FROM chat_hidden h
              WHERE h.conversation_id = m.group_id
                AND h.sender_id = m.sender_id
                AND h.seq = m.seq
            )
          ORDER BY m.created_at DESC
          LIMIT 1
        ) AS last_body,
        (
          SELECT sender_name FROM chat_message m
          WHERE m.group_id = c.id
            AND NOT EXISTS (
              SELECT 1 FROM chat_hidden h
              WHERE h.conversation_id = m.group_id
                AND h.sender_id = m.sender_id
                AND h.seq = m.seq
            )
          ORDER BY m.created_at DESC
          LIMIT 1
        ) AS last_sender,
        (
          SELECT created_at FROM chat_message m
          WHERE m.group_id = c.id
            AND NOT EXISTS (
              SELECT 1 FROM chat_hidden h
              WHERE h.conversation_id = m.group_id
                AND h.sender_id = m.sender_id
                AND h.seq = m.seq
            )
          ORDER BY m.created_at DESC
          LIMIT 1
        ) AS last_at,
        (
          SELECT kind FROM chat_message m
          WHERE m.group_id = c.id
            AND NOT EXISTS (
              SELECT 1 FROM chat_hidden h
              WHERE h.conversation_id = m.group_id
                AND h.sender_id = m.sender_id
                AND h.seq = m.seq
            )
          ORDER BY m.created_at DESC
          LIMIT 1
        ) AS last_kind
      FROM chat_conversation c
      ORDER BY c.updated_at DESC
    ''');
    return rows.map(ChatConversation.fromRow).toList();
  }

  Future<List<ChatPerson>> membersOf(String id) async {
    final rows = await _database.query(
      'chat_member',
      where: 'conversation_id = ?',
      whereArgs: <Object>[id],
    );
    return rows.map(ChatPerson.fromRow).toList();
  }

  Future<void> upsertMember(String conversationId, ChatPerson person) async {
    if (person.id.isEmpty) return;
    final rows = await _database.query(
      'chat_member',
      where: 'conversation_id = ? AND member_id = ?',
      whereArgs: <Object>[conversationId, person.id],
    );
    if (rows.isEmpty) {
      await _database.insert('chat_member', <String, Object>{
        'conversation_id': conversationId,
        'member_id': person.id,
        'name': person.name,
        'role': person.role,
      });
      return;
    }
    final current = ChatPerson.fromRow(rows.single);
    final name = person.name.isEmpty ? current.name : person.name;
    final role = current.isOwner ? kChatOwner : person.role;
    await _database.update(
      'chat_member',
      <String, Object>{'name': name, 'role': role},
      where: 'conversation_id = ? AND member_id = ?',
      whereArgs: <Object>[conversationId, person.id],
    );
  }

  Future<void> setMembers(
    String conversationId,
    List<ChatPerson> people,
  ) async {
    final batch = _database.batch();
    batch.delete(
      'chat_member',
      where: 'conversation_id = ?',
      whereArgs: <Object>[conversationId],
    );
    for (final person in people) {
      if (person.id.isEmpty) continue;
      batch.insert('chat_member', <String, Object>{
        'conversation_id': conversationId,
        'member_id': person.id,
        'name': person.name,
        'role': person.role,
      });
    }
    await batch.commit(noResult: true);
  }

  Future<void> removeMember(String conversationId, String memberId) {
    return _database.delete(
      'chat_member',
      where: 'conversation_id = ? AND member_id = ? AND role != ?',
      whereArgs: <Object>[conversationId, memberId, kChatOwner],
    );
  }

  Future<void> renameMember(String memberId, String name) {
    if (name.isEmpty) return Future<void>.value();
    return _database.update(
      'chat_member',
      <String, Object>{'name': name},
      where: 'member_id = ?',
      whereArgs: <Object>[memberId],
    );
  }

  Future<void> addRoute(String conversationId, String serial) {
    if (conversationId.isEmpty || serial.isEmpty) return Future<void>.value();
    return _database.insert('chat_route', <String, Object>{
      'conversation_id': conversationId,
      'serial': serial,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<String>> routes(String conversationId) async {
    final rows = await _database.query(
      'chat_route',
      columns: <String>['serial'],
      where: 'conversation_id = ?',
      whereArgs: <Object>[conversationId],
    );
    return <String>[for (final row in rows) '${row['serial']}'];
  }

  Future<String> saveBytes(String id, Uint8List bytes) async {
    final path = p.join(filesDir, id);
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  Future<String> copyIn(String id, String source) async {
    final path = p.join(filesDir, id);
    await File(source).copy(path);
    return path;
  }

  Future<void> close() => _database.close();
}
