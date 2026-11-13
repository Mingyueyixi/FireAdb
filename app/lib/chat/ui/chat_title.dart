import '../../l10n/generated/fireadb_localizations.dart';
import '../chat_conversation.dart';

String chatConversationTitle(
  FireAdbLocalizations l10n,
  ChatConversation? room,
  String selfId,
) {
  if (room == null) return l10n.chatTitle;
  if (room.isMyChannel(selfId) && room.title.trim().isEmpty) {
    return l10n.chatMyChannel;
  }
  if (room.title.trim().isNotEmpty) return room.title;
  return chatKindLabel(l10n, room, selfId);
}

String chatKindLabel(
  FireAdbLocalizations l10n,
  ChatConversation room,
  String selfId,
) {
  if (room.isMyChannel(selfId)) return l10n.chatMyChannel;
  switch (room.kind) {
    case kChatDirect:
      return l10n.chatKindDirect;
    default:
      return l10n.chatKindChannel;
  }
}

String chatPreview(FireAdbLocalizations l10n, ChatConversation room) {
  final body = room.lastBody;
  if (body == null || body.isEmpty) return l10n.chatPreviewEmpty;
  final sender = room.lastSender;
  if (sender == null || sender.isEmpty) return body;
  return '$sender: $body';
}
