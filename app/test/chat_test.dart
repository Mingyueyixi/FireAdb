import 'dart:typed_data';

import 'package:fireadb/appservice/protocol/fire_app_message.dart';
import 'package:fireadb/chat/chat_codec.dart';
import 'package:fireadb/chat/chat_conversation.dart';
import 'package:fireadb/chat/chat_message.dart';
import 'package:fireadb/chat/chat_post.dart';
import 'package:fireadb/chat/chat_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('群聊帧保留 emoji，文件帧跟在 JSON 后面', () {
    const text = '你好 😀';
    final message = ChatMessage(
      seq: 1,
      groupId: kDefaultChatGroup,
      senderId: 'self',
      senderName: '本机',
      kind: 'text',
      body: text,
      createdAt: 10,
    );
    final frames = encodeChatFrames(requestId: 3, message: message);
    final parsed = FireDataResponseReader().add(frames).single;
    expect(parsed.name, 'chat.deliver');
    expect(parsed.json['body'], text);

    final file = ChatMessage(
      seq: 2,
      groupId: kDefaultChatGroup,
      senderId: 'self',
      senderName: '本机',
      kind: 'image',
      body: 'a.png',
      mime: 'image/png',
      size: 4,
      createdAt: 11,
      bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
    );
    final both = encodeChatFrames(
      requestId: 4,
      message: file,
      fileBytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
    );
    final parts = FireDataResponseReader().add(both);
    expect(parts, hasLength(2));
    expect(parts[0].json['body'], 'a.png');
    expect(parts[1].name, 'chat.bytes');
    expect(parts[1].body, <int>[1, 2, 3, 4]);
  });

  test('SQLite 按自增号记下消息，删除留下空号', () async {
    await ensureChatDatabase();
    final store = await ChatStore.memory();
    try {
      Future<ChatMessage> text(int seq, String body) {
        return Future<ChatMessage>.value(
          ChatMessage(
            seq: seq,
            groupId: 'channel:me',
            senderId: 'self',
            senderName: '本机',
            kind: 'text',
            body: body,
            createdAt: seq,
          ),
        );
      }

      expect(await store.insert(await text(1, '一')), isTrue);
      expect(await store.insert(await text(1, '一')), isFalse);
      await store.insert(await text(2, '二'));
      await store.insert(await text(3, '三'));
      await store.setCursor('channel:me', 'ack', 0);
      expect((await store.latest(groupId: 'channel:me', selfId: 'self')).last.pending, isTrue);
      await store.markDeleted('channel:me', 'self', 2);
      final slice = await store.page('channel:me', after: 0);
      expect(slice.messages.map((message) => message.seq), <int>[1, 3]);
      expect(slice.head, 3);
      expect(slice.cursor, 3);
      await store.hide('channel:me', 'self', 1);
      final visible = await store.latest(groupId: 'channel:me', selfId: 'self');
      expect(visible.map((message) => message.body), <String>['二', '三']);
      await store.setCursor('channel:me', 'ack', 3);
      final settled = await store.latest(groupId: 'channel:me', selfId: 'self');
      expect(settled.last.pending, isFalse);
    } finally {
      await store.close();
    }
  });

  test('我的频道、私聊和群分开保存，旧消息并进我的频道', () async {
    await ensureChatDatabase();
    final store = await ChatStore.memory();
    try {
      final old = ChatMessage(
        seq: 1,
        groupId: kDefaultChatGroup,
        senderId: 'self',
        senderName: '本机',
        kind: 'text',
        body: '以前的',
        createdAt: 1,
      );
      expect(await store.insert(old), isTrue);
      await store.retarget(kDefaultChatGroup, 'channel:me');
      final now = 20;
      await store.ensureConversation(
        ChatConversation(
          id: 'channel:me',
          kind: kChatChannel,
          title: '',
          ownerId: 'me',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await store.upsertMember(
        'channel:me',
        const ChatPerson(id: 'me', name: '本机', role: kChatOwner),
      );
      await store.upsertMember(
        'channel:me',
        const ChatPerson(id: 'serial-a', name: '手机', role: kChatMemberRole),
      );
      await store.addRoute('channel:me', 'serial-a');
      await store.ensureConversation(
        ChatConversation(
          id: 'dm:me:serial-a',
          kind: kChatDirect,
          title: '手机',
          ownerId: 'me',
          peerSerial: 'serial-a',
          createdAt: now,
          updatedAt: now + 1,
        ),
      );

      final mine = await store.latest(groupId: 'channel:me');
      expect(mine.single.body, '以前的');
      final rooms = await store.conversations();
      expect(rooms.first.id, 'dm:me:serial-a');
      expect(rooms.last.lastBody, '以前的');
      expect(await store.membersOf('channel:me'), hasLength(2));
      expect(await store.routes('channel:me'), <String>['serial-a']);
      await store.removeMember('channel:me', 'serial-a');
      await store.removeMember('channel:me', 'me');
      final left = await store.membersOf('channel:me');
      expect(left.single.id, 'me');
      expect(left.single.isOwner, isTrue);

      final wire = ChatMessage(
        seq: 2,
        groupId: 'channel:me',
        senderId: 'me',
        senderName: '本机',
        kind: 'text',
        body: '你好 😀',
        createdAt: 30,
        conversation: rooms.last,
        people: left,
      );
      final parsed = FireDataResponseReader()
          .add(encodeChatFrames(requestId: 5, message: wire))
          .single;
      expect(parsed.json['conversationKind'], kChatChannel);
      expect(parsed.json['body'], '你好 😀');
      final restored = ChatMessage.fromJson(parsed.json);
      expect(restored.seq, 2);
      expect(restored.conversation?.ownerId, 'me');
      expect(restored.people.single.isOwner, isTrue);
    } finally {
      await store.close();
    }
  });

  test('帖子正文是纯文字，旧的图片标记不留在正文里', () async {
    expect(decodePost(encodePost('今天的图')), '今天的图');
    expect(
      decodePost(
        '{"title":"你好","markdown":"**重点**\\n[[image:8]]\\n[链接](https://example.com)"}',
      ),
      '你好\n重点\n链接',
    );

    await ensureChatDatabase();
    final store = await ChatStore.memory();
    try {
      final saved = await store.insert(
        ChatMessage(
          seq: 8,
          groupId: 'channel:me',
          senderId: 'self',
          senderName: '本机',
          kind: kChatPost,
          body: encodePost('你好'),
          parentSeq: 0,
          createdAt: 1,
        ),
      );
      expect(saved, isTrue);
      final loaded = (await store.page('channel:me', after: 0)).messages.single;
      expect(loaded.parentSeq, 0);
      expect(decodePost(loaded.body), '你好');
    } finally {
      await store.close();
    }
  });

  test('别人的新消息算未读，打开后清掉；缺文件可以补上路径', () async {
    await ensureChatDatabase();
    final store = await ChatStore.memory();
    try {
      final now = 20;
      await store.ensureConversation(
        ChatConversation(
          id: 'channel:me',
          kind: kChatChannel,
          title: '',
          ownerId: 'me',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await store.insert(
        ChatMessage(
          seq: 1,
          groupId: 'channel:me',
          senderId: 'phone',
          senderName: '手机',
          kind: 'text',
          body: '新的',
          createdAt: 30,
        ),
      );
      await store.insert(
        ChatMessage(
          seq: 2,
          groupId: 'channel:me',
          senderId: 'me',
          senderName: '本机',
          kind: 'text',
          body: '自己的',
          createdAt: 31,
        ),
      );
      await store.insert(
        ChatMessage(
          seq: 3,
          groupId: 'channel:me',
          senderId: 'phone',
          senderName: '手机',
          kind: 'image',
          body: 'a.png',
          createdAt: 32,
        ),
      );
      expect((await store.conversations(selfId: 'me')).single.unread, 2);
      await store.markSeen('channel:me');
      expect((await store.conversations(selfId: 'me')).single.unread, 0);
      expect((await store.missingFiles('channel:me')).single.seq, 3);
      await store.saveFile('channel:me', 'phone', 3, 'kept.png', 4);
      expect(await store.missingFiles('channel:me'), isEmpty);
      expect((await store.messageOf('channel:me', 'phone', 3))?.filePath, 'kept.png');
    } finally {
      await store.close();
    }
  });
}
