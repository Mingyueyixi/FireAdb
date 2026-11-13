import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../appservice/fire_app_session.dart';
import '../appservice/protocol/fire_app_message.dart';
import '../connection/connection_manager.dart';
import '../connection/local_machine_serial.dart';
import '../connection/model/connected_device.dart';
import '../connection/model/device_profile.dart';
import '../link/device_link.dart';
import '../log/app_log.dart';
import 'chat_bridge.dart';
import 'chat_conversation.dart';
import 'chat_message.dart';
import 'chat_post.dart';
import 'chat_store.dart';

const String _selfIdKey = 'chatSelfId';
const String _selfSerialsKey = 'chatSelfSerials';
const String _migratedKey = 'chatMigratedDefault';
const int _pullRounds = 20;

enum ChatPresence { ready, hostOffline, nobodyReached, peerOffline, removed }

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
  final linkTick = 0.obs;

  /// 桌面端公布的在线身份。套接字重连不会清掉这份名单。
  final onlinePeers = <String>[].obs;
  final onlineSerials = <String>[].obs;

  String _selfName = '';
  String _localSerial = '';
  String _selfFile = '';
  final Set<String> _selfTransports = <String>{};
  var _watching = '';
  var _memberToken = 0;
  final _reader = FireDataResponseReader();
  final _deviceChain = <String, Future<void>>{};
  Future<void> _bridgeChain = Future<void>.value();
  Future<void> _sendChain = Future<void>.value();
  Future<void> _pullChain = Future<void>.value();
  Completer<ChatSlice>? _batchWait;
  var _roomRoute = '';
  var _imageRoom = '';
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
    await store.catchUpSeen();
    await reload();
    WidgetsBinding.instance.addObserver(this);
    DeviceLink.onAppFrame = (serial, frame) {
      final previous = _deviceChain[serial] ?? Future<void>.value();
      _deviceChain[serial] = previous
          .catchError((Object _) {})
          .then((_) => _onDeviceFrame(serial, frame));
    };
    DeviceLink.onAppLink = (serial, up) {
      if (up &&
          selfId.value.isNotEmpty &&
          DeviceLink.appSelfIdOf(serial) == selfId.value) {
        unawaited(_rememberSelfSerial(serial));
      }
      _noteLink();
      unawaited(_publishPresence());
    };
    if (_bridge.available) {
      _bridge.listen(
        _onBridgeChunk,
        onLink: (up) {
          if (!up) {
            _failBridgeWait();
            onlinePeers.clear();
            onlineSerials.clear();
          }
          _noteLink();
          if (up) unawaited(_announceSelf());
        },
      );
      unawaited(_connectBridge());
    }
    _localSerial = await localMachineSerial();
    _selfFile = await publishSelfMarker(selfId.value);
    final saved = preferences.getStringList(_selfSerialsKey);
    if (saved != null) _selfTransports.addAll(saved);
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
    if (DeviceLink.onAppLink != null) DeviceLink.onAppLink = null;
    WidgetsBinding.instance.removeObserver(this);
    super.onClose();
  }

  Future<void> _ensureMine(SharedPreferences preferences) async {
    final id = myChannelId(selfId.value);
    if (!(preferences.getBool(_migratedKey) ?? false)) {
      await store.retarget(kDefaultChatGroup, id);
      await preferences.setBool(_migratedKey, true);
    }
    if (await store.hasLeft(id)) return;
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
    final id = myChannelId(selfId.value);
    if (await store.conversation(id) == null) {
      refreshMembers();
      return;
    }
    await store.upsertMember(
      id,
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

  void _noteLink() {
    linkTick.value++;
    refreshMembers();
  }

  Future<void> _loadMembers(String id) async {
    final token = ++_memberToken;
    final people = await store.membersOf(id);
    final routes = await store.routes(id);
    if (token != _memberToken || activeId.value != id) return;
    final room = await store.conversation(id);
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
          online: _memberOnline(room, person, routes),
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

  bool _memberOnline(
    ChatConversation? room,
    ChatPerson person,
    List<String> routes,
  ) {
    if (person.id == selfId.value) return true;
    if (room?.kind != kChatDirect) return _reachable(person, routes);
    if (room!.ownerId == selfId.value) return _deviceChatUp(person.id);
    if (_bridge.available && _bridge.linked) return true;
    return _deviceChatUp(person.id);
  }

  bool _reachable(ChatPerson person, List<String> routes) {
    if (person.id == selfId.value) return true;
    if (_knownOnline(person.id)) return true;
    if (!person.isOwner) return false;
    for (final serial in routes) {
      if (_knownOnline(serial)) return true;
    }
    return false;
  }

  /// 别人连到本机时，这条反向通道是否还在。本机自己连出去的设备不看它。
  bool get channelUp {
    final _ = linkTick.value;
    if (_bridge.available) return _bridge.linked;
    return true;
  }

  /// 这条 adb 连接的对端就是正在运行的这个 FireAdb。地址不能说明这一点。
  bool _isSelfTransport(String serial) => _selfTransports.contains(serial);

  bool isSelfChat(ChatConversation room) {
    final _ = linkTick.value;
    if (room.kind != kChatDirect) return false;
    final serial = room.peerSerial ?? '';
    if (serial == 'self') return true;
    return _isSelfTransport(serial);
  }

  Future<void> _rememberSelfSerial(String serial) async {
    final name = serial.trim();
    if (name.isEmpty || name == 'unknown') return;
    final added = _selfTransports.add(name);
    if (!added) return;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(
      _selfSerialsKey,
      _selfTransports.toList(),
    );
    _noteLink();
  }

  Future<bool> _marksThisMachine(ConnectedDevice device) async {
    if (await _shellHasOurIdentity(device)) return true;
    final mine = _localSerial.trim();
    if (mine.isEmpty) return false;
    final banner = device.adbConnection?.deviceSerial.trim() ?? '';
    if (_sameSerial(banner, mine)) return true;
    for (final key in const <String>['ro.serialno', 'ro.boot.serialno']) {
      try {
        final remote = (await device.shell('getprop $key')).trim();
        if (_sameSerial(remote, mine)) return true;
      } catch (error, stack) {
        log.info('读取 ${device.serial} $key 失败', error, stack);
      }
    }
    return false;
  }

  Future<bool> _shellHasOurIdentity(ConnectedDevice device) async {
    final id = selfId.value.trim();
    if (id.isEmpty) return false;
    final commands = <String>[
      if (_selfFile.isNotEmpty) 'cat $_selfFile',
      'run-as com.fire.adb cat files/fireadb-self',
      'cat /sdcard/Android/data/com.fire.adb/files/fireadb-self',
      'cat /storage/emulated/0/Android/data/com.fire.adb/files/fireadb-self',
    ];
    for (final command in commands) {
      try {
        final text = (await device.shell(command)).trim();
        if (text == id) return true;
      } catch (_) {}
    }
    return false;
  }

  /// 本机已经连上这台设备，并且它的聊天应用还在。
  bool _deviceChatUp(String id) {
    if (id.isEmpty) return false;
    if (_isSelfTransport(id)) return true;
    if (DeviceLink.appReady(id)) return true;
    for (final device in _manager.devices) {
      if (!DeviceLink.appReady(device.serial)) continue;
      if (device.serial == id || DeviceLink.appSelfIdOf(device.serial) == id) {
        return true;
      }
    }
    return false;
  }

  bool _knownOnline(String id) {
    if (id.isEmpty) return false;
    if (_deviceChatUp(id)) return true;
    if (!_bridge.available || !_bridge.linked) return false;
    return onlinePeers.contains(id) || onlineSerials.contains(id);
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
    if (_watching.isNotEmpty) await store.markSeen(_watching);
    final listed = await store.conversations(selfId: selfId.value);
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
    ChatConversation? active;
    for (final item in conversations) {
      if (item.id == id) active = item;
    }
    final room = active;
    messages.assignAll(
      room != null && room.kind != kChatDirect
          ? await store.board(id, selfId: selfId.value)
          : await store.latest(groupId: id, selfId: selfId.value),
    );
    refreshMembers();
  }

  void watch(String id) {
    _watching = id;
    if (id.isEmpty) return;
    unawaited(_markSeen(id));
  }

  void unwatch(String id) {
    if (_watching == id) _watching = '';
  }

  Future<void> _markSeen(String id) async {
    await store.markSeen(id);
    if (_watching != id) return;
    await reload();
  }

  bool claimRoomRoute(String id) {
    if (_roomRoute.isNotEmpty) return false;
    _roomRoute = id;
    return true;
  }

  void releaseRoomRoute(String id) {
    if (_roomRoute == id) _roomRoute = '';
  }

  Future<void> openConversation(String id) async {
    _imageRoom = id;
    if (activeId.value != id) {
      activeId.value = id;
      messages.clear();
      members.clear();
    }
    await reload();
    final room = await store.conversation(id);
    if (room == null || room.ownedBy(selfId.value) || room.closed) return;
    unawaited(_syncRoom(room));
  }

  Future<void> _syncRoom(ChatConversation room) async {
    if (room.kind == kChatDirect) {
      await _pullRoom(room);
    } else {
      await _pullFeed(room);
    }
    if (activeId.value == room.id) unawaited(_loadImages(room));
  }

  /// 下拉刷新。自己的频道只重读本机。连不上频道主时马上结束，不再空等。
  Future<bool> refreshChannel(String id) async {
    final room = await store.conversation(id);
    if (room == null || room.kind == kChatDirect) return true;
    if (room.closed) return false;
    if (room.ownedBy(selfId.value)) {
      await reload();
      return true;
    }
    if (!canPost(room)) return false;
    try {
      await _pullFeed(room, wait: false).timeout(const Duration(seconds: 8));
      if (activeId.value == room.id) unawaited(_loadImages(room));
      return true;
    } catch (error, stack) {
      log.warning('刷新频道失败', error, stack);
      return false;
    }
  }

  Future<String> createChannel(String title) async {
    final name = title.trim();
    if (name.isEmpty) return '';
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = newChatId();
    await store.ensureConversation(
      ChatConversation(
        id: id,
        kind: kChatChannel,
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
    final device = _manager.deviceOf(serial);
    final self =
        _isSelfTransport(serial) ||
        (device != null && await _marksThisMachine(device));
    if (self) {
      await _rememberSelfSerial(serial);
      await _rememberRelatedSerials(serial);
      final existing = await _selfDirectRoom();
      if (existing != null) {
        await _dropEmptySelfRooms(existing.id);
        await openConversation(existing.id);
        return existing.id;
      }
    } else {
      for (final item in conversations) {
        if (item.kind == kChatDirect && item.peerSerial == serial) {
          await openConversation(item.id);
          return item.id;
        }
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = directChatId(selfId.value, self ? 'self' : serial);
    await store.ensureConversation(
      ChatConversation(
        id: id,
        kind: kChatDirect,
        title: name,
        ownerId: selfId.value,
        peerSerial: self ? 'self' : serial,
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
    if (self) await _rememberSelfSerial('self');
    await openConversation(id);
    return id;
  }

  Future<ChatConversation?> _selfDirectRoom() async {
    final found = <ChatConversation>[
      for (final item in conversations)
        if (item.kind == kChatDirect && isSelfChat(item)) item,
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (final item in found) {
      if (await store.head(item.id) > 0) return item;
    }
    if (found.isEmpty) return null;
    return found.first;
  }

  Future<void> _rememberRelatedSerials(String serial) async {
    final profiles = <DeviceProfile>[..._manager.profiles, ..._manager.history];
    String? hardware;
    final device = _manager.deviceOf(serial);
    final banner = device?.adbConnection?.deviceSerial.trim() ?? '';
    if (banner.isNotEmpty && banner != 'unknown' && !banner.contains(':')) {
      hardware = banner;
    }
    for (final profile in profiles) {
      final listed = profile.adbSerial?.trim() ?? '';
      if (profile.serial == serial || listed == serial) {
        await _rememberSelfSerial(profile.serial);
        if (listed.isNotEmpty) {
          await _rememberSelfSerial(listed);
          if (!listed.contains(':')) hardware ??= listed;
        }
      }
    }
    if (hardware == null) return;
    for (final profile in profiles) {
      if (profile.adbSerial == hardware || profile.serial == hardware) {
        await _rememberSelfSerial(profile.serial);
      }
    }
  }

  Future<void> _dropEmptySelfRooms(String keepId) async {
    for (final item in conversations.toList()) {
      if (item.id == keepId || item.kind != kChatDirect || !isSelfChat(item)) {
        continue;
      }
      if (await store.head(item.id) > 0) continue;
      await store.forget(item.id);
    }
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
    if (DeviceLink.appReady(serial)) {
      await _hint(serial, room, fromSelf: false);
    }
  }

  /// 自己主持的频道从本机解散，包括默认的「我的频道」。解散后不再自动建回来。
  Future<void> disbandChannel(String id) async {
    final room = await store.conversation(id);
    if (room == null || room.kind == kChatDirect) return;
    if (!room.ownedBy(selfId.value)) return;
    await _announceClosed(room);
    await _dropRoom(id);
  }

  Future<void> _announceClosed(ChatConversation room) async {
    final body = <String, Object?>{
      'conversationId': room.id,
      'title': room.title,
      'ownerId': room.ownerId,
      'kind': room.kind,
      'closed': true,
    };
    for (final serial in await _memberSerials(room)) {
      if (_isSelfTransport(serial) || !DeviceLink.appReady(serial)) continue;
      try {
        await _sendJson(serial, 'chat.closed', body);
      } catch (error, stack) {
        log.warning('通知频道解散失败 $serial', error, stack);
      }
    }
    if (_bridge.available) await _bridgeSend('chat.closed', body);
  }

  Future<void> _noteClosed(String id) async {
    if (id.isEmpty) return;
    final room = await store.conversation(id);
    if (room == null || room.kind == kChatDirect || room.ownedBy(selfId.value)) {
      return;
    }
    if (room.closed) return;
    await store.markClosed(id);
    await reload();
  }

  Future<Map<String, Object?>> _catalogBody() async {
    final rooms = await store.conversations();
    return <String, Object?>{
      'channels': <Object?>[
        for (final room in rooms)
          if (room.kind != kChatDirect && room.ownedBy(selfId.value) && !room.closed)
            <String, Object?>{
              'id': room.id,
              'title': room.title,
              'ownerId': room.ownerId,
              'ownerName': _selfName,
              'kind': room.kind,
            },
      ],
    };
  }

  Future<void> _serveJoin(Map<String, dynamic> json, String serial) async {
    final id = '${json['conversationId'] ?? ''}';
    final room = await store.conversation(id);
    if (room == null || room.kind == kChatDirect || !room.ownedBy(selfId.value)) {
      throw StateError('频道已经解散');
    }
    final offered = '${json['serial'] ?? ''}'.trim();
    final caller = serial.isNotEmpty
        ? serial
        : (offered.isNotEmpty ? offered : '${json['selfId'] ?? ''}'.trim());
    final name = '${json['name'] ?? ''}'.trim();
    if (caller.isEmpty) throw StateError('没有加入路径');
    await addMember(id, caller, name.isEmpty ? caller : name);
  }

  Future<List<ChatListing>> discoverChannels() async {
    final found = <String, ChatListing>{};
    void take(FireDataResponse reply, String via) {
      final raw = reply.json['channels'];
      if (raw is! List) return;
      for (final item in raw) {
        if (item is! Map) continue;
        final id = '${item['id'] ?? ''}';
        final ownerId = '${item['ownerId'] ?? ''}';
        if (id.isEmpty || ownerId == selfId.value || found.containsKey(id)) {
          continue;
        }
        found[id] = ChatListing(
          id: id,
          title: '${item['title'] ?? ''}',
          ownerId: ownerId,
          ownerName: '${item['ownerName'] ?? ''}',
          via: via,
        );
      }
    }

    for (final device in _manager.devices) {
      if (!DeviceLink.appReady(device.serial)) continue;
      try {
        final reply = await _exchange(
          device.serial,
          (id) => FireDataRequest.json(
            name: 'chat.catalog',
            id: id,
            body: const <String, Object?>{},
          ),
        );
        take(reply, device.serial);
      } catch (error, stack) {
        log.warning('读取频道目录失败 ${device.serial}', error, stack);
      }
    }
    if (_bridge.linked) {
      try {
        take(await _bridge.exchange('chat.catalog', const <String, Object?>{}), '');
      } catch (error, stack) {
        log.warning('读取频道目录失败', error, stack);
      }
    }
    final listed = found.values.toList();
    listed.sort((a, b) => a.title.compareTo(b.title));
    return listed;
  }

  /// 只读取频道主上的帖子，不在本机建立订阅。
  Future<List<ChatMessage>> previewChannel(ChatListing channel) async {
    final body = <String, Object?>{
      'conversationId': channel.id,
      'list': true,
    };
    final FireDataResponse reply;
    if (channel.via.isNotEmpty) {
      reply = await _exchange(
        channel.via,
        (id) => FireDataRequest.json(name: 'chat.pull', id: id, body: body),
      );
    } else if (_bridge.linked) {
      reply = await _bridge.exchange('chat.pull', body);
    } else {
      throw StateError('聊天通道还没接上');
    }
    if (reply.json['closed'] == true) throw StateError('频道已经解散');
    if (reply.name != 'chat.batch') {
      throw StateError(reply.errorText('没有拉到聊天记录'));
    }
    final messages = ChatSlice.fromJson(reply.json).messages;
    messages.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return messages;
  }

  Future<String> joinChannel(ChatListing channel) async {
    final body = <String, Object?>{
      'conversationId': channel.id,
      'selfId': selfId.value,
      'name': _selfName,
      'serial': _localSerial,
    };
    final FireDataResponse reply;
    if (channel.via.isNotEmpty) {
      reply = await _exchange(
        channel.via,
        (id) => FireDataRequest.json(name: 'chat.join', id: id, body: body),
      );
    } else if (_bridge.linked) {
      reply = await _bridge.exchange('chat.join', body);
    } else {
      throw StateError('聊天通道还没接上');
    }
    if (reply.name == 'chat.closed' || reply.json['closed'] == true) {
      await _noteClosed(channel.id);
      throw StateError('频道已经解散');
    }
    if (reply.name != 'chat.ok' && reply.name != 'chat.join') {
      throw StateError(reply.errorText('没有加入这个频道'));
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    await store.ensureConversation(
      ChatConversation(
        id: channel.id,
        kind: kChatChannel,
        title: channel.title,
        ownerId: channel.ownerId,
        createdAt: now,
        updatedAt: now,
      ),
    );
    if (channel.via.isNotEmpty) await store.addRoute(channel.id, channel.via);
    await store.upsertMember(
      channel.id,
      ChatPerson(id: channel.ownerId, name: channel.ownerName, role: kChatOwner),
    );
    await reload();
    await openConversation(channel.id);
    return channel.id;
  }

  /// 成员退出别人主持的频道。
  Future<void> leaveChannel(String id) async {
    final room = await store.conversation(id);
    if (room == null || room.kind == kChatDirect) return;
    if (room.ownedBy(selfId.value)) return;
    await _dropRoom(id);
  }

  Future<void> removeConversation(String id) async {
    final room = await store.conversation(id);
    if (room == null || room.kind != kChatDirect) return;
    await _dropRoom(id);
  }

  Future<void> clearHistory(String id) async {
    final room = await store.conversation(id);
    if (room == null) return;
    await store.clearMessages(id);
    if (activeId.value == id) messages.clear();
    await reload();
  }

  Future<void> _dropRoom(String id) async {
    await store.forget(id);
    if (activeId.value == id) {
      activeId.value = '';
      messages.clear();
      members.clear();
    }
    await reload();
  }

  Future<void> forwardMessages(
    List<ChatMessage> messages,
    String targetId,
  ) {
    if (messages.isEmpty || targetId.isEmpty) return Future<void>.value();
    return _enqueue(() async {
      for (final message in messages) {
        await _send(
          ChatMessage(
            seq: 0,
            groupId: targetId,
            senderId: selfId.value,
            senderName: _selfName,
            kind: message.kind,
            body: message.body,
            filePath: message.filePath,
            mime: message.mime,
            size: message.size,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
    });
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
      await _pushDelete(room, message);
    } else {
      await _askDelete(room, message);
    }
    await reload();
  }

  /// 现在能发起私聊的对方：聊天通道已经接上，或正连着的本机。不含历史连接。
  List<DeviceProfile> onlineChatDevices() {
    final profiles = <String, DeviceProfile>{};
    for (final device in _manager.devices) {
      final serial = device.serial;
      if (!DeviceLink.appReady(serial) && !_isSelfTransport(serial)) continue;
      profiles[serial] =
          _manager.profileOf(serial) ?? DeviceProfile(serial: serial);
    }
    final values = profiles.values.toList();
    values.sort((a, b) => a.displayName.compareTo(b.displayName));
    return values;
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

  ChatPresence presenceOf(ChatConversation room) {
    final _ = linkTick.value;
    if (room.closed) return ChatPresence.removed;
    if (isSelfChat(room)) return ChatPresence.ready;
    if (room.kind == kChatDirect) {
      final serial = room.peerSerial ?? '';
      if (room.ownerId == selfId.value) {
        if (_deviceChatUp(serial)) return ChatPresence.ready;
        return ChatPresence.peerOffline;
      }
      if (_bridge.available && _bridge.linked) return ChatPresence.ready;
      if (_deviceChatUp(serial)) return ChatPresence.ready;
      return ChatPresence.peerOffline;
    }
    if (room.ownedBy(selfId.value)) return ChatPresence.ready;
    if (channelUp && onlinePeers.contains(room.ownerId)) return ChatPresence.ready;
    final ownerOnline = members.any(
      (member) => member.role == kChatOwner && member.online,
    );
    if (ownerOnline) return ChatPresence.ready;
    return ChatPresence.hostOffline;
  }

  /// 别人主持的频道，连不上频道主时不能发帖。自己主持的频道写在本机。
  bool canPost(ChatConversation room) {
    if (room.closed || room.kind == kChatDirect) return false;
    if (room.ownedBy(selfId.value)) return true;
    return presenceOf(room) == ChatPresence.ready;
  }

  int ownerReachCount() {
    final viaBridge = _bridge.available && _bridge.linked
        ? onlinePeers.where((id) => id != selfId.value).length
        : 0;
    final devices = members
        .where((member) => !member.self && member.online)
        .length;
    return viaBridge > devices ? viaBridge : devices;
  }

  bool canRevise(ChatMessage post) {
    if (post.senderId == selfId.value) return true;
    for (final room in conversations) {
      if (room.id == post.groupId) return room.ownedBy(selfId.value);
    }
    return false;
  }

  Future<void> publishPost({
    required String text,
    required List<String> imagePaths,
    required List<({String path, String name, String? mime})> files,
  }) {
    return _enqueue(() async {
      final body = text.trim();
      if (body.isEmpty && imagePaths.isEmpty && files.isEmpty) return;
      final room = await store.conversation(activeId.value);
      if (room == null || room.kind == kChatDirect) return;
      final post = await _send(
        _draft(room.id, kind: kChatPost, body: encodePost(body)),
      );
      await _attachPost(room.id, post.seq, imagePaths, files);
    });
  }

  Future<void> revisePost({
    required ChatMessage post,
    required String text,
    required String previous,
    required List<ChatMessage> removed,
    required List<String> imagePaths,
    required List<({String path, String name, String? mime})> files,
  }) {
    return _enqueue(() async {
      if (!canRevise(post)) return;
      final body = text.trim();
      for (final message in removed) {
        await deleteMessage(message);
      }
      await _attachPost(post.groupId, post.seq, imagePaths, files);
      if (body == previous.trim() && imagePaths.isEmpty && files.isEmpty && removed.isEmpty) {
        return;
      }
      if (body != previous.trim()) {
        await _send(
          _draft(
            post.groupId,
            kind: kChatRevise,
            body: encodePost(body),
            parentSeq: post.seq,
          ),
        );
      }
    });
  }

  Future<void> _attachPost(
    String groupId,
    int postSeq,
    List<String> imagePaths,
    List<({String path, String name, String? mime})> files,
  ) async {
    for (final path in imagePaths) {
      await _send(
        _draft(
          groupId,
          kind: _kindFor(_baseName(path), null),
          body: _baseName(path),
          parentSeq: postSeq,
          filePath: path,
        ),
      );
    }
    for (final file in files) {
      await _send(
        _draft(
          groupId,
          kind: 'file',
          body: file.name,
          parentSeq: postSeq,
          filePath: file.path,
          mime: file.mime,
        ),
      );
    }
  }

  Future<void> discuss(int postSeq, String text) {
    final body = text.trim();
    final groupId = activeId.value;
    if (body.isEmpty || groupId.isEmpty) return Future<void>.value();
    return _enqueue(
      () => _send(
        _draft(groupId, kind: 'text', body: body, parentSeq: postSeq),
      ),
    );
  }

  ChatMessage _draft(
    String groupId, {
    required String kind,
    required String body,
    int parentSeq = 0,
    String? filePath,
    String? mime,
  }) {
    return ChatMessage(
      seq: 0,
      groupId: groupId,
      senderId: selfId.value,
      senderName: _selfName,
      kind: kind,
      body: body,
      parentSeq: parentSeq,
      filePath: filePath,
      mime: mime,
      createdAt: DateTime.now().millisecondsSinceEpoch,
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
    _noteLink();
    final device = _manager.deviceOf(serial);
    if (device == null) return;
    if (await _marksThisMachine(device)) {
      await _rememberSelfSerial(serial);
      await _rememberRelatedSerials(serial);
      return;
    }
    if (_selfTransports.remove(serial)) {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setStringList(
        _selfSerialsKey,
        _selfTransports.toList(),
      );
    }
    try {
      await DeviceLink.open(device);
    } catch (error, stack) {
      log.warning('聊天通道没有打开', error, stack);
    }
  }

  Future<void> onDeviceDisconnected(String serial) async {
    await DeviceLink.close(serial);
    releaseChatHold(serial);
    _noteLink();
  }

  Future<ChatMessage> _send(ChatMessage draft, {bool notify = true}) async {
    final room = await store.conversation(draft.groupId);
    if (room == null) throw StateError('会话不存在');
    if (room.kind == kChatDirect) return _sendDirect(room, draft, notify: notify);
    if (room.ownedBy(selfId.value)) return _sendHosted(room, draft, notify: notify);
    return _sendToHost(room, draft);
  }

  Future<ChatMessage> _sendHosted(
    ChatConversation room,
    ChatMessage draft, {
    bool notify = true,
  }) async {
    final seq = await store.nextSeq(room.id);
    final message = await _stored(draft, seq);
    await store.insert(message);
    await store.touch(room.id, message.createdAt);
    await reload();
    if (notify) await _pushChannel(message);
    return message;
  }

  Future<ChatMessage> _sendDirect(
    ChatConversation room,
    ChatMessage draft, {
    bool notify = true,
  }) async {
    final seq = await store.nextSeq(room.id, senderId: selfId.value);
    final message = await _stored(draft, seq);
    await store.insert(message);
    await store.setCursor(room.id, 'ack', await store.cursor(room.id, 'ack'));
    await store.touch(room.id, message.createdAt);
    await reload();
    if (!notify) return message;
    final serial = room.peerSerial ?? '';
    if (room.ownerId == selfId.value) {
      if (_isSelfTransport(serial)) return message;
      if (serial.isNotEmpty && DeviceLink.appReady(serial)) {
        await _hint(serial, room, fromSelf: true);
      }
      return message;
    }
    if (_bridge.available && _bridge.linked) {
      final people = await store.membersOf(room.id);
      await _bridgeSend(
        'chat.deliver',
        (await _withBytes(message)).withRoom(room, people).wireJson(),
      );
      return message;
    }
    if (serial.isNotEmpty && DeviceLink.appReady(serial)) {
      await _hint(serial, room, fromSelf: true);
    }
    return message;
  }

  Future<ChatMessage> _sendToHost(ChatConversation room, ChatMessage draft) async {
    if (room.closed) throw StateError('频道已经解散');
    if (!canPost(room)) throw StateError('连不上频道主');
    final body = (await _withBytes(draft)).wireJson();
    final serial = await _connectedHost(room);
    ChatMessage accepted;
    if (serial != null) {
      final reply = await _exchange(
        serial,
        (id) => FireDataRequest.json(name: 'chat.submit', id: id, body: body),
      );
      if (reply.name == 'chat.closed' || reply.json['closed'] == true) {
        await _noteClosed(room.id);
        throw StateError('频道已经解散');
      }
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
        chatMediaId(accepted) ?? '${accepted.senderId}-${accepted.seq}',
        bytes,
      );
      message = accepted.copyWith(filePath: path, size: bytes.length);
    }
    await store.insert(message);
    await store.touch(room.id, message.createdAt);
    await reload();
    return message;
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
    final kept = await _keepMedia(draft);
    return _withBytes(
      ChatMessage(
        seq: seq,
        groupId: draft.groupId,
        senderId: draft.senderId,
        senderName: draft.senderName,
        kind: draft.kind,
        body: kept?.body ?? draft.body,
        parentSeq: draft.parentSeq,
        filePath: kept?.path ?? draft.filePath,
        mime: draft.mime,
        size: kept?.size ?? draft.size,
        createdAt: draft.createdAt,
      ),
    );
  }

  /// 把图片或附件收进 `发送者/摘要.后缀`。内容不变则编号不变。
  Future<({String path, String body, int size})?> _keepMedia(ChatMessage draft) async {
    final source = draft.filePath;
    final media = draft.kind == 'image' || draft.kind == 'file';
    if (!media || source == null || source.isEmpty) return null;
    final file = File(source);
    if (!await file.exists()) return null;
    if (chatMediaMarked(draft.body)) {
      final id = chatMediaId(draft);
      if (id == null) return (path: source, body: draft.body, size: await file.length());
      if (pEqualsDir(source, store.filesDir)) {
        return (path: source, body: draft.body, size: await file.length());
      }
      final bytes = await file.readAsBytes();
      final path = await store.saveBytes(id, bytes);
      return (path: path, body: draft.body, size: bytes.length);
    }
    final bytes = await file.readAsBytes();
    final name = draft.kind == 'file' ? draft.body : _baseName(source);
    final id = chatContentId(
      senderId: draft.senderId,
      bytes: bytes,
      ext: chatMediaExt(name, draft.mime),
    );
    final path = await store.saveBytes(id, bytes);
    return (
      path: path,
      body: chatMediaRef(
        image: draft.kind == 'image',
        id: id,
        name: draft.kind == 'file' ? name : '',
      ),
      size: bytes.length,
    );
  }

  Future<({String path, String body, int size})?> _keepSubmitted(
    ChatMessage draft,
  ) async {
    final bytes = draft.bytes;
    if (bytes == null || bytes.isEmpty) return _keepMedia(draft);
    if (draft.kind != 'image' && draft.kind != 'file') return null;
    final marked = chatMediaMarked(draft.body) ? chatMediaId(draft) : null;
    final name = draft.kind == 'file' ? draft.body : 'image';
    final id = marked ??
        chatContentId(
          senderId: draft.senderId,
          bytes: bytes,
          ext: chatMediaExt(name, draft.mime),
        );
    final path = await store.saveBytes(id, bytes);
    final body = marked == null
        ? chatMediaRef(
            image: draft.kind == 'image',
            id: id,
            name: draft.kind == 'file' ? name : '',
          )
        : draft.body;
    return (path: path, body: body, size: bytes.length);
  }

  String? placed(ChatMessage message) => store.placedMedia(message);

  Future<ChatMessage> _withBytes(ChatMessage message) async {
    final path = placed(message);
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
          _later(() async {
            await _publishPresence();
            await _hintForDevice(serial);
          });
        case 'chat.hint':
          _later(() => _pullFromHint(serial, frame.json));
        case 'chat.push':
          await _servePush(frame.json);
        case 'chat.pull':
          if (frame.id != 0) {
            final served = await _answer(frame.json);
            await DeviceLink.replyApp(
              serial,
              frame.id,
              'chat.batch',
              served ??
                  <String, Object?>{
                    'conversationId': '${frame.json['conversationId'] ?? ''}',
                    'head': 0,
                    'cursor': _asInt(frame.json['after']),
                    'senderId': '',
                    'messages': <Object?>[],
                  },
            );
          } else {
            _later(() => _servePull(serial, frame.json));
          }
        case 'chat.submit':
          await _serveSubmit(serial, frame.json, replyId: frame.id);
        case 'chat.deliver':
          await _serveDeliver(frame.json, serial);
        case 'chat.delete':
          await _serveDelete(frame.json);
        case 'chat.closed':
          await _noteClosed('${frame.json['conversationId'] ?? ''}');
        case 'chat.catalog':
          if (frame.id != 0) {
            await DeviceLink.replyApp(
              serial,
              frame.id,
              'chat.catalog',
              await _catalogBody(),
            );
          }
        case 'chat.join':
          if (frame.id != 0) {
            try {
              await _serveJoin(frame.json, serial);
              await DeviceLink.replyApp(
                serial,
                frame.id,
                'chat.ok',
                const <String, Object?>{},
              );
            } catch (error) {
              await DeviceLink.replyApp(
                serial,
                frame.id,
                'session.error',
                <String, Object?>{'error': '$error'},
              );
            }
          }
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
    if (_bridge.take(frame)) return;
    if (frame.id != 0 && frame.name == 'chat.catalog') {
      await _bridgeSend('chat.catalog', await _catalogBody(), id: frame.id);
      return;
    }
    if (frame.id != 0 && frame.name == 'chat.join') {
      try {
        await _serveJoin(frame.json, '');
        await _bridgeSend('chat.ok', const <String, Object?>{}, id: frame.id);
      } catch (error) {
        await _bridgeSend('session.error', '$error', id: frame.id, asText: true);
      }
      return;
    }
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
        _later(() => _pullFromHint('', frame.json));
      case 'chat.presence':
        _applyPresence(frame.json);
      case 'chat.push':
        await _servePush(frame.json);
      case 'chat.delete':
        await _serveDelete(frame.json);
      case 'chat.closed':
        await _noteClosed('${frame.json['conversationId'] ?? ''}');
        final waiting = _acceptWait;
        if (frame.id != 0 && waiting != null && !waiting.isCompleted) {
          waiting.completeError(StateError('频道已经解散'));
        }
      case 'chat.batch':
        if (frame.json['closed'] == true) {
          await _noteClosed('${frame.json['conversationId'] ?? ''}');
        }
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
          'chat.closed',
          <String, Object?>{
            'conversationId': '${frame.json['groupId'] ?? frame.json['conversationId'] ?? ''}',
            'closed': true,
          },
          id: frame.id,
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
      if (room.kind == kChatDirect || !room.ownedBy(selfId.value)) continue;
      final head = await store.head(room.id);
      await _bridgeSend(
        'chat.hint',
        _hintBody(room, head, fromSelf: false),
      );
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

  Future<void> _hint(
    String serial,
    ChatConversation room, {
    required bool fromSelf,
  }) async {
    if (_isSelfTransport(serial) || !DeviceLink.appReady(serial)) return;
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

  Future<void> _pullFeed(ChatConversation room, {bool wait = true}) {
    return _runPull(() async {
      final slice = await _pullSlice(
        room,
        <String, Object?>{
          'conversationId': room.id,
          'list': true,
        },
        wait: wait,
      );
      await _applySlice(room.id, '', slice, advance: false);
      if (activeId.value == room.id) await reload();
    });
  }

  Future<void> _pullRoom(ChatConversation room) {
    return _runPull(() async {
      final serial = await _connectedHost(room);
      if (serial != null) {
        await _pullFromDevice(serial, room, fromSelf: false, senderId: '');
        return;
      }
      if (_bridge.available) {
        await _pullFromBridge(room, fromSelf: false, senderId: '');
      }
    });
  }

  Future<void> _pullFromHint(String serial, Map<String, dynamic> json) async {
    final kind = '${json['kind'] ?? ''}';
    final ownerId = '${json['ownerId'] ?? ''}';
    final conversationId = '${json['conversationId'] ?? ''}';
    if (serial.isNotEmpty && _foreignDirect(conversationId, ownerId, kind)) {
      return;
    }
    await _remember(json, serial);
    final id = '${json['conversationId'] ?? ''}';
    final room = await store.conversation(id);
    if (room == null) return;
    if (room.kind != kChatDirect) {
      if (activeId.value == room.id && !room.ownedBy(selfId.value)) {
        await _pullFeed(room);
        unawaited(_loadImages(room));
      }
      return;
    }
    final fromSelf = json['fromSelf'] == true;
    final senderId = '${json['senderId'] ?? ''}';
    await _runPull(() async {
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
    });
    if (activeId.value == room.id) unawaited(_loadImages(room));
  }

  /// 同一时间只拉一次，避免后一次把前一次的等待盖掉。
  Future<void> _runPull(Future<void> Function() action) {
    final done = Completer<void>();
    _pullChain = _pullChain.then((_) async {
      try {
        await action();
        if (!done.isCompleted) done.complete();
      } catch (error, stack) {
        log.warning('拉取聊天失败', error, stack);
        if (!done.isCompleted) done.complete();
      }
    });
    return done.future;
  }

  void _later(Future<void> Function() action) {
    unawaited(() async {
      try {
        await action();
      } catch (error, stack) {
        log.warning('聊天后台任务失败', error, stack);
      }
    }());
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
      if (activeId.value == conversationId) await reload();
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
      if (serial != null && DeviceLink.appReady(serial)) {
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
    ChatSlice slice, {
    bool advance = true,
  }) async {
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
          chatMediaId(message) ?? '${message.senderId}-${message.seq}',
          bytes,
        );
        stored = message.copyWith(filePath: path, size: bytes.length);
      }
      await store.insert(stored);
      final path = stored.filePath;
      if (path != null && path.isNotEmpty) {
        await store.saveFile(
          stored.groupId,
          stored.senderId,
          stored.seq,
          path,
          stored.size,
        );
      }
    }
    for (final item in slice.dropped) {
      await store.markDeleted(conversationId, item.senderId, item.seq);
      await store.hide(conversationId, item.senderId, item.seq);
    }
    if (!advance) return;
    await store.setCursor(conversationId, cursorPeer, slice.cursor);
    await store.touch(
      conversationId,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 正文列表按序号增量拉取。图片只补本地还没有的内容摘要。
  Future<void> _loadImages(ChatConversation room) async {
    if (room.kind != kChatDirect && room.ownedBy(selfId.value)) return;
    _imageRoom = room.id;
    final missing = await store.missingFiles(room.id);
    for (final message in missing) {
      if (_imageRoom != room.id || message.kind != 'image') continue;
      if (placed(message) != null) continue;
      await _fetchMedia(room, message);
    }
  }

  /// 附件只在点击时下载。返回本机路径。
  Future<String?> downloadFile(ChatMessage message) async {
    final ready = placed(message);
    if (ready != null) return ready;
    final room = await store.conversation(message.groupId);
    if (room == null) return null;
    await _fetchMedia(room, message);
    return placed(message);
  }

  Future<void> _fetchMedia(ChatConversation room, ChatMessage message) {
    return _runPull(() async {
      if (placed(message) != null) return;
      final slice = await _pullSlice(room, <String, Object?>{
        'conversationId': room.id,
        'after': message.seq > 0 ? message.seq - 1 : 0,
        'fromSelf': room.kind == kChatDirect,
        'seq': message.seq,
        'senderId': message.senderId,
        'media': chatMediaRef(
          image: message.kind == 'image',
          id: chatMediaId(message) ?? '${message.senderId}-${message.seq}',
          name: message.kind == 'file' ? chatMediaName(message) : '',
        ),
      });
      await _applySlice(room.id, '', slice, advance: false);
      await reload();
    });
  }

  Future<ChatSlice> _pullSlice(
    ChatConversation room,
    Map<String, Object?> body, {
    bool wait = true,
  }) async {
    final String? serial;
    if (room.kind == kChatDirect) {
      serial = room.peerSerial;
    } else {
      serial = await _connectedHost(room);
    }
    if (serial != null && serial.isNotEmpty && _manager.deviceOf(serial) != null) {
      final reply = await _exchange(
        serial,
        (id) => FireDataRequest.json(name: 'chat.pull', id: id, body: body),
      );
      if (reply.json['closed'] == true) {
        await _noteClosed(room.id);
        return const ChatSlice(head: 0, cursor: 0, messages: <ChatMessage>[]);
      }
      if (reply.name != 'chat.batch') {
        throw StateError(reply.errorText('没有拉到附件'));
      }
      return ChatSlice.fromJson(reply.json);
    }
    if (!_bridge.available) throw StateError('聊天通道还没接上');
    if (!wait && !_bridge.linked) throw StateError('聊天通道还没接上');
    final budget = wait ? const Duration(seconds: 12) : const Duration(seconds: 8);
    final deadline = DateTime.now().add(budget);
    var pause = const Duration(seconds: 2);
    while (true) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        throw TimeoutException('拉取超时', budget);
      }
      if (!_bridge.linked) {
        if (!wait) throw StateError('聊天通道还没接上');
        await Future<void>.delayed(pause);
        final grown = pause.inMilliseconds * 2;
        pause = Duration(milliseconds: grown > 8000 ? 8000 : grown);
        continue;
      }
      final waiter = Completer<ChatSlice>();
      _batchWait = waiter;
      try {
        if (!await _bridgeSend('chat.pull', body)) {
          if (!wait) throw StateError('聊天通道还没接上');
          await Future<void>.delayed(pause);
          continue;
        }
        return await waiter.future.timeout(left);
      } on TimeoutException {
        if (!wait || !DateTime.now().isBefore(deadline)) rethrow;
      } catch (error) {
        final text = '$error';
        final dropped = text.contains('断开') || text.contains('还没接上');
        if (!wait || !dropped || !DateTime.now().isBefore(deadline)) rethrow;
      } finally {
        if (identical(_batchWait, waiter)) _batchWait = null;
      }
    }
  }

  void _failBridgeWait() {
    final batch = _batchWait;
    if (batch != null && !batch.isCompleted) {
      batch.completeError(StateError('聊天通道已断开'));
    }
    final accept = _acceptWait;
    if (accept != null && !accept.isCompleted) {
      accept.completeError(StateError('聊天通道已断开'));
    }
  }

  void _applyPresence(Map<String, dynamic> json) {
    final ids = json['selfIds'];
    final serials = json['serials'];
    onlinePeers.assignAll(<String>[
      if (ids is List) ...ids.map((item) => '$item'),
    ]);
    onlineSerials.assignAll(<String>[
      if (serials is List) ...serials.map((item) => '$item'),
    ]);
    linkTick.value++;
    refreshMembers();
  }

  /// 本机连上的每台设备，都告诉它现在哪些聊天应用还在。
  Future<void> _publishPresence() async {
    if (selfId.value.isEmpty) return;
    final ids = <String>{selfId.value};
    final serials = <String>[];
    for (final device in _manager.devices) {
      final appId = DeviceLink.appSelfIdOf(device.serial);
      if (appId == null) continue;
      ids.add(appId);
      serials.add(device.serial);
    }
    final body = <String, Object?>{
      'selfIds': ids.toList(),
      'serials': serials,
    };
    for (final device in _manager.devices) {
      if (!DeviceLink.appReady(device.serial) || _isSelfTransport(device.serial)) {
        continue;
      }
      try {
        await _exchange(
          device.serial,
          (id) => FireDataRequest.json(
            name: 'chat.presence',
            id: id,
            body: body,
          ),
        );
      } catch (error, stack) {
        log.warning('公布在线状态失败 ${device.serial}', error, stack);
      }
    }
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

  Future<void> _serveSubmit(
    String serial,
    Map<String, dynamic> json, {
    int replyId = 0,
  }) async {
    final message = await _acceptSubmit(json);
    if (message == null) {
      if (replyId != 0 && serial.isNotEmpty) {
        await DeviceLink.replyApp(serial, replyId, 'chat.closed', <String, Object?>{
          'conversationId': '${json['groupId'] ?? json['conversationId'] ?? ''}',
          'closed': true,
        });
      }
      return;
    }
    await _sendJson(serial, 'chat.accepted', message.wireJson());
    await _pushChannel(message);
  }

  Future<void> _pushChannel(ChatMessage message) async {
    final room = await store.conversation(message.groupId);
    if (room == null || room.kind == kChatDirect) return;
    final people = await store.membersOf(room.id);
    final body = message.withRoom(room, people).wireJson()..remove('data');
    for (final serial in await _memberSerials(room)) {
      if (_isSelfTransport(serial) || !DeviceLink.appReady(serial)) continue;
      try {
        await _sendJson(serial, 'chat.push', body);
      } catch (error, stack) {
        log.warning('推送频道消息失败 $serial', error, stack);
      }
    }
    if (_bridge.available && room.ownedBy(selfId.value)) {
      await _bridgeSend('chat.push', body);
    }
  }

  Future<void> _servePush(Map<String, dynamic> json) async {
    final message = await _keepDelivered(json);
    if (message == null) return;
    await reload();
    if (activeId.value != message.groupId || message.kind != 'image') return;
    final room = await store.conversation(message.groupId);
    if (room != null) unawaited(_loadImages(room));
  }

  Future<void> _serveDeliver(Map<String, dynamic> json, String serial) async {
    if (serial.isNotEmpty &&
        _foreignDirect(
          '${json['groupId'] ?? ''}',
          '${json['ownerId'] ?? ''}',
          '${json['conversationKind'] ?? ''}',
        )) {
      return;
    }
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
    await store.hide(conversationId, senderId, seq);
    final room = await store.conversation(conversationId);
    if (room != null && room.ownedBy(selfId.value)) {
      await _pushDelete(
        room,
        ChatMessage(
          seq: seq,
          groupId: conversationId,
          senderId: senderId,
          senderName: '',
          kind: 'text',
          body: '',
          createdAt: 0,
        ),
      );
    }
    await reload();
  }

  Future<void> _pushDelete(ChatConversation room, ChatMessage message) async {
    final body = <String, Object?>{
      'conversationId': message.groupId,
      'senderId': message.senderId,
      'seq': message.seq,
    };
    for (final serial in await _memberSerials(room)) {
      if (_isSelfTransport(serial) || !DeviceLink.appReady(serial)) continue;
      try {
        await _sendJson(serial, 'chat.delete', body);
      } catch (error, stack) {
        log.warning('通知删除失败 $serial', error, stack);
      }
    }
    if (_bridge.available) {
      await _bridgeSend('chat.delete', body);
    }
  }

  Future<Map<String, Object?>?> _answer(Map<String, dynamic> json) async {
    final id = '${json['conversationId'] ?? ''}';
    final room = await store.conversation(id);
    if (room == null) {
      if (id.isEmpty) return null;
      return <String, Object?>{
        'conversationId': id,
        'closed': true,
        'head': 0,
        'cursor': 0,
        'senderId': '',
        'messages': <Object?>[],
      };
    }
    final onlySeq = _asInt(json['seq']);
    final onlySender = '${json['senderId'] ?? ''}';
    if (onlySeq > 0 && onlySender.isNotEmpty) {
      if (room.kind == kChatDirect) {
        if (onlySender != selfId.value) return null;
      } else if (!room.ownedBy(selfId.value)) {
        return null;
      }
      final found = await store.messageOf(id, onlySender, onlySeq);
      final message = found == null ? null : await _withBytes(found);
      final slice = ChatSlice(
        head: onlySeq,
        cursor: onlySeq,
        messages: message == null ? const <ChatMessage>[] : <ChatMessage>[message],
        dropped: await store.deletedKeys(id),
      );
      final single = slice.toJson(senderId: onlySender);
      single['conversationId'] = id;
      return single;
    }
    if (json['list'] == true) {
      if (room.kind == kChatDirect || !room.ownedBy(selfId.value)) return null;
      final page = await store.feed(id);
      final listed = ChatSlice(
        head: page.head,
        cursor: page.cursor,
        messages: page.messages,
        dropped: await store.deletedKeys(id),
      );
      final listedBody = listed.toJson();
      listedBody['conversationId'] = id;
      return listedBody;
    }
    final after = _asInt(json['after']);
    final fromSelf = json['fromSelf'] == true;
    if (room.kind == kChatDirect) {
      if (!fromSelf) return null;
      await store.setCursor(id, 'ack', after);
      final page = await store.page(id, after: after, senderId: selfId.value);
      final packed = ChatSlice(
        head: page.head,
        cursor: page.cursor,
        messages: page.messages,
        dropped: await store.deletedKeys(id),
      );
      final body = packed.toJson(senderId: selfId.value);
      body['conversationId'] = id;
      return body;
    }
    if (!room.ownedBy(selfId.value)) return null;
    final page = await store.page(id, after: after);
    final slice = ChatSlice(
      head: page.head,
      cursor: page.cursor,
      messages: page.messages,
      dropped: await store.deletedKeys(id),
    );
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
    final kept = await _keepSubmitted(draft);
    var message = ChatMessage(
      seq: seq,
      groupId: id,
      senderId: draft.senderId,
      senderName: draft.senderName,
      kind: draft.kind,
      body: kept?.body ?? draft.body,
      parentSeq: draft.parentSeq,
      mime: draft.mime,
      size: kept?.size ?? draft.size,
      createdAt: draft.createdAt == 0
          ? DateTime.now().millisecondsSinceEpoch
          : draft.createdAt,
      bytes: draft.bytes,
      filePath: kept?.path,
    );
    final bytes = message.bytes;
    if (bytes != null && bytes.isNotEmpty) {
      final path = await store.saveBytes(
        chatMediaId(message) ?? '${message.senderId}-$seq',
        bytes,
      );
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
      final path = await store.saveBytes(
        chatMediaId(draft) ?? '${draft.senderId}-${draft.seq}',
        bytes,
      );
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
    if (id.isEmpty || kind.isEmpty || await store.hasLeft(id)) return;
    if (await store.hasClosed(id)) return;
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
      if (DeviceLink.appReady(serial)) return serial;
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

  /// 私聊 id 是 `dm:发起人:对端`。发起人不是本机时，这份私聊不属于这里。
  bool _foreignDirect(String groupId, String ownerId, String kind) {
    final direct = kind == kChatDirect || groupId.startsWith('dm:');
    if (!direct) return false;
    final owner = ownerId.isNotEmpty
        ? ownerId
        : (groupId.startsWith('dm:')
              ? groupId.substring(3).split(':').first
              : '');
    return owner.isNotEmpty && owner != selfId.value;
  }
}

bool _sameSerial(String left, String right) {
  if (left.isEmpty || right.isEmpty) return false;
  if (left == 'unknown' || right == 'unknown') return false;
  return left == right;
}

bool pEqualsDir(String path, String directory) {
  final prefix = directory.endsWith(Platform.pathSeparator)
      ? directory
      : '$directory${Platform.pathSeparator}';
  return path.startsWith(prefix);
}

class ChatListing {
  const ChatListing({
    required this.id,
    required this.title,
    required this.ownerId,
    required this.ownerName,
    required this.via,
  });

  final String id;
  final String title;
  final String ownerId;
  final String ownerName;

  /// 空字符串表示从当前聊天通道问到的，否则是本机连上的设备序列号。
  final String via;
}

String? _optional(Object? value) {
  final text = value?.toString() ?? '';
  return text.isEmpty ? null : text;
}

int _asInt(Object? value) {
  if (value is int) return value;
  return int.tryParse('$value') ?? 0;
}

String _baseName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  if (index < 0) return path;
  return normalized.substring(index + 1);
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
