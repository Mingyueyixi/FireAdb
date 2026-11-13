import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../app_feedback.dart';
import '../../l10n/fireadb_localizations_ext.dart';
import '../chat_controller.dart';
import 'chat_channel_preview_page.dart';

class ChatDiscoverPage extends StatefulWidget {
  const ChatDiscoverPage({super.key});

  @override
  State<ChatDiscoverPage> createState() => _ChatDiscoverPageState();
}

class _ChatDiscoverPageState extends State<ChatDiscoverPage> {
  final Set<String> _joining = <String>{};
  List<ChatListing> _channels = const <ChatListing>[];
  var _loading = true;

  ChatController get _chat => Get.find<ChatController>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final found = await _chat.discoverChannels();
    if (!mounted) return;
    setState(() {
      _channels = found;
      _loading = false;
    });
  }

  bool _joined(String id) {
    for (final room in _chat.conversations) {
      if (room.id == id && !room.closed) return true;
    }
    return false;
  }

  Future<void> _join(ChatListing channel) async {
    setState(() => _joining.add(channel.id));
    try {
      await _chat.joinChannel(channel);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      showAppMessage(
        ScaffoldMessenger.of(context),
        Theme.of(context),
        title: context.l10n.chatJoin,
        message: context.l10n.chatJoinFailed,
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _joining.remove(channel.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.chatDiscover)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: Obx(() {
          final _ = _chat.conversations.length;
          if (_loading && _channels.isEmpty) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: <Widget>[
                const SizedBox(height: 48),
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 16),
                Center(child: Text(l10n.chatDiscovering)),
              ],
            );
          }
          if (_channels.isEmpty) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: <Widget>[
                const SizedBox(height: 120),
                Center(child: Text(l10n.chatDiscoverEmpty)),
              ],
            );
          }
          return ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: _channels.length,
            separatorBuilder: (context, index) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final channel = _channels[index];
              final joined = _joined(channel.id);
              final busy = _joining.contains(channel.id);
              final title = channel.title.trim().isEmpty
                  ? channel.ownerName
                  : channel.title;
              return ListTile(
                leading: const Icon(Icons.campaign_outlined),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ChatChannelPreviewPage(channel: channel),
                    ),
                  );
                },
                title: Text(title, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  channel.ownerName.trim().isEmpty
                      ? l10n.chatKindChannel
                      : channel.ownerName,
                ),
                trailing: joined
                    ? Text(l10n.chatJoined)
                    : FilledButton(
                        onPressed: busy ? null : () => _join(channel),
                        child: busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(l10n.chatJoin),
                      ),
              );
            },
          );
        }),
      ),
    );
  }
}
