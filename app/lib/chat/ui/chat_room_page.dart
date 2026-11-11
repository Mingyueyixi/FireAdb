import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../l10n/fireadb_localizations_ext.dart';
import '../chat_controller.dart';
import '../chat_conversation.dart';
import 'chat_info_page.dart';
import 'chat_title.dart';
import 'chat_transcript.dart';

class ChatRoomPage extends StatefulWidget {
  const ChatRoomPage({super.key, required this.conversationId});

  final String conversationId;

  @override
  State<ChatRoomPage> createState() => _ChatRoomPageState();
}

class _ChatRoomPageState extends State<ChatRoomPage> {
  ChatController get _chat => Get.find<ChatController>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _chat.openConversation(widget.conversationId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    _chat.useSelfName(l10n.chatSelf);
    return Scaffold(
      appBar: AppBar(
        title: Obx(() {
          return Text(
            chatConversationTitle(l10n, _find(_chat), _chat.selfId.value),
          );
        }),
        actions: <Widget>[
          IconButton(
            tooltip: l10n.chatInfo,
            onPressed: () {
              _chat.refreshMembers();
              openChatInfo(context, widget.conversationId);
            },
            icon: const Icon(Icons.info_outline),
          ),
        ],
      ),
      body: ChatTranscript(conversationId: widget.conversationId),
    );
  }

  ChatConversation? _find(ChatController chat) {
    for (final item in chat.conversations) {
      if (item.id == widget.conversationId) return item;
    }
    return null;
  }
}

void openChatInfo(BuildContext context, String conversationId) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ChatInfoPage(conversationId: conversationId),
    ),
  );
}
