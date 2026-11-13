import 'dart:convert';

import 'chat_message.dart';

const String kChatPost = 'post';
const String kChatRevise = 'revise';

String encodePost(String text) {
  return jsonEncode(<String, String>{'text': text.trim()});
}

/// 正文是纯文字。旧帖里的标题、标记和图片占位会收成一段文字。
String decodePost(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      if (decoded.containsKey('text')) return '${decoded['text'] ?? ''}'.trim();
      final title = '${decoded['title'] ?? ''}'.trim();
      final markdown = _plain('${decoded['markdown'] ?? ''}');
      if (title.isEmpty) return markdown;
      if (markdown.isEmpty) return title;
      return '$title\n$markdown';
    }
  } catch (_) {}
  return _plain(body);
}

String latestPostText(ChatMessage post, Iterable<ChatMessage> messages) {
  final revises = <ChatMessage>[
    for (final message in messages)
      if (message.kind == kChatRevise && message.parentSeq == post.seq) message,
  ]..sort((a, b) => a.seq.compareTo(b.seq));
  return decodePost(revises.isEmpty ? post.body : revises.last.body);
}

String postSnippet(String text) {
  final trimmed = text.trim();
  if (trimmed.length <= 80) return trimmed;
  return '${trimmed.substring(0, 80)}…';
}

String _plain(String input) {
  final kept = <String>[];
  var fenced = false;
  for (final raw in input.replaceAll('\r\n', '\n').split('\n')) {
    final trimmed = raw.trim();
    if (trimmed.startsWith('```')) {
      fenced = !fenced;
      continue;
    }
    if (fenced || trimmed.isEmpty) continue;
    if (RegExp(r'^\[\[(?:image|new):\d+\]\]$').hasMatch(trimmed)) continue;
    var text = trimmed.replaceFirst(RegExp(r'^#+\s*'), '');
    text = text.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '');
    text = text.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\([^)]*\)'),
      (match) => match.group(1)!,
    );
    text = text.replaceAll(RegExp(r'[*_`]'), '');
    if (text.trim().isNotEmpty) kept.add(text.trim());
  }
  return kept.join('\n');
}
