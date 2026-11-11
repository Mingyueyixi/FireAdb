import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../l10n/fireadb_localizations_ext.dart';
import '../../widgets/adaptive.dart';
import '../chat_controller.dart';
import '../chat_conversation.dart';
import 'chat_info_page.dart';
import 'chat_room_page.dart';
import 'chat_title.dart';
import 'chat_transcript.dart';

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
          SizedBox(width: 320, child: _list(context)),
          const VerticalDivider(width: 1),
          Expanded(child: _wideRoom(context)),
        ],
      );
    }
    return _list(context);
  }

  Widget _list(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        actions: <Widget>[
          IconButton(
            tooltip: l10n.chatNewDirect,
            onPressed: () => _direct(context),
            icon: const Icon(Icons.add_comment_outlined),
          ),
          IconButton(
            tooltip: l10n.chatNewGroup,
            onPressed: () => _group(context),
            icon: const Icon(Icons.group_add_outlined),
          ),
        ],
      ),
      body: Obx(() {
        final items = _chat.conversations.toList();
        return ListView(
          children: <Widget>[
            for (var index = 0; index < items.length; index++) ...<Widget>[
              _tile(context, items[index]),
              if (index == 0 && items.length == 1)
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
    final selected = isWide(context) && _chat.activeId.value == room.id;
    return ListTile(
      selected: selected,
      leading: Icon(_icon(room, selfId)),
      title: Text(title, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        room.isMyChannel(selfId)
            ? chatPreview(l10n, room)
            : '${chatKindLabel(l10n, room, selfId)} · ${chatPreview(l10n, room)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => _open(context, room.id),
    );
  }

  IconData _icon(ChatConversation room, String selfId) {
    if (room.kind == kChatDirect) return Icons.chat_bubble_outline;
    if (room.kind == kChatGroup) return Icons.group_outlined;
    if (room.isMyChannel(selfId)) return Icons.campaign_outlined;
    return Icons.podcasts_outlined;
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
                icon: const Icon(Icons.info_outline),
              ),
            ],
          ),
          const Divider(height: 1),
          Expanded(child: ChatTranscript(conversationId: id)),
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

  Future<void> _open(BuildContext context, String id) async {
    await _chat.openConversation(id);
    if (!context.mounted || isWide(context)) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ChatRoomPage(conversationId: id)),
    );
  }

  Future<void> _direct(BuildContext context) async {
    final picked = await showChatDevicePicker(
      context,
      devices: _chat.knownDevices(),
      title: context.l10n.chatNewDirect,
    );
    if (picked == null || !context.mounted) return;
    final id = await _chat.startDirect(picked.serial, picked.displayName);
    if (!context.mounted) return;
    await _openExisting(context, id);
  }

  Future<void> _group(BuildContext context) async {
    final l10n = context.l10n;
    final name = await showChatNameDialog(
      context,
      title: l10n.chatNewGroup,
      label: l10n.chatNameLabel,
      confirm: l10n.chatCreate,
    );
    if (name == null || !context.mounted) return;
    final id = await _chat.createGroup(name);
    if (!context.mounted || id.isEmpty) return;
    await _openExisting(context, id);
  }

  Future<void> _openExisting(BuildContext context, String id) async {
    if (isWide(context)) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ChatRoomPage(conversationId: id)),
    );
  }
}
