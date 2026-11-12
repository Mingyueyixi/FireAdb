import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../appservice/fire_app_session.dart';
import '../appservice/protocol/fire_app_message.dart';
import '../connection/connection_manager.dart';
import '../connection/model/connected_device.dart';
import '../connection/model/device_profile.dart';
import '../link/device_link.dart';
import '../log/app_log.dart';
import 'chat_bridge.dart';
import 'chat_conversation.dart';
import 'chat_message.dart';
import 'chat_store.dart';

const String _selfIdKey = 'chatSelfId';
const String _migratedKey = 'chatMigratedDefault';
const int _pullRounds = 20;

class ChatMember {
  const ChatMember({
    required this.serial,
    required this.name,
    required this.role,
    required this.online,
    required this.self,
  });

  final String serial;
  final String name;
  final String role;
  final bool online;
  final bool self;
}

/// 频道和群的完整记录在主持的这台 FireAdb 上，成员来拉。
/// 私聊只在本机和那一台设备之间传递。
class ChatController extends GetxController with WidgetsBindingObserver {
  ChatController({this._store, ChatBridge? bridge})
    : _bridge = bridge ?? ChatBridge();

  final ChatStore? _store;
  final ChatBridge _bridge;
  ChatStore? _opened;

  final conversations = <ChatConversation>[].obs;
  final messages = <ChatMessage>[].obs;
  final members = <ChatMember>[].obs;
  final selfId = ''.obs;
  final activeId = ''.obs;

  String _selfName = '';
  var _memberToken = 0;
  final _reader = FireDataResponseReader();
  final _deviceChain = <String, Future<void>>{};
  Future<void> _bridgeChain = Future<void>.value();
  Future<void> _sendChain = Future<void>.value();
  Completer<ChatSlice>? _batchWait;
  Completer<ChatMessage>? _acceptWait;

  ChatStore get store => _opened!;

  ConnectionManager get _manager => Get.find<ConnectionManager>();

