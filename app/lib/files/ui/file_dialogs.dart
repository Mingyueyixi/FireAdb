import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/fire_adb_localizations_ext.dart';

Future<bool> confirmDeleteFiles(
  BuildContext context, {
  required String? name,
  required int count,
}) async {
  final l10n = context.l10n;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        title: Text(l10n.filesDelete),
        content: Text(
          name == null
              ? l10n.filesBatchDeleteConfirm(count)
              : l10n.filesDeleteConfirm(name),
          style: TextStyle(color: scheme.error),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.filesDelete),
          ),
        ],
      );
    },
  );
  return confirmed == true;
}

Future<String?> askRemoteName(
  BuildContext context, {
  required String title,
  required String action,
  String initial = '',
}) async {
  final name = await showDialog<String>(
    context: context,
    builder: (context) => _TextPromptDialog(
      title: title,
      action: action,
      label: context.l10n.filesName,
      initialText: initial,
    ),
  );
  if (name == null || name.isEmpty) return null;
  return name;
}

Future<({String name, bool directory})?> askCreateEntry(BuildContext context) {
  return showDialog<({String name, bool directory})>(
    context: context,
    builder: (context) => const _CreateEntryDialog(),
  );
}

Future<String?> askPermission(BuildContext context, String current) async {
  final l10n = context.l10n;
  final initial = RegExp(r'[0-7]{3,4}').stringMatch(current) ?? '';
  final mode = await showDialog<String>(
    context: context,
    builder: (context) => _TextPromptDialog(
      title: l10n.filesPermission,
      action: l10n.commonSave,
      label: l10n.filesPermissionHint,
      initialText: initial,
    ),
  );
  if (mode == null || mode.isEmpty) return null;
  return mode;
}

Future<String?> askFileExportDirectory(
  BuildContext context,
  String prompt,
) async {
  final l10n = context.l10n;
  final directory = await showDialog<String>(
    context: context,
    builder: (context) => _TextPromptDialog(
      title: l10n.filesExport,
      action: l10n.filesExport,
      label: l10n.appsExportDirectory,
      initialText: _defaultExportDirectory(),
      message: prompt,
      autofocus: false,
    ),
  );
  if (directory == null || directory.isEmpty) return null;
  return directory;
}

Future<String?> askSearchKeyword(BuildContext context) async {
  final l10n = context.l10n;
  final keyword = await showDialog<String>(
    context: context,
    builder: (context) => _TextPromptDialog(
      title: l10n.filesSearch,
      action: l10n.filesSearch,
      label: l10n.filesSearchHint,
    ),
  );
  if (keyword == null || keyword.isEmpty) return null;
  return keyword;
}

Future<String?> editRemoteText(
  BuildContext context, {
  required String name,
  required String text,
}) async {
  final saved = await showDialog<String>(
    context: context,
    builder: (context) => _TextPromptDialog(
      title: context.l10n.filesEditTitle(name),
      action: context.l10n.commonSave,
      initialText: text,
      minLines: 8,
      maxLines: 16,
      trim: false,
      width: 520,
    ),
  );
  return saved;
}

Future<bool> confirmOverwrite(BuildContext context, String names) async {
  final l10n = context.l10n;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.filesUpload),
      content: Text(l10n.filesOverwrite(names)),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.filesUpload),
        ),
      ],
    ),
  );
  return confirmed == true;
}

class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.action,
    this.label,
    this.message,
    this.initialText = '',
    this.autofocus = true,
    this.minLines = 1,
    this.maxLines = 1,
    this.trim = true,
    this.width,
  });

  final String title;
  final String action;
  final String? label;
  final String? message;
  final String initialText;
  final bool autofocus;
  final int minLines;
  final int maxLines;
  final bool trim;
  final double? width;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = widget.trim ? _controller.text.trim() : _controller.text;
    Navigator.pop(context, text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final field = TextField(
      controller: _controller,
      autofocus: widget.autofocus,
      minLines: widget.minLines,
      maxLines: widget.maxLines,
      decoration: InputDecoration(
        labelText: widget.label,
        border: const OutlineInputBorder(),
      ),
      onSubmitted: widget.maxLines == 1 ? (_) => _submit() : null,
    );
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: widget.width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (widget.message != null) ...<Widget>[
              Text(widget.message!),
              const SizedBox(height: 12),
            ],
            field,
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.action)),
      ],
    );
  }
}

class _CreateEntryDialog extends StatefulWidget {
  const _CreateEntryDialog();

  @override
  State<_CreateEntryDialog> createState() => _CreateEntryDialogState();
}

class _CreateEntryDialogState extends State<_CreateEntryDialog> {
  late final TextEditingController _controller;
  var _directory = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.filesCreate),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: l10n.filesName,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) {
              final name = _controller.text.trim();
              if (name.isEmpty) return;
              Navigator.pop(context, (name: name, directory: _directory));
            },
          ),
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            segments: <ButtonSegment<bool>>[
              ButtonSegment<bool>(value: false, label: Text(l10n.filesFile)),
              ButtonSegment<bool>(value: true, label: Text(l10n.filesFolder)),
            ],
            selected: <bool>{_directory},
            onSelectionChanged: (value) =>
                setState(() => _directory = value.first),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () {
            final name = _controller.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(context, (name: name, directory: _directory));
          },
          child: Text(l10n.filesCreate),
        ),
      ],
    );
  }
}

String _defaultExportDirectory() {
  final home =
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '';
  if (home.isEmpty) return Directory.systemTemp.path;
  return '$home${Platform.pathSeparator}Downloads';
}
