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
import 'chat_transcript.dart';

class ChatPostPage extends StatefulWidget {
  const ChatPostPage({
    super.key,
    required this.conversationId,
    required this.senderId,
    required this.seq,
  });

  final String conversationId;
  final String senderId;
  final int seq;

  @override
  State<ChatPostPage> createState() => _ChatPostPageState();
}

class _ChatPostPageState extends State<ChatPostPage> {
  final _comment = TextEditingController();
  ChatController get _chat => Get.find<ChatController>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chat.activeId.value != widget.conversationId) {
        _chat.openConversation(widget.conversationId);
      }
    });
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Obx(() {
      final post = _post();
      if (post == null) {
        return Scaffold(appBar: AppBar(), body: const SizedBox.shrink());
      }
      final text = latestPostText(post, _chat.messages);
      final images = _children(post.seq, 'image');
      final files = _children(post.seq, 'file');
      final comments = _children(post.seq, 'text');
      final room = _room();
      final canWrite = room != null && _chat.canPost(room);
      return Scaffold(
        appBar: AppBar(
          title: Text(post.senderName),
          actions: <Widget>[
            if (_chat.canRevise(post))
              IconButton(
                tooltip: l10n.chatEditPost,
                onPressed: canWrite
                    ? () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ChatComposePage(
                              conversationId: widget.conversationId,
                              editing: post,
                              initialText: text,
                              existingImages: images,
                              existingFiles: files,
                            ),
                          ),
                        );
                      }
                    : null,
                icon: const Icon(Icons.edit_outlined),
              ),
          ],
        ),
        body: Column(
          children: <Widget>[
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  Text(post.senderName, style: Theme.of(context).textTheme.labelMedium),
                  if (text.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 12),
                    SelectableText(text),
                  ],
                  if (images.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 12),
                    ChatMediaGrid(
                      paths: <String?>[
                        for (final image in images) _chat.placed(image),
                      ],
                      onTap: (index) {
                        final path = _chat.placed(images[index]);
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
                    const SizedBox(height: 12),
                    for (final file in files)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.insert_drive_file_outlined),
                        title: Text(
                          chatMediaName(file).isEmpty ? file.body : chatMediaName(file),
                        ),
                        subtitle: Text(
                          _chat.placed(file) != null ? '' : l10n.chatFileDownload,
                        ),
                        onTap: () => _openFile(file),
                      ),
                  ],
                  const Divider(),
                  Text(l10n.chatDiscuss, style: Theme.of(context).textTheme.titleSmall),
                  for (final comment in comments)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('${comment.senderName}: ${comment.body}'),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: _comment,
                        enabled: canWrite,
                        decoration: InputDecoration(
                          hintText: l10n.chatDiscussHint,
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                        onSubmitted: canWrite ? (_) => _sendComment() : null,
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.chatSend,
                      onPressed: canWrite ? _sendComment : null,
                      icon: const Icon(Icons.send),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    });
  }

  ChatConversation? _room() {
    for (final item in _chat.conversations) {
      if (item.id == widget.conversationId) return item;
    }
    return null;
  }

  ChatMessage? _post() {
    for (final message in _chat.messages) {
      if (message.kind == kChatPost &&
          message.senderId == widget.senderId &&
          message.seq == widget.seq) {
        return message;
      }
    }
    return null;
  }

  List<ChatMessage> _children(int seq, String kind) {
    final found = <ChatMessage>[
      for (final message in _chat.messages)
        if (message.parentSeq == seq && message.kind == kind) message,
    ];
    found.sort((a, b) => a.seq.compareTo(b.seq));
    return found;
  }

  Future<void> _openFile(ChatMessage file) async {
    final path = await _chat.downloadFile(file);
    if (!mounted) return;
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

  Future<void> _sendComment() async {
    final text = _comment.text;
    if (text.trim().isEmpty) return;
    _comment.clear();
    try {
      await _chat.discuss(widget.seq, text);
    } catch (error) {
      if (!mounted) return;
      _comment.text = text;
      showAppMessage(
        ScaffoldMessenger.of(context),
        Theme.of(context),
        title: context.l10n.chatDiscuss,
        message: context.l10n.chatSendFailed('$error'),
        isError: true,
      );
    }
  }
}
