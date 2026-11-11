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
      final title = chatConversationTitle(l10n, room, _chat.selfId.value);
      final owned = room?.ownedBy(_chat.selfId.value) ?? false;
      return Scaffold(
        appBar: AppBar(
          title: Text(l10n.chatInfo),
          actions: <Widget>[
            if (owned)
              IconButton(
                tooltip: l10n.chatRename,
                onPressed: () => _rename(context, title),
                icon: const Icon(Icons.edit_outlined),
              ),
            if (owned)
              IconButton(
                tooltip: l10n.chatAddMember,
                onPressed: () => _add(context),
                icon: const Icon(Icons.person_add_alt_1),
              ),
          ],
        ),
        body: ListView(
          children: <Widget>[
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
            for (final member in _chat.members)
              if (_chat.activeId.value == widget.conversationId)
                ListTile(
                  leading: Icon(
                    member.self ? Icons.computer : Icons.phone_android,
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
              ? Text(l10n.chatNoDevices)
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
