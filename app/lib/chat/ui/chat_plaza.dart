import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../app_feedback.dart';
import '../../capture/data/local_opener.dart';
import '../../l10n/fireadb_localizations_ext.dart';
import '../chat_controller.dart';
import '../chat_conversation.dart';
import '../chat_message.dart';
import '../chat_post.dart';
import 'chat_compose_page.dart';
import 'chat_media.dart';
import 'chat_post_page.dart';
import 'chat_status.dart';
import 'chat_transcript.dart';

class ChatPlaza extends StatelessWidget {
  const ChatPlaza({super.key, required this.conversationId});

  final String conversationId;

  ChatController get _chat => Get.find<ChatController>();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Obx(() {
      final room = _room();
      final posts = <ChatMessage>[
        for (final message in _chat.messages)
          if (message.kind == kChatPost && message.parentSeq == 0) message,
      ];
      posts.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return Column(
        children: <Widget>[
          if (room != null) ChatStatusBanner(room: room),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _chat.refreshChannel(conversationId),
              child: posts.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: <Widget>[
                      SizedBox(
                        height: 240,
                        child: Center(child: Text(l10n.chatPlazaEmpty)),
                      ),
                    ],
                  )
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: posts.length,
                    separatorBuilder: (context, index) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final post = posts[index];
                      final text = latestPostText(post, _chat.messages);
                      final images = _children(post.seq, 'image');
                      final files = _children(post.seq, 'file');
                      return InkWell(
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => ChatPostPage(
                                conversationId: conversationId,
                                senderId: post.senderId,
                                seq: post.seq,
                              ),
                            ),
                          );
                        },
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                post.senderName,
                                style: Theme.of(context).textTheme.labelMedium,
                              ),
                              if (text.isNotEmpty) ...<Widget>[
                                const SizedBox(height: 6),
                                Text(text, maxLines: 4, overflow: TextOverflow.ellipsis),
                              ],
                              if (images.isNotEmpty) ...<Widget>[
                                const SizedBox(height: 8),
                                ChatMediaGrid(
                                  paths: <String?>[
                                    for (final image in images.take(9))
                                      _chat.placed(image),
                                  ],
                                  onTap: (imageIndex) {
                                    final path = _chat.placed(images[imageIndex]);
                                    if (path == null) return;
                                    Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) => ChatImagePage(path: path),
                                      ),
                                    );
                                  },
                                ),
                              ],
                              if (files.isNotEmpty) ...<Widget>[
                                const SizedBox(height: 8),
                                for (final file in files)
                                  GestureDetector(
                                    onTap: () => _download(context, file),
                                    child: Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Row(
                                        children: <Widget>[
                                          const Icon(Icons.insert_drive_file_outlined, size: 16),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              chatMediaName(file).isEmpty
                                                ? file.body
                                                : chatMediaName(file),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
            ),
          ),
          SafeArea(
            top: false,
            child: Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ChatComposePage(conversationId: conversationId),
                      ),
                    );
                  },
                  icon: const Icon(Icons.edit_outlined),
                  label: Text(l10n.chatNewPost),
                ),
              ),
            ),
          ),
        ],
      );
    });
  }

  ChatConversation? _room() {
    for (final item in _chat.conversations) {
      if (item.id == conversationId) return item;
    }
    return null;
  }

  Future<void> _download(BuildContext context, ChatMessage file) async {
    final path = await _chat.downloadFile(file);
    if (!context.mounted) return;
    if (path == null) {
      showAppMessage(
        ScaffoldMessenger.of(context),
        Theme.of(context),
        title: file.body,
        message: context.l10n.chatFileMissing,
        isError: true,
      );
      return;
    }
    await openLocalPath(path, openFile: true);
  }

  List<ChatMessage> _children(int seq, String kind) {
    final found = <ChatMessage>[
      for (final message in _chat.messages)
        if (message.parentSeq == seq && message.kind == kind) message,
    ];
    found.sort((a, b) => a.seq.compareTo(b.seq));
    return found;
  }
}
