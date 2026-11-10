import 'package:flutter/material.dart';

import '../../l10n/fireadb_localizations_ext.dart';

/// 发送到设备的多行文本输入。预填 [preset]（一般是本机剪贴板内容），
/// 返回输入文本；取消返回 null。
Future<String?> promptClipboardText(
  BuildContext context, {
  required String title,
  String preset = '',
}) async {
  final l10n = context.l10n;
  final field = TextEditingController(text: preset);
  final formKey = GlobalKey<FormState>();
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Form(
        key: formKey,
        child: TextFormField(
          controller: field,
          autofocus: true,
          maxLines: 6,
          minLines: 3,
          validator: (value) =>
              (value == null || value.trim().isEmpty)
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
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(MaterialLocalizations.of(dialogContext).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: () {
            if (formKey.currentState?.validate() ?? false) {
              Navigator.of(dialogContext).pop(field.text);
            }
          },
          child: Text(l10n.clipboardSend),
        ),
      ],
    ),
  );
  field.dispose();
  return result;
}
