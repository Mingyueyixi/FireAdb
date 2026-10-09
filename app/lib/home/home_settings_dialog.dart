import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app_feedback.dart';
import '../app_locale_controller.dart';
import '../connection/connection_manager.dart';
import '../l10n/fire_adb_localizations_ext.dart';
import '../l10n/generated/fire_adb_localizations.dart';
import 'home_controller.dart';

Future<void> showHomeSettings(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => const _HomeSettingsDialog(),
  );
}

class _HomeSettingsDialog extends StatefulWidget {
  const _HomeSettingsDialog();

  @override
  State<_HomeSettingsDialog> createState() => _HomeSettingsDialogState();
}

class _HomeSettingsDialogState extends State<_HomeSettingsDialog> {
  late final TextEditingController _portController;
  var _applyingServer = false;
  String? _portError;

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController(
      text: '${Get.find<ConnectionManager>().adbServerPort.value}',
    );
  }

  @override
  void dispose() {
    _portController.dispose();
    super.dispose();
  }

  Future<void> _selectLocale(Locale locale) async {
    try {
      await Get.find<AppLocaleController>().setLocale(locale);
    } catch (error, stackTrace) {
      logAppError('Could not save application language', error, stackTrace);
      if (!mounted) return;
      final l10n = context.l10n;
      showAppMessage(
        ScaffoldMessenger.of(context),
        Theme.of(context),
        title: l10n.commonSettingsSaveFailed,
        message: l10n.settingsLanguageSaveFailed('$error'),
        isError: true,
      );
    }
  }

  Future<void> _pickLanguage() async {
    final localeController = Get.find<AppLocaleController>();
    final selected = await showDialog<Locale>(
      context: context,
      builder: (context) {
        final current = localeController.locale.value;
        return AlertDialog(
          title: Text(context.l10n.settingsChooseLanguage),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final language in AppLocaleController.languages)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(language.nativeName),
                    trailing: language.locale == current
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () => Navigator.pop(context, language.locale),
                  ),
              ],
            ),
          ),
        );
      },
    );
    if (selected == null) return;
    await _selectLocale(selected);
  }

  Future<void> _applyPort() async {
    final l10n = context.l10n;
    final port = int.tryParse(_portController.text.trim());
    if (port == null || port < 1 || port > 65535) {
      setState(() => _portError = l10n.settingsAdbServerPortInvalid);
      return;
    }
    setState(() {
      _portError = null;
      _applyingServer = true;
    });
    try {
      await Get.find<ConnectionManager>().setAdbServerPort(port);
      if (!mounted) return;
      Get.find<HomeController>().refreshListedDevices();
    } catch (error, stackTrace) {
      logAppError('保存 adb server 端口失败', error, stackTrace);
      if (!mounted) return;
      showAppMessage(
        ScaffoldMessenger.of(context),
        Theme.of(context),
        title: context.l10n.commonSettingsSaveFailed,
        message: '$error',
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _applyingServer = false);
    }
  }

  Future<void> _setPreferSdk(bool value) async {
    setState(() => _applyingServer = true);
    try {
      await Get.find<ConnectionManager>().setPreferSdkAdbServer(value);
      if (!mounted) return;
      Get.find<HomeController>().refreshListedDevices();
    } catch (error, stackTrace) {
      logAppError('保存 adb server 设置失败', error, stackTrace);
      if (!mounted) return;
      showAppMessage(
        ScaffoldMessenger.of(context),
        Theme.of(context),
        title: context.l10n.commonSettingsSaveFailed,
        message: '$error',
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _applyingServer = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final localeController = Get.find<AppLocaleController>();
    final manager = Get.find<ConnectionManager>();
    return AlertDialog(
      title: Text(l10n.settingsTitle),
      content: SizedBox(
        width: 420,
        child: Obx(() {
          final locale = localeController.locale.value;
          final prefer = manager.preferSdkAdbServer.value;
          final adbPath = manager.sdkAdbPath.value;
          final adbError = manager.sdkAdbError.value;
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.settingsLanguage),
                  subtitle: Text(localeController.nativeNameOf(locale)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _applyingServer
                      ? null
                      : () => unawaited(_pickLanguage()),
                ),
                const Divider(),
                Text(
                  l10n.settingsAdbServerPort,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.settingsAdbServerPortHelp,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: _portController,
                        enabled: !_applyingServer,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          isDense: true,
                          errorText: _portError,
                          border: const OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => unawaited(_applyPort()),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _applyingServer
                          ? null
                          : () => unawaited(_applyPort()),
                      child: Text(l10n.settingsApply),
                    ),
                  ],
                ),
                if (!Platform.isAndroid) ...<Widget>[
                  const Divider(),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.settingsPreferSdkAdb),
                    subtitle: Text(_sdkStatus(l10n, prefer, adbPath, adbError)),
                    value: prefer,
                    onChanged: _applyingServer ? null : _setPreferSdk,
                  ),
                ],
              ],
            ),
          );
        }),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonClose),
        ),
      ],
    );
  }

  String _sdkStatus(
    FireAdbLocalizations l10n,
    bool prefer,
    String? adbPath,
    String? adbError,
  ) {
    final help = l10n.settingsPreferSdkAdbHelp;
    if (adbError != null && prefer) {
      return '$help\n${l10n.settingsSdkAdbStartFailed(adbError)}';
    }
    if (adbPath != null) return '$help\n${l10n.settingsSdkAdbPath(adbPath)}';
    if (prefer) return '$help\n${l10n.settingsSdkAdbMissing}';
    return help;
  }
}
