import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../connection/model/device_profile.dart';
import '../../l10n/fireadb_localizations_ext.dart';
import '../chat_controller.dart';
import '../chat_conversation.dart';
import 'chat_title.dart';

class ChatInfoPage extends StatefulWidget {
  const ChatInfoPage({super.key, required this.conversationId});

  final String conversationId;

  @override
  State<ChatInfoPage> createState() => _ChatInfoPageState();
}

class _ChatInfoPageState extends State<ChatInfoPage> {
  ChatController get _chat => Get.find<ChatController>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chat.activeId.value != widget.conversationId) {
        _chat.openConversation(widget.conversationId);
      } else {
        _chat.refreshMembers();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    _chat.useSelfName(l10n.chatSelf);
    return Obx(() {
      final room = _room();
      final _ = _chat.linkTick.value;
      final title = chatConversationTitle(l10n, room, _chat.selfId.value);
      final owned = room?.ownedBy(_chat.selfId.value) ?? false;
      final direct = room?.kind == kChatDirect;
      return Scaffold(
        appBar: AppBar(
          title: Text(l10n.chatInfo),
          actions: <Widget>[
            if (owned && !direct)
              IconButton(
                tooltip: l10n.chatRename,
                onPressed: () => _rename(context, title),
                icon: const Icon(Icons.edit_outlined),
              ),
            if (owned && !direct)
              IconButton(
                tooltip: l10n.chatAddMember,
                onPressed: () => _add(context),
                icon: const Icon(Icons.person_add_alt_1),
              ),
          ],
        ),
        body: ListView(
          children: direct && room != null
              ? _directInfo(context, room, title)
              : <Widget>[
            ListTile(
              title: Text(title),
              subtitle: Text(
                room == null
                    ? ''
                    : chatKindLabel(l10n, room, _chat.selfId.value),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                l10n.chatMembers,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            if (room != null && room.kind != kChatDirect)
              ListTile(
                iconColor: owned
                    ? Theme.of(context).colorScheme.error
                    : null,
                textColor: owned
                    ? Theme.of(context).colorScheme.error
                    : null,
                leading: Icon(
                  owned ? Icons.delete_outline : Icons.logout,
                ),
                title: Text(owned ? l10n.chatDisband : l10n.chatLeave),
                onTap: () => owned ? _disband(context) : _leave(context),
              ),
            if (room != null &&
                room.ownedBy(_chat.selfId.value) &&
                _chat.ownerReachCount() > 0)
              ListTile(
                leading: const Icon(Icons.forum_outlined),
                title: Text(l10n.chatReachCount(_chat.ownerReachCount())),
                subtitle: Text(l10n.chatReachable),
              ),
            for (final member in _chat.members)
              if (_chat.activeId.value == widget.conversationId)
                ListTile(
                  leading: Icon(
                    member.self &&
                            Theme.of(context).platform != TargetPlatform.android
                        ? Icons.computer
                        : Icons.phone_android,
                  ),
                  title: Text(member.name),
                  subtitle: Text(_subtitle(context, member)),
                  onTap: () => _detail(context, member),
                  trailing: owned && !member.self && member.role != kChatOwner
                      ? IconButton(
                          tooltip: l10n.chatRemove,
                          onPressed: () => _chat.removeMember(
                            widget.conversationId,
                            member.serial,
                          ),
                          icon: const Icon(Icons.person_remove_outlined),
                        )
                      : null,
                ),
          ],
        ),
      );
    });
  }

  List<Widget> _directInfo(
    BuildContext context,
    ChatConversation room,
    String title,
  ) {
    final l10n = context.l10n;
    final self = _chat.isSelfChat(room);
    final serial = room.peerSerial ?? '';
    DeviceProfile? profile;
    if (!self && serial.isNotEmpty && serial != 'self') {
      for (final device in _chat.knownDevices()) {
        if (device.serial == serial) {
          profile = device;
          break;
        }
      }
    }
    final presence = _chat.presenceOf(room);
    final status = self
        ? l10n.chatSelfDirect
        : presence == ChatPresence.ready
        ? l10n.chatPeerOnline
        : l10n.chatPeerOffline;
    final address = profile?.connectionAddress ?? '';
    return <Widget>[
      ListTile(
        leading: CircleAvatar(
          child: Icon(self ? Icons.phone_android : Icons.person),
        ),
        title: Text(title),
        subtitle: Text(self ? l10n.chatSelf : l10n.chatKindDirect),
      ),
      if (!self && serial.isNotEmpty && serial != 'self')
        ListTile(
          leading: const Icon(Icons.tag),
          title: Text(l10n.chatSerial),
          subtitle: Text(serial),
        ),
      if (address.isNotEmpty && address != serial)
        ListTile(
          leading: const Icon(Icons.lan_outlined),
          title: Text(address),
        ),
      ListTile(
        leading: const Icon(Icons.info_outline),
        title: Text(status),
      ),
      const Divider(height: 1),
      ListTile(
        leading: const Icon(Icons.delete_sweep_outlined),
        title: Text(l10n.chatClearHistory),
        onTap: () => _clear(context),
      ),
      ListTile(
        iconColor: Theme.of(context).colorScheme.error,
        textColor: Theme.of(context).colorScheme.error,
        leading: const Icon(Icons.delete_outline),
        title: Text(l10n.chatDeleteConversation),
        onTap: () => _deleteDirect(context),
      ),
    ];
  }

  ChatConversation? _room() {
    for (final item in _chat.conversations) {
      if (item.id == widget.conversationId) return item;
    }
    return null;
  }

  String _subtitle(BuildContext context, ChatMember member) {
    final l10n = context.l10n;
    final role = member.self
        ? l10n.chatSelf
        : member.role == kChatOwner
        ? l10n.chatRoleOwner
        : l10n.chatRoleMember;
    final room = _room();
    if (member.self || (room != null && _chat.isSelfChat(room))) {
      return l10n.chatSelf;
    }
    final reach = member.online ? l10n.chatReachable : l10n.chatUnreachable;
    return '$role · $reach';
  }

  Future<void> _detail(BuildContext context, ChatMember member) async {
    final l10n = context.l10n;
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(member.name),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(_subtitle(context, member)),
              if (!member.self) ...<Widget>[
                const SizedBox(height: 8),
                Text('${l10n.chatSerial}: ${member.serial}'),
              ],
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(MaterialLocalizations.of(context).okButtonLabel),
            ),
          ],
        );
      },
    );
  }

  Future<void> _rename(BuildContext context, String current) async {
    final l10n = context.l10n;
    final name = await showChatNameDialog(
      context,
      title: l10n.chatRename,
      label: l10n.chatNameLabel,
      confirm: l10n.chatSave,
      initial: current,
    );
    if (name == null) return;
    await _chat.renameConversation(widget.conversationId, name);
  }

  Future<void> _disband(BuildContext context) async {
    final confirmed = await _confirm(context, context.l10n.chatDisbandConfirm);
    if (!confirmed || !context.mounted) return;
    await _chat.disbandChannel(widget.conversationId);
    if (!context.mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _clear(BuildContext context) async {
    final confirmed = await _confirm(
      context,
      context.l10n.chatClearHistoryConfirm,
    );
    if (!confirmed || !context.mounted) return;
    await _chat.clearHistory(widget.conversationId);
  }

  Future<void> _deleteDirect(BuildContext context) async {
    final confirmed = await _confirm(
      context,
      context.l10n.chatDeleteConversationConfirm,
    );
    if (!confirmed || !context.mounted) return;
    await _chat.removeConversation(widget.conversationId);
    if (!context.mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _leave(BuildContext context) async {
    final confirmed = await _confirm(context, context.l10n.chatLeaveConfirm);
    if (!confirmed || !context.mounted) return;
    await _chat.leaveChannel(widget.conversationId);
    if (!context.mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<bool> _confirm(BuildContext context, String message) async {
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
              child: Text(MaterialLocalizations.of(context).okButtonLabel),
            ),
          ],
        );
      },
    );
    return answer == true;
  }

  Future<void> _add(BuildContext context) async {
    final present = <String>{for (final member in _chat.members) member.serial};
    final devices = <DeviceProfile>[
      for (final device in _chat.knownDevices())
        if (!present.contains(device.serial)) device,
    ];
    final picked = await showChatDevicePicker(
      context,
      devices: devices,
      title: context.l10n.chatAddMember,
    );
    if (picked == null) return;
    await _chat.addMember(
      widget.conversationId,
      picked.serial,
      picked.displayName,
    );
  }
}

