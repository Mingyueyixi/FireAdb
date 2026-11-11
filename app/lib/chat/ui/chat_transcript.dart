import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../app_feedback.dart';
import '../../l10n/fireadb_localizations_ext.dart';
import '../chat_controller.dart';
import '../chat_conversation.dart';
import '../chat_message.dart';

class ChatTranscript extends StatefulWidget {
  const ChatTranscript({super.key, required this.conversationId});

  final String conversationId;

  @override
  State<ChatTranscript> createState() => _ChatTranscriptState();
}

class _ChatTranscriptState extends State<ChatTranscript> {
  final _field = TextEditingController();
  ChatController get _chat => Get.find<ChatController>();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      children: <Widget>[
        Expanded(
          child: Obx(() {
            if (_chat.activeId.value != widget.conversationId) {
              return const Center(child: CircularProgressIndicator());
            }
            final messages = _chat.messages;
            if (messages.isEmpty) {
              return Center(child: Text(l10n.chatPreviewEmpty));
            }
            return ListView.builder(
              reverse: true,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: messages.length,
              itemBuilder: (context, index) {
                final message = messages[messages.length - 1 - index];
                return _bubble(context, message);
              },
            );
          }),
        ),
        Obx(() {
          final room = _room(widget.conversationId);
          final alone =
              room != null &&
              room.ownedBy(_chat.selfId.value) &&
              _chat.members.where((member) => !member.self).isEmpty;
          if (!alone) return const SizedBox.shrink();
          return Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(l10n.chatNeedMembers),
            ),
          );
        }),
        const Divider(height: 1),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                IconButton(
                  tooltip: l10n.chatAttach,
                  onPressed: _attach,
                  icon: const Icon(Icons.attach_file),
                ),
                Expanded(
                  child: TextField(
                    controller: _field,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.newline,
                    keyboardType: TextInputType.multiline,
                    decoration: InputDecoration(
                      hintText: l10n.chatHint,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: l10n.chatSend,
                  onPressed: _send,
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  ChatConversation? _room(String id) {
    for (final item in _chat.conversations) {
      if (item.id == id) return item;
    }
    return null;
  }

  Widget _bubble(BuildContext context, ChatMessage message) {
    final mine = message.senderId == _chat.selfId.value;
    final theme = Theme.of(context);
    final background = mine
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest;
    final time = DateTime.fromMillisecondsSinceEpoch(message.createdAt);
    final clock =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _delete(message),
        child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Card(
          color: background,
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(message.senderName, style: theme.textTheme.labelMedium),
                const SizedBox(height: 4),
                _body(context, message),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(clock, style: theme.textTheme.labelSmall),
                    if (message.pending) ...<Widget>[
                      const SizedBox(width: 4),
                      Icon(
                        Icons.schedule,
                        size: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, ChatMessage message) {
    if (message.kind == 'image' && message.filePath != null) {
      final file = File(message.filePath!);
      if (file.existsSync()) {
        return Image.file(file, height: 180, fit: BoxFit.contain);
      }
    }
    if (!message.isText) {
      final missing =
          message.filePath == null || !File(message.filePath!).existsSync();
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.insert_drive_file_outlined, size: 18),
          const SizedBox(width: 6),
          Flexible(
            child: Text(missing ? context.l10n.chatFileMissing : message.body),
          ),
        ],
      );
    }
    return Text(message.body);
  }

  Future<void> _delete(ChatMessage message) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) {
        final l10n = context.l10n;
        return AlertDialog(
          content: Text(l10n.chatDelete),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.commonCancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.chatDelete),
            ),
          ],
        );
      },
    );
    if (remove == true) await _chat.deleteMessage(message);
  }

  Future<void> _send() async {
    final text = _field.text;
    if (text.trim().isEmpty) return;
    await _run(() async {
      await _chat.sendText(text);
      _field.clear();
    });
  }

  Future<void> _attach() async {
    final file = await openFile();
    if (file == null) return;
    await _run(
      () =>
          _chat.sendFile(path: file.path, name: file.name, mime: file.mimeType),
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      showAppMessage(
        ScaffoldMessenger.of(context),
        Theme.of(context),
        title: context.l10n.chatSend,
        message: context.l10n.chatSendFailed('$error'),
        isError: true,
      );
    }
  }
}
