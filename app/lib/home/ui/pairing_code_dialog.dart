import 'package:flutter/material.dart';

import '../../l10n/fire_adb_localizations_ext.dart';

Future<String?> showPairingCodeDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (context) => const PairingCodeDialog(),
  );
}

class PairingCodeDialog extends StatefulWidget {
  const PairingCodeDialog({super.key});

  @override
  State<PairingCodeDialog> createState() => _PairingCodeDialogState();
}

class _PairingCodeDialogState extends State<PairingCodeDialog> {
  final TextEditingController _codeController = TextEditingController();

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _codeController.text);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      scrollable: true,
      title: Text(l10n.homePairingTitle),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(l10n.homePairingCodeHelp),
            const SizedBox(height: 12),
            TextField(
              controller: _codeController,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: l10n.homePair,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        TextButton(onPressed: _submit, child: Text(l10n.homePair)),
      ],
    );
  }
}