  Future<void> init() async {
    _opened = _store ?? await ChatStore.open();
    final preferences = await SharedPreferences.getInstance();
    final existing = preferences.getString(_selfIdKey);
    if (existing == null || existing.isEmpty) {
      final created = newChatId();
      await preferences.setString(_selfIdKey, created);
      selfId.value = created;
    } else {
      selfId.value = existing;
    }
    await _ensureMine(preferences);
    await reload();
    WidgetsBinding.instance.addObserver(this);
    DeviceLink.onAppFrame = (serial, frame) {
      final previous = _deviceChain[serial] ?? Future<void>.value();
      _deviceChain[serial] = previous
          .catchError((Object _) {})
          .then((_) => _onDeviceFrame(serial, frame));
    };
    if (_bridge.available) {
      _bridge.listen(_onBridgeChunk, onLinked: () => unawaited(_announceSelf()));
      unawaited(_connectBridge());
    }
    for (final device in _manager.devices) {
      unawaited(onDeviceConnected(device.serial));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(reload());
    if (_bridge.available) unawaited(_connectBridge());
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    super.onClose();
  }

  Future<void> _ensureMine(SharedPreferences preferences) async {
    final id = myChannelId(selfId.value);
    if (!(preferences.getBool(_migratedKey) ?? false)) {
      await store.retarget(kDefaultChatGroup, id);
      await preferences.setBool(_migratedKey, true);
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    await store.ensureConversation(
      ChatConversation(
        id: id,
        kind: kChatChannel,
        title: '',
        ownerId: selfId.value,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await store.upsertMember(
      id,
      ChatPerson(id: selfId.value, name: _selfName, role: kChatOwner),
    );
  }

  void useSelfName(String name) {
    if (_selfName == name) return;
    _selfName = name;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_selfName != name || selfId.value.isEmpty) return;
      unawaited(_applySelfName(name));
    });
  }

  Future<void> _applySelfName(String name) async {
    await store.renameMember(selfId.value, name);
    await store.upsertMember(
      myChannelId(selfId.value),
      ChatPerson(id: selfId.value, name: name, role: kChatOwner),
    );
    refreshMembers();
  }

  void refreshMembers() {
    final id = activeId.value;
    if (id.isEmpty) {
      members.clear();
      return;
    }
    unawaited(_loadMembers(id));
  }

  Future<void> _loadMembers(String id) async {
    final token = ++_memberToken;
    final people = await store.membersOf(id);
    final routes = await store.routes(id);
    if (token != _memberToken || activeId.value != id) return;
    final visible = <ChatPerson>[
      for (final person in people)
        if (_visible(person)) person,
    ];
    visible.sort((a, b) {
      final rank = _rank(a).compareTo(_rank(b));
      if (rank != 0) return rank;
      return a.name.compareTo(b.name);
    });
    members.assignAll(<ChatMember>[
      for (final person in visible)
        ChatMember(
          serial: person.id,
          name: person.id == selfId.value && _selfName.isNotEmpty
              ? _selfName
              : (person.name.isEmpty ? person.id : person.name),
          role: person.role,
          online: _reachable(person, routes),
          self: person.id == selfId.value,
        ),
    ]);
  }

  int _rank(ChatPerson person) {
    if (person.isOwner) return 0;
    if (person.id == selfId.value) return 1;
    return 2;
  }

  bool _visible(ChatPerson person) {
    if (person.id == selfId.value || person.isOwner) return true;
    return _isDevice(person.id);
  }

  bool _reachable(ChatPerson person, List<String> routes) {
    if (person.id == selfId.value) return true;
    if (_manager.isConnected(person.id)) return true;
    if (!person.isOwner) return false;
    for (final serial in routes) {
      if (_manager.isConnected(serial)) return true;
    }
    return false;
  }

  bool _isDevice(String id) {
    if (id.isEmpty || id == selfId.value) return false;
    if (_manager.deviceOf(id) != null) return true;
    for (final profile in _manager.history) {
      if (profile.serial == id) return true;
    }
    for (final profile in _manager.profiles) {
      if (profile.serial == id) return true;
    }
    return false;
  }

  Future<void> reload() async {
    final listed = await store.conversations();
    final mine = <ChatConversation>[];
    final rest = <ChatConversation>[];
    for (final item in listed) {
      if (item.isMyChannel(selfId.value)) {
        mine.add(item);
      } else {
        rest.add(item);
      }
    }
    conversations.assignAll(<ChatConversation>[...mine, ...rest]);
    final id = activeId.value;
    if (id.isEmpty) {
      messages.clear();
      return;
    }
    messages.assignAll(
      await store.latest(groupId: id, selfId: selfId.value),
    );
    refreshMembers();
  }

  Future<void> openConversation(String id) async {
    if (activeId.value != id) {
      activeId.value = id;
      messages.clear();
      members.clear();
    }
    await reload();
    final room = await store.conversation(id);
    if (room == null || room.ownedBy(selfId.value)) return;
    if (room.kind == kChatDirect) return;
    try {
      await _pullRoom(room);
    } catch (error, stack) {
      log.warning('拉取聊天失败', error, stack);
    }
  }

  Future<String> createGroup(String title) async {
    final name = title.trim();
    if (name.isEmpty) return '';
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = newChatId();
    await store.ensureConversation(
      ChatConversation(
        id: id,
        kind: kChatGroup,
        title: name,
        ownerId: selfId.value,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await store.upsertMember(
      id,
      ChatPerson(id: selfId.value, name: _selfName, role: kChatOwner),
    );
    await openConversation(id);
    return id;
  }

  Future<String> startDirect(String serial, String name) async {
    for (final item in conversations) {
      if (item.kind == kChatDirect && item.peerSerial == serial) {
        await openConversation(item.id);
        return item.id;
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = directChatId(selfId.value, serial);
    await store.ensureConversation(
      ChatConversation(
        id: id,
        kind: kChatDirect,
        title: name,
        ownerId: selfId.value,
        peerSerial: serial,
        createdAt: now,
        updatedAt: now + 1,
      ),
    );
    await store.upsertMember(
      id,
      ChatPerson(id: selfId.value, name: _selfName, role: kChatMemberRole),
    );
    await store.upsertMember(
      id,
      ChatPerson(id: serial, name: name, role: kChatMemberRole),
    );
    await store.addRoute(id, serial);
    await store.setCursor(id, 'ack', 0);
    await openConversation(id);
    return id;
  }

  Future<void> renameConversation(String id, String title) async {
    final name = title.trim();
    final room = await store.conversation(id);
    if (name.isEmpty || room == null || !room.ownedBy(selfId.value)) return;
    await store.renameConversation(
      id,
      name,
      DateTime.now().millisecondsSinceEpoch,
    );
    await reload();
  }

  Future<void> addMember(String id, String serial, String name) async {
    final room = await store.conversation(id);
    if (room == null || !room.ownedBy(selfId.value)) return;
    if (serial.isEmpty || serial == selfId.value) return;
    await store.upsertMember(
      id,
      ChatPerson(id: serial, name: name, role: kChatMemberRole),
    );
    await store.addRoute(id, serial);
    refreshMembers();
    if (_manager.isConnected(serial)) {
      await _hint(serial, room, fromSelf: false);
    }
  }

  Future<void> removeMember(String id, String memberId) async {
    final room = await store.conversation(id);
    if (room == null || !room.ownedBy(selfId.value)) return;
    if (memberId == selfId.value) return;
    await store.removeMember(id, memberId);
    refreshMembers();
  }

  /// 本机不再显示。还没拉到的成员下次会跳过这个号；已经收下的保持原样。
  Future<void> deleteMessage(ChatMessage message) async {
    await store.hide(message.groupId, message.senderId, message.seq);
    final room = await store.conversation(message.groupId);
    if (room == null) {
      await reload();
      return;
    }
    if (room.kind == kChatDirect) {
      if (message.senderId == selfId.value) {
        final ack = await store.cursor(room.id, 'ack');
        if (message.seq > ack) {
          await store.markDeleted(message.groupId, message.senderId, message.seq);
        }
      }
    } else if (room.ownedBy(selfId.value)) {
      await store.markDeleted(message.groupId, message.senderId, message.seq);
    } else {
      await _askDelete(room, message);
    }
    await reload();
  }

  List<DeviceProfile> knownDevices() {
    final profiles = <String, DeviceProfile>{};
    for (final profile in _manager.history) {
      profiles[profile.serial] = profile;
    }
    for (final profile in _manager.profiles) {
      profiles[profile.serial] = profile;
    }
    final values = profiles.values.toList();
    values.sort((a, b) {
      final online = _manager.isConnected(a.serial) ? 0 : 1;
      final other = _manager.isConnected(b.serial) ? 0 : 1;
      if (online != other) return online.compareTo(other);
      return a.displayName.compareTo(b.displayName);
    });
    return values;
  }

  Future<void> sendText(String text) {
    final body = text.trim();
    final groupId = activeId.value;
    if (body.isEmpty || groupId.isEmpty) return Future<void>.value();
    return _enqueue(
      () => _send(
        ChatMessage(
          seq: 0,
          groupId: groupId,
          senderId: selfId.value,
          senderName: _selfName,
          kind: 'text',
          body: body,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ),
    );
  }

  Future<void> sendFile({
    required String path,
    required String name,
    String? mime,
  }) {
    final groupId = activeId.value;
    if (groupId.isEmpty) return Future<void>.value();
    return _enqueue(() async {
      final kind = _kindFor(name, mime);
      final size = await File(path).length();
      await _send(
        ChatMessage(
          seq: 0,
          groupId: groupId,
          senderId: selfId.value,
          senderName: _selfName,
          kind: kind,
          body: name,
          filePath: path,
          mime: mime,
          size: size,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    });
  }

  Future<void> onDeviceConnected(String serial) async {
    refreshMembers();
    final device = _manager.deviceOf(serial);
    if (device == null) return;
    try {
      await DeviceLink.open(device);
    } catch (error, stack) {
      log.warning('聊天通道没有打开', error, stack);
    }
  }

  Future<void> onDeviceDisconnected(String serial) async {
    await DeviceLink.close(serial);
    releaseChatHold(serial);
    refreshMembers();
  }

  Future<void> _send(ChatMessage draft) async {
    final room = await store.conversation(draft.groupId);
    if (room == null) return;
    if (room.kind == kChatDirect) {
      await _sendDirect(room, draft);
      return;
    }
    if (room.ownedBy(selfId.value)) {
      await _sendHosted(room, draft);
      return;
    }
    await _sendToHost(room, draft);
  }

  Future<void> _sendHosted(ChatConversation room, ChatMessage draft) async {
    final seq = await store.nextSeq(room.id);
    final message = await _stored(draft, seq);
    await store.insert(message);
    await store.touch(room.id, message.createdAt);
    await reload();
    await _hintMembers(room, fromSelf: false);
  }

  Future<void> _sendDirect(ChatConversation room, ChatMessage draft) async {
    final seq = await store.nextSeq(room.id, senderId: selfId.value);
    final message = await _stored(draft, seq);
    await store.insert(message);
    await store.setCursor(room.id, 'ack', await store.cursor(room.id, 'ack'));
    await store.touch(room.id, message.createdAt);
    await reload();
    final serial = room.peerSerial ?? '';
    if (serial.isEmpty) return;
    await _hint(serial, room, fromSelf: true);
    if (_bridge.available) {
      await _bridgeSend(
        'chat.deliver',
        (await _withBytes(message)).wireJson(),
      );
    }
  }

  Future<void> _sendToHost(ChatConversation room, ChatMessage draft) async {
    final body = (await _withBytes(draft)).wireJson();
    final serial = await _connectedHost(room);
    ChatMessage accepted;
    if (serial != null) {
      final reply = await _exchange(
        serial,
        (id) => FireDataRequest.json(name: 'chat.submit', id: id, body: body),
      );
      if (reply.name != 'chat.accepted') {
        throw StateError(reply.errorText('聊天没有写入服务端'));
      }
      accepted = ChatMessage.fromJson(reply.json);
    } else if (_bridge.available) {
      final waiter = Completer<ChatMessage>();
      _acceptWait = waiter;
      try {
        if (!await _bridgeSend('chat.submit', body)) {
          throw StateError('聊天通道还没接上');
        }
        accepted = await waiter.future.timeout(const Duration(seconds: 20));
      } finally {
        if (identical(_acceptWait, waiter)) _acceptWait = null;
      }
    } else {
      throw StateError('会话服务端不在线');
    }
    var message = accepted;
    final bytes = accepted.bytes;
    if (bytes != null && bytes.isNotEmpty) {
      final path = await store.saveBytes(
        '${accepted.senderId}-${accepted.seq}',
        bytes,
      );
      message = accepted.copyWith(filePath: path, size: bytes.length);
    }
    await store.insert(message);
    await store.touch(room.id, message.createdAt);
    await reload();
  }

  Future<void> _askDelete(ChatConversation room, ChatMessage message) async {
    final body = <String, Object?>{
      'conversationId': message.groupId,
      'senderId': message.senderId,
      'seq': message.seq,
    };
    final serial = await _connectedHost(room);
    if (serial != null) {
      await _exchange(
        serial,
        (id) => FireDataRequest.json(name: 'chat.delete', id: id, body: body),
      );
      return;
    }
    if (_bridge.available) {
      await _bridgeSend('chat.delete', body);
    }
  }

  Future<ChatMessage> _stored(ChatMessage draft, int seq) async {
    var filePath = draft.filePath;
    if (!draft.isText &&
        filePath != null &&
        store.filesDir.isNotEmpty &&
        !pEqualsDir(filePath, store.filesDir)) {
      filePath = await store.copyIn('${draft.senderId}-$seq', filePath);
    }
    return _withBytes(
      ChatMessage(
        seq: seq,
        groupId: draft.groupId,
        senderId: draft.senderId,
        senderName: draft.senderName,
        kind: draft.kind,
        body: draft.body,
        filePath: filePath,
        mime: draft.mime,
        size: draft.size,
        createdAt: draft.createdAt,
      ),
    );
  }

  Future<ChatMessage> _withBytes(ChatMessage message) async {
    final path = message.filePath;
    if (message.isText || path == null) return message;
    final file = File(path);
    if (!await file.exists()) return message;
    final bytes = await file.readAsBytes();
    return message.copyWith(bytes: bytes, size: bytes.length);
  }

  Future<void> _onDeviceFrame(String serial, FireDataResponse frame) async {
    try {
      switch (frame.name) {
        case 'chat.ready':
          await _hintForDevice(serial);
        case 'chat.hint':
          await _pullFromHint(serial, frame.json);
        case 'chat.pull':
          await _servePull(serial, frame.json);
        case 'chat.submit':
          await _serveSubmit(serial, frame.json);
        case 'chat.deliver':
          await _serveDeliver(frame.json, serial);
        case 'chat.delete':
          await _serveDelete(frame.json);
        case 'chat.ack':
          await store.setCursor(
            '${frame.json['conversationId'] ?? ''}',
            'ack',
            _asInt(frame.json['cursor']),
          );
          await reload();
      }
    } catch (error, stack) {
      log.warning('处理聊天 ${frame.name} 失败', error, stack);
    }
  }

  Future<void> _connectBridge() async {
    try {
      await _bridge.start(selfId.value);
      await _announceSelf();
    } catch (error, stack) {
      log.warning('连接聊天通道失败', error, stack);
    }
  }

  void _onBridgeChunk(Uint8List chunk) {
    final frames = _reader.add(chunk);
    for (final frame in frames) {
      _bridgeChain = _bridgeChain
          .catchError((Object _) {})
          .then((_) => _onBridge(frame));
    }
  }

  Future<void> _onBridge(FireDataResponse frame) async {
    try {
      await _onBridgeFrame(frame);
    } catch (error, stack) {
      log.warning('处理聊天 ${frame.name} 失败', error, stack);
    }
  }

  Future<void> _onBridgeFrame(FireDataResponse frame) async {
    if (frame.id != 0 &&
        (frame.name == 'chat.pull' ||
            frame.name == 'chat.submit' ||
            frame.name == 'chat.deliver' ||
            frame.name == 'chat.delete')) {
      await _answerBridge(frame);
      return;
    }
    switch (frame.name) {
      case 'chat.hint':
        unawaited(_pullFromHint('', frame.json));
      case 'chat.batch':
        final slice = ChatSlice.fromJson(frame.json);
        final waiter = _batchWait;
        if (waiter != null && !waiter.isCompleted) {
          waiter.complete(slice);
        } else {
          await _applyIncoming(frame.json, slice);
          await reload();
        }
      case 'chat.accepted':
        final message = ChatMessage.fromJson(frame.json);
        final waiter = _acceptWait;
        if (waiter != null && !waiter.isCompleted) {
          waiter.complete(message);
        }
      case 'chat.ack':
        await store.setCursor(
          '${frame.json['conversationId'] ?? ''}',
          'ack',
          _asInt(frame.json['cursor']),
        );
        await reload();
      case 'chat.ok':
        break;
    }
    if (frame.id != 0 && frame.name != 'chat.ok') {
      await _bridgeSend('chat.ok', <String, Object?>{}, id: frame.id);
    }
  }

  Future<void> _answerBridge(FireDataResponse frame) async {
    if (frame.name == 'chat.pull') {
      final served = await _answer(frame.json);
      await _bridgeSend(
        'chat.batch',
        served ??
            <String, Object?>{
              'conversationId': '${frame.json['conversationId'] ?? ''}',
              'head': 0,
              'cursor': _asInt(frame.json['after']),
              'senderId': '',
              'messages': <Object?>[],
            },
        id: frame.id,
      );
      return;
    }
    if (frame.name == 'chat.submit') {
      final message = await _acceptSubmit(frame.json);
      if (message == null) {
        await _bridgeSend(
          'session.error',
          '不是这个会话的服务端',
          id: frame.id,
          asText: true,
        );
        return;
      }
      await _bridgeSend('chat.accepted', message.wireJson(), id: frame.id);
      return;
    }
    if (frame.name == 'chat.deliver') {
      await _serveDeliver(frame.json, '');
      await _bridgeSend('chat.ok', <String, Object?>{}, id: frame.id);
      return;
    }
    if (frame.name == 'chat.delete') {
      await _serveDelete(frame.json);
      await _bridgeSend('chat.ok', <String, Object?>{}, id: frame.id);
    }
  }

  Future<void> _announceSelf() async {
    await _bridgeSend('chat.ready', <String, Object?>{'selfId': selfId.value});
    final rooms = await store.conversations();
    for (final room in rooms) {
      if (room.kind == kChatDirect || room.ownedBy(selfId.value)) {
        final head = await store.head(
          room.id,
          senderId: room.kind == kChatDirect ? selfId.value : null,
        );
        await _bridgeSend(
          'chat.hint',
          _hintBody(room, head, fromSelf: room.kind == kChatDirect),
        );
      }
    }
  }

  Future<void> _hintForDevice(String serial) async {
    final rooms = await store.conversations();
    for (final room in rooms) {
      if (!await _includes(room, serial)) continue;
      if (room.kind == kChatDirect || room.ownedBy(selfId.value)) {
        await _hint(serial, room, fromSelf: room.kind == kChatDirect);
      }
    }
  }

  Future<bool> _includes(ChatConversation room, String serial) async {
    if (room.peerSerial == serial) return true;
    final people = await store.membersOf(room.id);
    if (people.any((person) => person.id == serial)) return true;
    final routes = await store.routes(room.id);
    return routes.contains(serial);
  }

  Future<void> _hintMembers(ChatConversation room, {required bool fromSelf}) async {
    final targets = await _memberSerials(room);
    for (final serial in targets) {
      if (!_manager.isConnected(serial)) continue;
      await _hint(serial, room, fromSelf: fromSelf);
    }
    if (_bridge.available && (room.ownedBy(selfId.value) || fromSelf)) {
      final head = await store.head(
        room.id,
        senderId: fromSelf ? selfId.value : null,
      );
      await _bridgeSend('chat.hint', _hintBody(room, head, fromSelf: fromSelf));
    }
  }

  Future<void> _hint(
    String serial,
    ChatConversation room, {
    required bool fromSelf,
  }) async {
    if (!_manager.isConnected(serial)) return;
    final head = await store.head(
      room.id,
      senderId: fromSelf ? selfId.value : null,
    );
    try {
      final reply = await _exchange(
        serial,
        (id) => FireDataRequest.json(
          name: 'chat.hint',
          id: id,
          body: _hintBody(room, head, fromSelf: fromSelf),
        ),
      );
      if (reply.name != 'chat.ok') {
        throw StateError(reply.errorText('聊天通知没有送到'));
      }
    } catch (error, stack) {
      log.warning('聊天通知 $serial 失败', error, stack);
    }
  }

  Map<String, Object?> _hintBody(
    ChatConversation room,
    int head, {
    required bool fromSelf,
  }) {
    return <String, Object?>{
      'conversationId': room.id,
      'head': head,
      'fromSelf': fromSelf,
      'senderId': fromSelf ? selfId.value : '',
      'kind': room.kind,
      'title': room.title,
      'ownerId': room.ownerId,
      'peerSerial': room.peerSerial ?? '',
    };
  }

  Future<void> _pullRoom(ChatConversation room) async {
    final serial = await _connectedHost(room);
    if (serial != null) {
      await _pullFromDevice(serial, room, fromSelf: false, senderId: '');
      return;
    }
    if (_bridge.available) {
      await _pullFromBridge(room, fromSelf: false, senderId: '');
    }
  }

  Future<void> _pullFromHint(String serial, Map<String, dynamic> json) async {
    await _remember(json, serial);
    final id = '${json['conversationId'] ?? ''}';
    final room = await store.conversation(id);
    if (room == null) return;
    if (room.ownedBy(selfId.value) && room.kind != kChatDirect) return;
    final fromSelf = json['fromSelf'] == true;
    final senderId = '${json['senderId'] ?? ''}';
    if (serial.isNotEmpty && _manager.deviceOf(serial) != null) {
      await _pullFromDevice(
        serial,
        room,
        fromSelf: fromSelf,
        senderId: senderId,
      );
      return;
    }
    await _pullFromBridge(room, fromSelf: fromSelf, senderId: senderId);
  }

  Future<void> _pullFromDevice(
    String serial,
    ChatConversation room, {
    required bool fromSelf,
    required String senderId,
  }) async {
    final peer = fromSelf ? senderId : '';
    await _pullAll(
      conversationId: room.id,
      cursorPeer: peer,
      fetch: (after) async {
        final reply = await _exchange(
          serial,
          (id) => FireDataRequest.json(
            name: 'chat.pull',
            id: id,
            body: <String, Object?>{
              'conversationId': room.id,
              'after': after,
              'fromSelf': fromSelf,
            },
          ),
        );
        if (reply.name != 'chat.batch') {
          throw StateError(reply.errorText('没有拉到聊天记录'));
        }
        return ChatSlice.fromJson(reply.json);
      },
    );
  }

  Future<void> _pullFromBridge(
    ChatConversation room, {
    required bool fromSelf,
    required String senderId,
  }) async {
    final peer = fromSelf ? senderId : '';
    await _pullAll(
      conversationId: room.id,
      cursorPeer: peer,
      fetch: (after) async {
        final waiter = Completer<ChatSlice>();
        _batchWait = waiter;
        try {
          if (!await _bridgeSend('chat.pull', <String, Object?>{
            'conversationId': room.id,
            'after': after,
            'fromSelf': fromSelf,
          })) {
            throw StateError('聊天通道还没接上');
          }
          return await waiter.future.timeout(const Duration(seconds: 20));
        } finally {
          if (identical(_batchWait, waiter)) _batchWait = null;
        }
      },
    );
  }

  Future<void> _pullAll({
    required String conversationId,
    required String cursorPeer,
    required Future<ChatSlice> Function(int after) fetch,
  }) async {
    var after = await store.cursor(conversationId, cursorPeer);
    for (var round = 0; round < _pullRounds; round++) {
      final slice = await fetch(after);
      await _applySlice(conversationId, cursorPeer, slice);
      if (slice.cursor <= after || slice.cursor >= slice.head) break;
      after = slice.cursor;
    }
    if (cursorPeer.isNotEmpty) {
      await _bridgeSend('chat.ack', <String, Object?>{
        'conversationId': conversationId,
        'cursor': await store.cursor(conversationId, cursorPeer),
      });
      final serial = (await store.conversation(conversationId))?.peerSerial;
      final acked = await store.cursor(conversationId, cursorPeer);
      if (serial != null && _manager.isConnected(serial)) {
        try {
          await _exchange(
            serial,
            (id) => FireDataRequest.json(
              name: 'chat.ack',
              id: id,
              body: <String, Object?>{
                'conversationId': conversationId,
                'cursor': acked,
              },
            ),
          );
        } catch (error, stack) {
          log.warning('确认私聊进度失败', error, stack);
        }
      }
    }
    await reload();
  }

  Future<void> _applyIncoming(
    Map<String, dynamic> json,
    ChatSlice slice,
  ) async {
    final conversationId = '${json['conversationId'] ?? ''}';
    final senderId = '${json['senderId'] ?? ''}';
    final id = conversationId.isNotEmpty
        ? conversationId
        : (slice.messages.isEmpty ? '' : slice.messages.first.groupId);
    if (id.isEmpty) return;
    await _applySlice(id, senderId, slice);
  }

  Future<void> _applySlice(
    String conversationId,
    String cursorPeer,
    ChatSlice slice,
  ) async {
    for (final message in slice.messages) {
      if (await store.isHidden(
        message.groupId,
        message.senderId,
        message.seq,
      )) {
        continue;
      }
      var stored = message;
      final bytes = message.bytes;
      if (bytes != null && bytes.isNotEmpty) {
        final path = await store.saveBytes(
          '${message.senderId}-${message.seq}',
          bytes,
        );
        stored = message.copyWith(filePath: path, size: bytes.length);
      }
      await store.insert(stored);
    }
    await store.setCursor(conversationId, cursorPeer, slice.cursor);
    await store.touch(
      conversationId,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _servePull(String serial, Map<String, dynamic> json) async {
    final served = await _answer(json);
    final id = '${json['conversationId'] ?? ''}';
    await _sendJson(
      serial,
      'chat.batch',
      served ??
          <String, Object?>{
            'conversationId': id,
            'head': 0,
            'cursor': _asInt(json['after']),
            'senderId': '',
            'messages': <Object?>[],
          },
    );
  }

  Future<void> _serveSubmit(String serial, Map<String, dynamic> json) async {
    final message = await _acceptSubmit(json);
    if (message == null) return;
    await _sendJson(serial, 'chat.accepted', message.wireJson());
    final room = await store.conversation(message.groupId);
    if (room != null) await _hintMembers(room, fromSelf: false);
  }

  Future<void> _serveDeliver(Map<String, dynamic> json, String serial) async {
    final message = await _keepDelivered(json);
    if (message == null) return;
    if (serial.isNotEmpty) await store.addRoute(message.groupId, serial);
    final current = await store.cursor(message.groupId, message.senderId);
    if (message.seq <= current + 1) {
      await store.setCursor(message.groupId, message.senderId, message.seq);
    } else {
      final room = await store.conversation(message.groupId);
      if (room != null && serial.isNotEmpty) {
        await _pullFromDevice(
          serial,
          room,
          fromSelf: true,
          senderId: message.senderId,
        );
        return;
      }
    }
    await reload();
  }

  Future<void> _serveDelete(Map<String, dynamic> json) async {
    final conversationId = '${json['conversationId'] ?? json['groupId'] ?? ''}';
    final senderId = '${json['senderId'] ?? ''}';
    final seq = _asInt(json['seq']);
    if (conversationId.isEmpty || seq <= 0) return;
    await store.markDeleted(conversationId, senderId, seq);
  }

  Future<Map<String, Object?>?> _answer(Map<String, dynamic> json) async {
    final id = '${json['conversationId'] ?? ''}';
    final room = await store.conversation(id);
    if (room == null) return null;
    final after = _asInt(json['after']);
    final fromSelf = json['fromSelf'] == true;
    if (room.kind == kChatDirect) {
      if (!fromSelf) return null;
      await store.setCursor(id, 'ack', after);
      final slice = await store.page(id, after: after, senderId: selfId.value);
      final body = slice.toJson(senderId: selfId.value);
      body['conversationId'] = id;
      return body;
    }
    if (!room.ownedBy(selfId.value)) return null;
    final slice = await store.page(id, after: after);
    final body = slice.toJson();
    body['conversationId'] = id;
    return body;
  }

  Future<ChatMessage?> _acceptSubmit(Map<String, dynamic> json) async {
    final id = '${json['groupId'] ?? json['conversationId'] ?? ''}';
    final room = await store.conversation(id);
    if (room == null || room.kind == kChatDirect || !room.ownedBy(selfId.value)) {
      return null;
    }
    final draft = ChatMessage.fromJson(json);
    final seq = await store.nextSeq(id);
    var message = ChatMessage(
      seq: seq,
      groupId: id,
      senderId: draft.senderId,
      senderName: draft.senderName,
      kind: draft.kind,
      body: draft.body,
      mime: draft.mime,
      size: draft.size,
      createdAt: draft.createdAt == 0
          ? DateTime.now().millisecondsSinceEpoch
          : draft.createdAt,
      bytes: draft.bytes,
    );
    final bytes = message.bytes;
    if (bytes != null && bytes.isNotEmpty) {
      final path = await store.saveBytes('${message.senderId}-$seq', bytes);
      message = message.copyWith(filePath: path, size: bytes.length);
    }
    await store.insert(message);
    await store.touch(id, message.createdAt);
    await reload();
    return _withBytes(message);
  }

  Future<ChatMessage?> _keepDelivered(Map<String, dynamic> json) async {
    final draft = ChatMessage.fromJson(json);
    if (draft.seq <= 0 || draft.groupId.isEmpty) return null;
    if (await store.isHidden(draft.groupId, draft.senderId, draft.seq)) {
      return draft;
    }
    var message = draft;
    final bytes = draft.bytes;
    if (bytes != null && bytes.isNotEmpty) {
      final path = await store.saveBytes('${draft.senderId}-${draft.seq}', bytes);
      message = draft.copyWith(filePath: path, size: bytes.length);
    }
    final roomKind = '${json['conversationKind'] ?? ''}';
    if (roomKind.isNotEmpty) {
      final now = message.createdAt;
      await store.ensureConversation(
        ChatConversation(
          id: message.groupId,
          kind: roomKind,
          title: '${json['conversationTitle'] ?? ''}',
          ownerId: '${json['ownerId'] ?? ''}',
          peerSerial: _optional(json['peerSerial']),
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
    await store.insert(message);
    await store.touch(message.groupId, message.createdAt);
    return message;
  }

  Future<void> _remember(Map<String, dynamic> json, String serial) async {
    final id = '${json['conversationId'] ?? ''}';
    final kind = '${json['kind'] ?? ''}';
    if (id.isEmpty || kind.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await store.ensureConversation(
      ChatConversation(
        id: id,
        kind: kind,
        title: '${json['title'] ?? ''}',
        ownerId: '${json['ownerId'] ?? ''}',
        peerSerial: _optional(json['peerSerial']),
        createdAt: now,
        updatedAt: now,
      ),
    );
    if (serial.isNotEmpty) await store.addRoute(id, serial);
    final senderId = '${json['senderId'] ?? ''}';
    if (senderId.isNotEmpty) {
      await store.upsertMember(
        id,
        ChatPerson(id: senderId, name: senderId, role: kChatMemberRole),
      );
    }
  }

  Future<List<String>> _memberSerials(ChatConversation room) async {
    if (room.kind == kChatDirect) {
      final serial = room.peerSerial ?? '';
      return serial.isEmpty ? const <String>[] : <String>[serial];
    }
    final people = await store.membersOf(room.id);
    final routes = await store.routes(room.id);
    return <String>{
      for (final person in people)
        if (person.id != selfId.value && _isDevice(person.id)) person.id,
      for (final serial in routes)
        if (serial != selfId.value) serial,
    }.toList();
  }

  Future<String?> _connectedHost(ChatConversation room) async {
    final routes = await store.routes(room.id);
    for (final serial in routes) {
      if (_manager.isConnected(serial)) return serial;
    }
    return null;
  }

  Future<void> _sendJson(
    String serial,
    String name,
    Map<String, Object?> body,
  ) async {
    final reply = await _exchange(
      serial,
      (id) => FireDataRequest.json(name: name, id: id, body: body),
    );
    if (reply.name != 'chat.ok' && reply.name != name) {
      throw StateError(reply.errorText('聊天没有送达'));
    }
  }

  Future<bool> _bridgeSend(
    String name,
    Object body, {
    int id = 0,
    bool asText = false,
  }) {
    final request = asText
        ? FireDataRequest.text(name: name, id: id, body: '$body')
        : FireDataRequest.json(name: name, id: id, body: body);
    return _bridge.send(request.bytes);
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final done = Completer<T>();
    _sendChain = _sendChain.then((_) async {
      try {
        done.complete(await action());
      } catch (error, stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      }
    });
    return done.future;
  }

  Future<FireDataResponse> _exchange(
    String serial,
    FireDataRequest Function(int id) build,
  ) async {
    final device = _manager.deviceOf(serial);
    if (device == null) throw StateError('设备不在线');
    return _exchangeOn(device, build);
  }

  Future<FireDataResponse> _exchangeOn(
    ConnectedDevice device,
    FireDataRequest Function(int id) build,
  ) async {
    return DeviceLink.exchangeApp(device.serial, build);
  }
}

bool pEqualsDir(String path, String directory) {
  final prefix = directory.endsWith(Platform.pathSeparator)
      ? directory
      : '$directory${Platform.pathSeparator}';
  return path.startsWith(prefix);
}

String? _optional(Object? value) {
  final text = value?.toString() ?? '';
  return text.isEmpty ? null : text;
}

int _asInt(Object? value) {
  if (value is int) return value;
  return int.tryParse('$value') ?? 0;
}

String _kindFor(String name, String? mime) {
  final type = mime?.toLowerCase() ?? '';
  if (type.startsWith('image/')) return 'image';
  final lower = name.toLowerCase();
  const extensions = <String>['.png', '.jpg', '.jpeg', '.gif', '.webp'];
  for (final extension in extensions) {
    if (lower.endsWith(extension)) return 'image';
  }
  return 'file';
}
