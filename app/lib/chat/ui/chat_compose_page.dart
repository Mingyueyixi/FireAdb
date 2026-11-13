import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../app_feedback.dart';
import '../../l10n/fireadb_localizations_ext.dart';
import '../chat_controller.dart';
import '../chat_message.dart';
import 'chat_media.dart';
import 'chat_transcript.dart';

class _DraftImage {
  _DraftImage.fresh(this.path);
  _DraftImage.kept(ChatMessage message, {String? placed})
    : path = placed ?? message.filePath,
      message = message;

  final String? path;
  ChatMessage? message;
}

class _DraftFile {
  _DraftFile.fresh(this.path, this.name, this.mime);
  _DraftFile.kept(ChatMessage message, {String? placed})
    : path = placed ?? message.filePath,
      name = chatMediaName(message).isEmpty ? message.body : chatMediaName(message),
      mime = message.mime,
      message = message;

  final String? path;
  final String name;
  final String? mime;
  ChatMessage? message;
}

class ChatComposePage extends StatefulWidget {
  const ChatComposePage({
    super.key,
    required this.conversationId,
    this.editing,
    this.initialText = '',
    this.existingImages = const <ChatMessage>[],
    this.existingFiles = const <ChatMessage>[],
  });

  final String conversationId;
  final ChatMessage? editing;
  final String initialText;
  final List<ChatMessage> existingImages;
  final List<ChatMessage> existingFiles;

  @override
  State<ChatComposePage> createState() => _ChatComposePageState();
}

class _ChatComposePageState extends State<ChatComposePage> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initialText,
  );
  late final List<_DraftImage> _images = <_DraftImage>[
    for (final message in widget.existingImages)
      _DraftImage.kept(message, placed: _chat.placed(message)),
  ];
  late final List<_DraftFile> _files = <_DraftFile>[
    for (final message in widget.existingFiles)
      _DraftFile.kept(message, placed: _chat.placed(message)),
  ];
  final _removed = <ChatMessage>[];

  ChatController get _chat => Get.find<ChatController>();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final editing = widget.editing != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? l10n.chatEditPost : l10n.chatNewPost),
        actions: <Widget>[
          TextButton(onPressed: _submit, child: Text(l10n.chatSave)),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: <Widget>[
                TextField(
                  controller: _text,
                  autofocus: true,
                  minLines: 4,
                  maxLines: 8,
                  decoration: InputDecoration(
                    hintText: l10n.chatPostBody,
                    border: InputBorder.none,
                  ),
                ),
                if (_images.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  ChatMediaGrid(
                    paths: <String?>[for (final image in _images) image.path],
                    onTap: (index) {
                      final path = _images[index].path;
                      if (path == null) return;
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => ChatImagePage(path: path),
                        ),
                      );
                    },
                    onRemove: (index) {
                      setState(() {
                        final image = _images.removeAt(index);
                        final message = image.message;
                        if (message != null) _removed.add(message);
                      });
                    },
                  ),
                ],
                if (_files.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  for (var index = 0; index < _files.length; index++)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.insert_drive_file_outlined),
                      title: Text(_files[index].name),
                      trailing: IconButton(
                        tooltip: l10n.chatRemoveImage,
                        onPressed: () {
                          setState(() {
                            final file = _files.removeAt(index);
                            final message = file.message;
                            if (message != null) _removed.add(message);
                          });
                        },
                        icon: const Icon(Icons.close),
                      ),
                    ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          SafeArea(
            top: false,
            child: Row(
              children: <Widget>[
                IconButton(
                  tooltip: l10n.chatInsertImage,
                  onPressed: _addImage,
                  icon: const Icon(Icons.image_outlined),
                ),
                IconButton(
                  tooltip: l10n.chatAddFile,
                  onPressed: _addFile,
                  icon: const Icon(Icons.attach_file),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addImage() async {
    final file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: 'image',
          extensions: <String>['png', 'jpg', 'jpeg', 'gif', 'webp'],
        ),
      ],
    );
    if (file == null) return;
    setState(() => _images.add(_DraftImage.fresh(file.path)));
  }

  Future<void> _addFile() async {
    final file = await openFile();
    if (file == null) return;
    setState(() {
      _files.add(_DraftFile.fresh(file.path, file.name, file.mimeType));
    });
  }

  Future<void> _submit() async {
    final text = _text.text.trim();
    final freshImages = <String>[
      for (final image in _images)
        if (image.message == null && image.path != null) image.path!,
    ];
    final freshFiles = <({String path, String name, String? mime})>[
      for (final file in _files)
        if (file.message == null && file.path != null)
          (path: file.path!, name: file.name, mime: file.mime),
    ];
    if (text.isEmpty && _images.isEmpty && _files.isEmpty) return;
    final editing = widget.editing;
    try {
      if (editing == null) {
        await _chat.publishPost(
          text: text,
          imagePaths: freshImages,
          files: freshFiles,
        );
      } else {
        await _chat.revisePost(
          post: editing,
          text: text,
          previous: widget.initialText.trim(),
          removed: _removed,
          imagePaths: freshImages,
          files: freshFiles,
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      showAppMessage(
        ScaffoldMessenger.of(context),
        Theme.of(context),
        title: context.l10n.chatNewPost,
        message: context.l10n.chatSendFailed('$error'),
        isError: true,
      );
    }
  }
}
