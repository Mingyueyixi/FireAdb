import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../app_feedback.dart';
import '../../capture/data/local_opener.dart';
import '../../l10n/fireadb_localizations_ext.dart';
import '../chat_controller.dart';
import '../chat_conversation.dart';
import '../chat_message.dart';
import 'chat_status.dart';
import 'chat_title.dart';

class ChatTranscript extends StatefulWidget {
  const ChatTranscript({super.key, required this.conversationId});

  final String conversationId;

  @override
  State<ChatTranscript> createState() => _ChatTranscriptState();
}

class _ChatTranscriptState extends State<ChatTranscript> {
  final _field = TextEditingController();
  final _inputFocus = FocusNode();
  final _selected = <String>{};
  var _selecting = false;
  ChatController get _chat => Get.find<ChatController>();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  @override
  void didUpdateWidget(ChatTranscript oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId) {
      _selecting = false;
      _selected.clear();
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _inputFocus.dispose();
    _field.dispose();
    super.dispose();
  }

  bool _onHardwareKey(KeyEvent event) {
    if (!_inputFocus.hasFocus || event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.enter) return false;
    if (HardwareKeyboard.instance.isShiftPressed) return false;
    _send();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      children: <Widget>[
        Obx(() {
          final room = _room(widget.conversationId);
          if (room == null || room.kind != kChatDirect) {
            return const SizedBox.shrink();
          }
          return ChatStatusBanner(room: room);
        }),
        if (_selecting) _selectionBar(context),
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
                    focusNode: _inputFocus,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
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

  Widget _selectionBar(BuildContext context) {
    final l10n = context.l10n;
    final chosen = _chosen();
    final canCopy = chosen.isNotEmpty && chosen.every((item) => item.isText);
    return Material(
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: l10n.commonCancel,
            onPressed: _clearSelection,
            icon: const Icon(Icons.close),
          ),
          Text(l10n.chatSelected(_selected.length)),
          const Spacer(),
          IconButton(
            tooltip: l10n.chatForward,
            onPressed: chosen.isEmpty ? null : () => _forward(chosen),
            icon: const Icon(Icons.forward),
          ),
          IconButton(
            tooltip: l10n.chatCopy,
            onPressed: canCopy ? () => _copy(chosen) : null,
            icon: const Icon(Icons.copy),
          ),
          IconButton(
            tooltip: l10n.chatDelete,
            onPressed: chosen.isEmpty ? null : () => _deleteAll(chosen),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }

  ChatConversation? _room(String id) {
    for (final item in _chat.conversations) {
      if (item.id == id) return item;
    }
    return null;
  }

  List<ChatMessage> _chosen() {
    return <ChatMessage>[
      for (final message in _chat.messages)
        if (_selected.contains(message.id)) message,
    ];
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
    final picked = _selected.contains(message.id);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onTap: () => _tap(message),
        onLongPress: () => _selecting ? _toggle(message) : _menu(message),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            color: background,
            margin: const EdgeInsets.symmetric(vertical: 4),
            shape: picked
                ? RoundedRectangleBorder(
                    side: BorderSide(color: theme.colorScheme.primary, width: 2),
                    borderRadius: BorderRadius.circular(12),
                  )
                : null,
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
    if (message.kind == 'image') {
      final path = _chat.placed(message);
      if (path != null) {
        return Image.file(File(path), height: 180, fit: BoxFit.contain);
      }
    }
    if (!message.isText) {
      final ready = _chat.placed(message) != null;
      final label = chatMediaName(message);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.insert_drive_file_outlined, size: 18),
          const SizedBox(width: 6),
          Flexible(
            child: Text(ready ? (label.isEmpty ? message.body : label) : context.l10n.chatFileDownload),
          ),
        ],
      );
    }
    return Text(message.body);
  }

