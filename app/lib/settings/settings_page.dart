import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app_feedback.dart';
import '../app_locale_controller.dart';
import '../capture/data/local_opener.dart';
import '../connection/connection_manager.dart';
import '../files/android_storage_access.dart';
import '../home/home_controller.dart';
import '../l10n/fire_adb_localizations_ext.dart';
import '../l10n/generated/fire_adb_localizations.dart';
import '../log/app_log.dart';
import 'app_settings_store.dart';

/// 独立设置页。语言、端口和自动刷新都在这一页修改。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _portController;
  late final TextEditingController _intervalController;
  var _applyingServer = false;
  String? _portError;
  String? _intervalError;
  String? _logDirectory;

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController(
      text: '${Get.find<ConnectionManager>().adbServerPort.value}',
    );
    _intervalController = TextEditingController(
      text: '${Get.find<AppSettingsStore>().autoRefreshIntervalSeconds.value}',
    );
    unawaited(_loadLogDirectory());
  }

  Future<void> _loadLogDirectory() async {
    final path = await resolveLogDirectory();
    if (!mounted) return;
    setState(() => _logDirectory = path);
  }

  Future<void> _openLogDirectory() async {
    final path = _logDirectory;
    if (path == null) return;
    try {
      if (Platform.isAndroid) {
        final granted = await ensureAllFilesAccess(context);
        if (!granted || !mounted) return;
      }
      final directory = await ensureLogDirectory(create: true);
      if (!mounted || directory == null) return;
      setState(() => _logDirectory = directory);
      await attachFileLogStore();
      await openSystemDirectory(directory);
    } catch (error, stackTrace) {
      log.severe('打开日志目录失败：$path', error, stackTrace);
      if (!mounted) return;
      showAppMessage(
        ScaffoldMessenger.of(context),
        Theme.of(context),
        title: context.l10n.settingsLogDirectory,
        message: context.l10n.settingsOpenLogDirectoryFailed('$error'),
        isError: true,
      );
    }
  }

  @override
  void dispose() {
    _portController.dispose();
    _intervalController.dispose();
    super.dispose();
  }

  Future<void> _selectLocale(Locale locale) async {
    try {
      await Get.find<AppLocaleController>().setLocale(locale);
    } catch (error, stackTrace) {
      log.severe('Could not save application language', error, stackTrace);
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
      log.severe('保存 adb server 端口失败', error, stackTrace);
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
      log.severe('保存 adb server 设置失败', error, stackTrace);
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

  Future<void> _applyInterval() async {
    final l10n = context.l10n;
    final seconds = int.tryParse(_intervalController.text.trim());
    if (seconds == null ||
        seconds < AppSettingsStore.minAutoRefreshSeconds ||
        seconds > AppSettingsStore.maxAutoRefreshSeconds) {
      setState(() => _intervalError = l10n.settingsAutoRefreshIntervalInvalid);
      return;
    }
    setState(() => _intervalError = null);
    try {
      await Get.find<AppSettingsStore>().setAutoRefreshIntervalSeconds(seconds);
    } catch (error, stackTrace) {
      log.severe('保存自动刷新间隔失败', error, stackTrace);
      if (!mounted) return;
      showAppMessage(
        ScaffoldMessenger.of(context),
        Theme.of(context),
        title: context.l10n.commonSettingsSaveFailed,
        message: '$error',
        isError: true,
      );
    }
  }

  Future<void> _setAutoRefresh({
    required bool mdns,
    required bool value,
  }) async {
    final store = Get.find<AppSettingsStore>();
    try {
      if (mdns) {
        await store.setAutoRefreshMdns(value);
      } else {
        await store.setAutoRefreshDevices(value);
      }
    } catch (error, stackTrace) {
      log.severe('保存自动刷新设置失败', error, stackTrace);
      if (!mounted) return;
      showAppMessage(
        ScaffoldMessenger.of(context),
        Theme.of(context),
        title: context.l10n.commonSettingsSaveFailed,
        message: '$error',
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final localeController = Get.find<AppLocaleController>();
    final manager = Get.find<ConnectionManager>();
    final settings = Get.find<AppSettingsStore>();
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: Obx(() {
        final locale = localeController.locale.value;
        final prefer = manager.preferSdkAdbServer.value;
        final adbPath = manager.sdkAdbPath.value;
        final adbError = manager.sdkAdbError.value;
        final autoRefreshMdns = settings.autoRefreshMdns.value;
        final autoRefreshDevices = settings.autoRefreshDevices.value;
        final intervalSeconds = settings.autoRefreshIntervalSeconds.value;
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.all(16),
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
                CheckboxListTile(
                  key: const ValueKey<String>('settings-auto-refresh-mdns'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.settingsAutoRefreshMdns),
                  subtitle: Text(l10n.settingsAutoRefreshHelp(intervalSeconds)),
                  value: autoRefreshMdns,
                  onChanged: (value) {
                    if (value == null) return;
                    unawaited(_setAutoRefresh(mdns: true, value: value));
                  },
                ),
                CheckboxListTile(
                  key: const ValueKey<String>('settings-auto-refresh-devices'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.settingsAutoRefreshDevices),
                  subtitle: Text(l10n.settingsAutoRefreshHelp(intervalSeconds)),
                  value: autoRefreshDevices,
                  onChanged: (value) {
                    if (value == null) return;
                    unawaited(_setAutoRefresh(mdns: false, value: value));
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.settingsAutoRefreshInterval,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        key: const ValueKey<String>(
                          'settings-auto-refresh-interval',
                        ),
                        controller: _intervalController,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          isDense: true,
                          errorText: _intervalError,
                          border: const OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => unawaited(_applyInterval()),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      key: const ValueKey<String>(
                        'settings-auto-refresh-interval-apply',
                      ),
                      onPressed: () => unawaited(_applyInterval()),
                      child: Text(l10n.settingsApply),
                    ),
                  ],
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
                const Divider(),
                Text(
                  l10n.settingsLogDirectory,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                SelectableText(
                  _logDirectory ?? l10n.settingsLogDirectoryUnavailable,
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey<String>('settings-open-log-directory'),
                    onPressed: _logDirectory == null
                        ? null
                        : () => unawaited(_openLogDirectory()),
                    icon: const Icon(Icons.folder_open),
                    label: Text(l10n.settingsOpenLogDirectory),
                  ),
                ),
              ],
            ),
          ),
        );
      }),
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
