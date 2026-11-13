import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../l10n/fireadb_localizations_ext.dart';
import '../../widgets/adaptive.dart';
import '../chat_controller.dart';
import '../chat_conversation.dart';
import 'chat_discover_page.dart';
import 'chat_info_page.dart';
import 'chat_plaza.dart';
import 'chat_room_page.dart';
import 'chat_title.dart';
import 'chat_transcript.dart';

class _KeepReading extends StatefulWidget {
  const _KeepReading({required this.id, required this.child});

  final String id;
  final Widget child;

  @override
  State<_KeepReading> createState() => _KeepReadingState();
}

class _KeepReadingState extends State<_KeepReading> {
  ChatController get _chat => Get.find<ChatController>();

  @override
  void initState() {
    super.initState();
    _chat.watch(widget.id);
  }

  @override
  void didUpdateWidget(_KeepReading oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) _chat.watch(widget.id);
  }

  @override
  void dispose() {
    _chat.unwatch(widget.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class ChatPage extends StatelessWidget {
  const ChatPage({super.key});

  ChatController get _chat => Get.find<ChatController>();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    _chat.useSelfName(l10n.chatSelf);
    if (isWide(context)) {
      return Row(
        children: <Widget>[
          const SizedBox(width: 320, child: _ChatList()),
          const VerticalDivider(width: 1),
          Expanded(child: _wideRoom(context)),
        ],
      );
    }
    return const _ChatList();
  }

  Widget _wideRoom(BuildContext context) {
    final l10n = context.l10n;
    return Obx(() {
      final id = _chat.activeId.value;
      if (id.isEmpty) {
        return Center(child: Text(l10n.chatSelect));
      }
      return Column(
        children: <Widget>[
          AppBar(
            automaticallyImplyLeading: false,
            title: Text(
              chatConversationTitle(l10n, _find(id), _chat.selfId.value),
            ),
            actions: <Widget>[
              IconButton(
                tooltip: l10n.chatInfo,
                onPressed: () {
                  _chat.refreshMembers();
                  openChatInfo(context, id);
                },
                icon: const Icon(Icons.more_vert),
              ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: _KeepReading(
              id: id,
              child: _find(id)?.kind == kChatDirect
                  ? ChatTranscript(conversationId: id)
                  : ChatPlaza(conversationId: id),
            ),
          ),
        ],
      );
    });
  }

  ChatConversation? _find(String id) {
    for (final item in _chat.conversations) {
      if (item.id == id) return item;
    }
    return null;
  }

}

class _ChatList extends StatefulWidget {
  const _ChatList();

  @override
  State<_ChatList> createState() => _ChatListState();
}

class _ChatListState extends State<_ChatList> {
  final Set<String> _selected = <String>{};
  bool _selecting = false;

  ChatController get _chat => Get.find<ChatController>();

  bool get _desktop {
    switch (Theme.of(context).platform) {
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
        return true;
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: _selecting
            ? IconButton(
                tooltip: l10n.commonCancel,
                onPressed: _clearSelection,
                icon: const Icon(Icons.close),
              )
            : null,
        title: Text(
          _selecting ? l10n.chatSelected(_selected.length) : l10n.chatTitle,
        ),
        actions: _selecting
            ? <Widget>[
                IconButton(
                  tooltip: _batchLabel(_selectedRooms()),
                  onPressed: _selected.isEmpty ? null : _removeSelected,
                  icon: Icon(_batchIcon(_selectedRooms())),
                ),
              ]
            : <Widget>[
                if (_desktop)
                  IconButton(
                    tooltip: l10n.chatSelectMore,
                    onPressed: () => setState(() => _selecting = true),
                    icon: const Icon(Icons.checklist),
                  ),
                IconButton(
                  tooltip: l10n.chatDiscover,
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const ChatDiscoverPage(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.travel_explore),
                ),
                IconButton(
                  tooltip: l10n.chatNewDirect,
                  onPressed: () => _direct(context),
                  icon: const Icon(Icons.add_comment_outlined),
                ),
                IconButton(
                  tooltip: l10n.chatNewGroup,
                  onPressed: () => _channel(context),
                  icon: const Icon(Icons.campaign_outlined),
                ),
              ],
      ),
      body: Obx(() {
        final items = _chat.conversations.toList();
        return ListView(
          children: <Widget>[
            for (var index = 0; index < items.length; index++) ...<Widget>[
              _tile(context, items[index]),
              if (index == 0 && items.length == 1 && !_selecting)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Text(l10n.chatEmpty),
                ),
            ],
          ],
        );
      }),
    );
  }

  Widget _tile(BuildContext context, ChatConversation room) {
    final l10n = context.l10n;
    final selfId = _chat.selfId.value;
    final title = chatConversationTitle(l10n, room, selfId);
    final picked = _selected.contains(room.id);
    final openHere = isWide(context) && _chat.activeId.value == room.id;
    final tile = ListTile(
      selected: picked || openHere,
      leading: _selecting
          ? Icon(
              picked ? Icons.check_circle : Icons.circle_outlined,
              color: picked ? Theme.of(context).colorScheme.primary : null,
            )
          : Badge(
              isLabelVisible: room.unread > 0,
              backgroundColor: const Color(0xFFE53935),
              label: Text(room.unread > 99 ? '99+' : '${room.unread}'),
              child: Icon(_icon(room, selfId)),
            ),
      title: Text(title, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        room.closed
            ? l10n.chatChannelClosed
            : room.isMyChannel(selfId)
            ? chatPreview(l10n, room)
            : '${chatKindLabel(l10n, room, selfId)} · ${chatPreview(l10n, room)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () {
        if (_selecting) {
          _toggle(room.id);
          return;
        }
        _open(context, room.id);
      },
    );
    final row = GestureDetector(
      onSecondaryTapDown: _selecting
          ? null
          : (details) => _menu(context, room, details.globalPosition),
      onLongPressStart: (details) {
        if (_selecting) {
          _toggle(room.id);
          return;
        }
        _menu(context, room, details.globalPosition);
      },
      child: tile,
    );
    if (_selecting || _desktop || !_canDrop(room)) return row;
    final leaving = room.kind != kChatDirect;
    return Dismissible(
      key: ValueKey(room.id),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => _confirm(
        context,
        leaving ? l10n.chatLeaveConfirm : l10n.chatRemoveConversationConfirm,
        leaving ? l10n.chatLeave : l10n.chatRemoveConversation,
      ),
      onDismissed: (_) {
        _chat.conversations.removeWhere((item) => item.id == room.id);
        if (leaving) {
          unawaited(_chat.leaveChannel(room.id));
        } else {
          unawaited(_chat.removeConversation(room.id));
        }
      },
      background: Container(
        alignment: Alignment.centerRight,
        color: Theme.of(context).colorScheme.error,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Icon(
          Icons.delete_outline,
          color: Theme.of(context).colorScheme.onError,
        ),
      ),
      child: row,
    );
  }

  IconData _icon(ChatConversation room, String selfId) {
    if (room.kind == kChatDirect) return Icons.chat_bubble_outline;
    if (room.isMyChannel(selfId) || room.ownedBy(selfId)) {
      return Icons.campaign_outlined;
    }
    return Icons.podcasts_outlined;
  }

  void _toggle(String id) {
    setState(() {
      if (!_selected.add(id)) _selected.remove(id);
      if (_selected.isEmpty) _selecting = false;
    });
  }

  void _clearSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  Future<void> _menu(
    BuildContext context,
    ChatConversation room,
    Offset position,
  ) async {
    final l10n = context.l10n;
    final String? action;
    if (_desktop) {
      final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
      action = await showMenu<String>(
        context: context,
        position: RelativeRect.fromRect(
          Rect.fromLTWH(position.dx, position.dy, 0, 0),
          Offset.zero & overlay.size,
        ),
        items: <PopupMenuEntry<String>>[
          if (_canDrop(room))
            PopupMenuItem<String>(
              value: 'remove',
              child: Text(
                room.kind == kChatDirect
                    ? l10n.chatRemoveConversation
                    : l10n.chatLeave,
              ),
            ),
          PopupMenuItem<String>(
            value: 'select',
            child: Text(l10n.chatSelectMore),
          ),
        ],
      );
    } else {
      action = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (context) {
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (_canDrop(room))
                  ListTile(
                    leading: Icon(
                      room.kind == kChatDirect
                          ? Icons.delete_outline
                          : Icons.logout,
                    ),
                    title: Text(
                      room.kind == kChatDirect
                          ? l10n.chatRemoveConversation
                          : l10n.chatLeave,
                    ),
                    onTap: () => Navigator.pop(context, 'remove'),
                  ),
                ListTile(
                  leading: const Icon(Icons.checklist),
                  title: Text(l10n.chatSelectMore),
                  onTap: () => Navigator.pop(context, 'select'),
                ),
              ],
            ),
          );
        },
      );
    }
    if (!mounted || action == null) return;
    if (action == 'select') {
      setState(() {
        _selecting = true;
        _selected.clear();
        _selected.add(room.id);
      });
      return;
    }
    await _removeIds(<String>[room.id]);
  }

  Future<void> _removeSelected() => _removeIds(_selected.toList());

  bool _canDrop(ChatConversation room) {
    final selfId = _chat.selfId.value;
    if (room.kind == kChatDirect) return true;
    return !room.isMyChannel(selfId) && !room.ownedBy(selfId);
  }

  bool _hosted(ChatConversation room) {
    return room.kind != kChatDirect && room.ownedBy(_chat.selfId.value);
  }

  List<ChatConversation> _selectedRooms() {
    return <ChatConversation>[
      for (final id in _selected) ?_listed(id),
    ];
  }

  String _batchLabel(List<ChatConversation> rooms) {
    final l10n = context.l10n;
    if (rooms.isNotEmpty && rooms.every(_hosted)) return l10n.chatDisband;
    if (rooms.isNotEmpty && rooms.every((room) => room.kind != kChatDirect)) {
      return l10n.chatLeave;
    }
    return l10n.chatRemoveConversation;
  }

  IconData _batchIcon(List<ChatConversation> rooms) {
    if (rooms.isNotEmpty && rooms.every(_hosted)) return Icons.delete_forever_outlined;
    if (rooms.isNotEmpty && rooms.every((room) => room.kind != kChatDirect)) {
      return Icons.logout;
    }
    return Icons.delete_outline;
  }

  ChatConversation? _listed(String id) {
    for (final item in _chat.conversations) {
      if (item.id == id) return item;
    }
    return null;
  }

  Future<void> _removeIds(List<String> ids) async {
    final rooms = <ChatConversation>[
      for (final id in ids) ?_listed(id),
    ];
    if (rooms.isEmpty || !mounted) return;
    final l10n = context.l10n;
    final hosted = rooms.where(_hosted).length;
    final joined = rooms.where((room) => room.kind != kChatDirect && !_hosted(room)).length;
    final direct = rooms.length - hosted - joined;
    final String message;
    if (hosted == rooms.length && rooms.length == 1) {
      message = l10n.chatDisbandConfirm;
    } else if (hosted == rooms.length) {
      message = l10n.chatDisbandSelectedConfirm;
    } else if (joined == rooms.length && rooms.length == 1) {
      message = l10n.chatLeaveConfirm;
    } else if (direct == rooms.length && rooms.length == 1) {
      message = l10n.chatRemoveConversationConfirm;
    } else if (hosted > 0 && (joined > 0 || direct > 0)) {
      message = l10n.chatApplySelectedConfirm;
    } else {
      message = l10n.chatRemoveSelectedConfirm;
    }
    final confirmed = await _confirm(context, message, _batchLabel(rooms));
    if (!confirmed || !mounted) return;
    setState(() {
      _selecting = false;
      _selected.clear();
    });
    for (final room in rooms) {
      if (room.kind == kChatDirect) {
        await _chat.removeConversation(room.id);
      } else if (_hosted(room)) {
        await _chat.disbandChannel(room.id);
      } else {
        await _chat.leaveChannel(room.id);
      }
    }
  }

  Future<bool> _confirm(
    BuildContext context,
    String message,
    String action,
  ) async {
    final l10n = context.l10n;
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          content: Text(message),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.commonCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(action),
            ),
          ],
        );
      },
    );
    return answer == true;
  }

  void _open(BuildContext context, String id) {
    unawaited(_chat.openConversation(id));
    if (isWide(context)) return;
    if (!_chat.claimRoomRoute(id)) return;
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => ChatRoomPage(conversationId: id),
          ),
        )
        .whenComplete(() => _chat.releaseRoomRoute(id));
  }

  Future<void> _direct(BuildContext context) async {
    final picked = await showChatDevicePicker(
      context,
      devices: _chat.onlineChatDevices(),
      title: context.l10n.chatNewDirect,
      empty: context.l10n.chatNoOnlineDevices,
    );
    if (picked == null || !context.mounted) return;
    final id = await _chat.startDirect(picked.serial, picked.displayName);
    if (!context.mounted) return;
    _open(context, id);
  }

  Future<void> _channel(BuildContext context) async {
    final l10n = context.l10n;
    final name = await showChatNameDialog(
      context,
      title: l10n.chatNewGroup,
      label: l10n.chatNameLabel,
      confirm: l10n.chatCreate,
    );
    if (name == null || !context.mounted) return;
    final id = await _chat.createChannel(name);
    if (!context.mounted || id.isEmpty) return;
    _open(context, id);
  }
}
