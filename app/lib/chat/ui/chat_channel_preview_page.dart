import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../app_feedback.dart';
import '../../l10n/fireadb_localizations_ext.dart';
import '../chat_controller.dart';
import '../chat_message.dart';
import '../chat_post.dart';
import 'chat_compose_page.dart';

class ChatChannelPreviewPage extends StatefulWidget {
  const ChatChannelPreviewPage({super.key, required this.channel});

  final ChatListing channel;

  @override
  State<ChatChannelPreviewPage> createState() => _ChatChannelPreviewPageState();
}

class _ChatChannelPreviewPageState extends State<ChatChannelPreviewPage> {
  List<ChatMessage> _messages = const <ChatMessage>[];
  var _loading = true;
  String? _error;
  var _busy = false;

  ChatController get _chat => Get.find<ChatController>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool get _joined {
    for (final room in _chat.conversations) {
      if (room.id == widget.channel.id && !room.closed) return true;
    }
    return false;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final messages = await _chat.previewChannel(widget.channel);
      if (!mounted) return;
      setState(() {
        _messages = messages;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  String get _title {
    final name = widget.channel.title.trim();
    if (name.isNotEmpty) return name;
    final owner = widget.channel.ownerName.trim();
    return owner.isEmpty ? widget.channel.id : owner;
  }

  Future<void> _join() async {
    setState(() => _busy = true);
    try {
      await _chat.joinChannel(widget.channel);
    } catch (error) {
      if (!mounted) return;
      showAppMessage(
        ScaffoldMessenger.of(context),
        Theme.of(context),
        title: context.l10n.chatJoin,
        message: context.l10n.chatJoinFailed,
        isError: true,
      );
      rethrow;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _compose() async {
    try {
      if (!_joined) await _join();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatComposePage(conversationId: widget.channel.id),
        ),
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final posts = <ChatMessage>[
      for (final message in _messages)
        if (message.kind == kChatPost && message.parentSeq == 0) message,
    ];
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: Column(
        children: <Widget>[
          Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: ListTile(
              title: Text(
                widget.channel.ownerName.trim().isEmpty
                    ? l10n.chatKindChannel
                    : widget.channel.ownerName,
              ),
              subtitle: Text(_joined ? l10n.chatJoined : l10n.chatNotJoined),
            ),
          ),
          if (!_joined)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(l10n.chatJoinOnPost),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Text(
                      _error!.contains('解散')
                          ? l10n.chatChannelClosed
                          : l10n.chatHostOffline,
                    ),
                  )
                : posts.isEmpty
                ? Center(child: Text(l10n.chatPlazaEmpty))
                : ListView.separated(
                    itemCount: posts.length,
                    separatorBuilder: (context, index) =>
                        const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final post = posts[index];
                      final text = latestPostText(post, _messages);
                      return ListTile(
                        title: Text(post.senderName),
                        subtitle: Text(
                          text.isEmpty ? l10n.chatPreviewEmpty : text,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => _PreviewPostPage(
                                channel: widget.channel,
                                post: post,
                                messages: _messages,
                                joined: _joined,
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  if (!_joined) ...<Widget>[
                    OutlinedButton(
                      onPressed: _busy ? null : () async {
                        try {
                          await _join();
                        } catch (_) {}
                      },
                      child: Text(l10n.chatJoin),
                    ),
                    const SizedBox(width: 8),
                  ],
                  FilledButton.icon(
                    onPressed: _busy || _error != null ? null : _compose,
                    icon: const Icon(Icons.edit_outlined),
                    label: Text(l10n.chatNewPost),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewPostPage extends StatefulWidget {
  const _PreviewPostPage({
    required this.channel,
    required this.post,
    required this.messages,
    required this.joined,
  });

  final ChatListing channel;
  final ChatMessage post;
  final List<ChatMessage> messages;
  final bool joined;

  @override
  State<_PreviewPostPage> createState() => _PreviewPostPageState();
}

class _PreviewPostPageState extends State<_PreviewPostPage> {
  final _comment = TextEditingController();
  var _busy = false;

  ChatController get _chat => Get.find<ChatController>();

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _comment.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      if (!widget.joined) await _chat.joinChannel(widget.channel);
      await _chat.discuss(widget.post.seq, text);
      if (!mounted) return;
      _comment.clear();
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      showAppMessage(
        ScaffoldMessenger.of(context),
        Theme.of(context),
        title: context.l10n.chatDiscuss,
        message: context.l10n.chatJoinFailed,
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final text = latestPostText(widget.post, widget.messages);
    final comments = <ChatMessage>[
      for (final message in widget.messages)
        if (message.parentSeq == widget.post.seq && message.kind == 'text')
          message,
    ];
    return Scaffold(
      appBar: AppBar(title: Text(widget.post.senderName)),
      body: Column(
        children: <Widget>[
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                Text(widget.post.senderName),
                if (text.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  SelectableText(text),
                ],
                const Divider(),
                Text(l10n.chatDiscuss, style: Theme.of(context).textTheme.titleSmall),
                for (final comment in comments)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('${comment.senderName}: ${comment.body}'),
                  ),
                if (!widget.joined) ...<Widget>[
                  const SizedBox(height: 16),
                  Text(l10n.chatJoinOnPost),
                ],
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
                      decoration: InputDecoration(
                        hintText: l10n.chatDiscussHint,
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.chatSend,
                    onPressed: _busy ? null : _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