  Future<void> _tap(ChatMessage message) async {
    if (_selecting) {
      _toggle(message);
      return;
    }
    final path = _chat.placed(message);
    if (message.kind == 'image' && path != null) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ChatImagePage(path: path)),
      );
      return;
    }
    if (message.isText || message.kind == 'image') return;
    final saved = await _chat.downloadFile(message);
    if (!mounted) return;
    if (saved == null) {
      showAppMessage(
        ScaffoldMessenger.of(context),
        Theme.of(context),
        title: message.body,
        message: context.l10n.chatFileMissing,
        isError: true,
      );
      return;
    }
    await openLocalPath(saved, openFile: true);
  }

  void _toggle(ChatMessage message) {
    setState(() {
      if (!_selected.add(message.id)) _selected.remove(message.id);
      if (_selected.isEmpty) _selecting = false;
    });
  }

  void _clearSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  Future<void> _menu(ChatMessage message) async {
    final l10n = context.l10n;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.forward),
                title: Text(l10n.chatForward),
                onTap: () => Navigator.pop(context, 'forward'),
              ),
              if (message.isText)
                ListTile(
                  leading: const Icon(Icons.copy),
                  title: Text(l10n.chatCopy),
                  onTap: () => Navigator.pop(context, 'copy'),
                ),
              ListTile(
                leading: const Icon(Icons.checklist),
                title: Text(l10n.chatSelectMore),
                onTap: () => Navigator.pop(context, 'select'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(l10n.chatDelete),
                onTap: () => Navigator.pop(context, 'delete'),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'forward':
        await _forward(<ChatMessage>[message]);
      case 'copy':
        await _copy(<ChatMessage>[message]);
      case 'select':
        setState(() {
          _selecting = true;
          _selected
            ..clear()
            ..add(message.id);
        });
      case 'delete':
        await _deleteAll(<ChatMessage>[message]);
    }
  }

  Future<void> _forward(List<ChatMessage> messages) async {
    final l10n = context.l10n;
    final targets = <ChatConversation>[
      for (final room in _chat.conversations)
        if (room.id != widget.conversationId) room,
    ];
    final target = await showDialog<ChatConversation>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(l10n.chatForwardTo),
          content: SizedBox(
            width: 420,
            height: targets.isEmpty ? null : 320,
            child: targets.isEmpty
                ? Text(l10n.chatNoForward)
                : ListView(
                    children: <Widget>[
                      for (final room in targets)
                        ListTile(
                          title: Text(
                            chatConversationTitle(
                              l10n,
                              room,
                              _chat.selfId.value,
                            ),
                          ),
                          onTap: () => Navigator.of(context).pop(room),
                        ),
                    ],
                  ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.commonCancel),
            ),
          ],
        );
      },
    );
    if (target == null) return;
    await _run(() async {
      await _chat.forwardMessages(messages, target.id);
      if (mounted) _clearSelection();
    });
  }

  Future<void> _copy(List<ChatMessage> messages) async {
    final text = messages.map((message) => message.body).join('\n');
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    showAppMessage(
      ScaffoldMessenger.of(context),
      Theme.of(context),
      title: context.l10n.chatCopy,
      message: context.l10n.chatCopied,
    );
    _clearSelection();
  }

  Future<void> _deleteAll(List<ChatMessage> messages) async {
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
    if (remove != true) return;
    for (final message in messages) {
      await _chat.deleteMessage(message);
    }
    if (mounted) _clearSelection();
  }

  Future<void> _send() async {
    final text = _field.text;
    if (text.trim().isEmpty) return;
    _field.clear();
    await _run(() => _chat.sendText(text), restore: text);
  }

  Future<void> _attach() async {
    final file = await openFile();
    if (file == null) return;
    await _run(
      () =>
          _chat.sendFile(path: file.path, name: file.name, mime: file.mimeType),
    );
  }

  Future<void> _run(Future<void> Function() action, {String? restore}) async {
    try {
      await action();
    } catch (error) {
      if (restore != null && _field.text.isEmpty) _field.text = restore;
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

class ChatImagePage extends StatelessWidget {
  const ChatImagePage({super.key, required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: InteractiveViewer(
        minScale: 0.5,
        maxScale: 4,
        child: Center(child: Image.file(File(path), fit: BoxFit.contain)),
      ),
    );
  }
}