Future<String?> showChatNameDialog(
  BuildContext context, {
  required String title,
  required String label,
  required String confirm,
  String initial = '',
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _ChatNameDialog(
      title: title,
      label: label,
      confirm: confirm,
      initial: initial,
    ),
  );
}

class _ChatNameDialog extends StatefulWidget {
  const _ChatNameDialog({
    required this.title,
    required this.label,
    required this.confirm,
    required this.initial,
  });

  final String title;
  final String label;
  final String confirm;
  final String initial;

  @override
  State<_ChatNameDialog> createState() => _ChatNameDialogState();
}

class _ChatNameDialogState extends State<_ChatNameDialog> {
  late final TextEditingController _field = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _field.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _field,
        autofocus: true,
        decoration: InputDecoration(labelText: widget.label),
        onSubmitted: (_) => _submit(),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        TextButton(onPressed: _submit, child: Text(widget.confirm)),
      ],
    );
  }
}

Future<DeviceProfile?> showChatDevicePicker(
  BuildContext context, {
  required List<DeviceProfile> devices,
  required String title,
  String? empty,
}) {
  final l10n = context.l10n;
  return showDialog<DeviceProfile>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          height: devices.isEmpty ? null : 320,
          child: devices.isEmpty
              ? Text(empty ?? l10n.chatNoDevices)
              : ListView(
                  children: <Widget>[
                    for (final device in devices)
                      ListTile(
                        title: Text(device.displayName),
                        subtitle: Text(device.connectionAddress),
                        onTap: () => Navigator.of(context).pop(device),
                      ),
                  ],
                ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
        ],
      );
    },
  );
}
