import 'package:flutter/material.dart';

import '../../l10n/fireadb_localizations_ext.dart';

/// 发送到设备的多行文本输入。预填 [preset]（一般是本机剪贴板内容），
/// 返回输入文本；取消返回 null。
Future<String?> promptClipboardText(
  BuildContext context, {
  required String title,
  String preset = '',
}) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => _ClipboardTextDialog(
      title: title,
      preset: preset,
    ),
  );
}

/// 控制器跟着对话框的 State 走。`showDialog` 在弹出动画结束前就返回，
/// 那时输入框还在树上，不能提前 dispose。
class _ClipboardTextDialog extends StatefulWidget {
  const _ClipboardTextDialog({required this.title, required this.preset});

  final String title;
  final String preset;

  @override
  State<_ClipboardTextDialog> createState() => _ClipboardTextDialogState();
}

class _ClipboardTextDialogState extends State<_ClipboardTextDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _field;

  @override
  void initState() {
    super.initState();
    _field = TextEditingController(text: widget.preset);
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      Navigator.of(context).pop(_field.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(widget.title),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _field,
          autofocus: true,
          maxLines: 6,
          minLines: 3,
          validator: (value) => (value == null || value.trim().isEmpty)
              ? l10n.clipboardSendTextEmpty
              : null,
          decoration: InputDecoration(
            hintText: l10n.clipboardSendTextHint,
            border: const OutlineInputBorder(),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(l10n.clipboardSend),
        ),
      ],
    );
  }
}
