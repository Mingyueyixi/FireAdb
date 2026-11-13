import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../l10n/fireadb_localizations_ext.dart';
import '../chat_controller.dart';
import '../chat_conversation.dart';

class ChatStatusBanner extends StatelessWidget {
  const ChatStatusBanner({super.key, required this.room});

  final ChatConversation room;

  @override
  Widget build(BuildContext context) {
    final chat = Get.find<ChatController>();
    final l10n = context.l10n;
    return Obx(() {
      final presence = chat.presenceOf(room);
      final text = chat.isSelfChat(room)
          ? l10n.chatSelfDirect
          : switch (presence) {
        ChatPresence.ready when room.kind == kChatDirect => l10n.chatPeerOnline,
        ChatPresence.ready when room.ownedBy(chat.selfId.value) =>
          chat.desktopOnlyReach
              ? l10n.chatDesktopOnline
              : l10n.chatReachCount(chat.ownerReachCount()),
        ChatPresence.ready => l10n.chatHostOnline,
        ChatPresence.peerOffline => l10n.chatPeerOffline,
        ChatPresence.hostOffline => l10n.chatHostOffline,
        ChatPresence.nobodyReached => l10n.chatNobodyReached,
      };
      return Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(text),
        ),
      );
    });
  }
}
