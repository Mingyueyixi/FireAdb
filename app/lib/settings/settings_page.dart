import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app_feedback.dart';
import '../app_locale_controller.dart';
import '../connection/connection_manager.dart';
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
  late final TextEditingController _logBufferController;
  late final TextEditingController _logRetentionController;
  var _applyingServer = false;
  String? _portError;
  String? _intervalError;
  String? _logBufferError;
  String? _logRetentionError;
  String? _logDirectory;
  var _clearingLogs = false;

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController(
      text: '${Get.find<ConnectionManager>().adbServerPort.value}',
    );
    _intervalController = TextEditingController(
      text: '${Get.find<AppSettingsStore>().autoRefreshIntervalSeconds.value}',
    );
    final settings = Get.find<AppSettingsStore>();
    _logBufferController = TextEditingController(
      text: '${settings.logBufferKb.value}',
    );
    _logRetentionController = TextEditingController(
      text: '${settings.logRetentionDays.value}',
    );
    unawaited(_loadLogDirectory());
  }

  @override
  void dispose() {
    _portController.dispose();
    _intervalController.dispose();
    _logBufferController.dispose();
    _logRetentionController.dispose();
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

  Future<void> _loadLogDirectory() async {
    final path = await resolveLogDirectory();
    if (!mounted) return;
    setState(() => _logDirectory = path);
  }

  Future<void> _openLogDirectory() async {
    final path = _logDirectory;
    if (path == null) return;
    try {
      final directory = await openSavedLogDirectory(context);
      if (!mounted || directory == null) return;
      setState(() => _logDirectory = directory);
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

  Future<void> _applyLogBuffer() async {
    await _applyRange(
      controller: _logBufferController,
      min: AppSettingsStore.minLogBufferKb,
      max: AppSettingsStore.maxLogBufferKb,
      invalid: context.l10n.settingsLogBufferInvalid,
      assignError: (message) => _logBufferError = message,
      save: Get.find<AppSettingsStore>().setLogBufferKb,
      failure: '保存日志缓冲区失败',
    );
  }

  Future<void> _applyLogRetention() async {
    await _applyRange(
      controller: _logRetentionController,
      min: AppSettingsStore.minLogRetentionDays,
      max: AppSettingsStore.maxLogRetentionDays,
      invalid: context.l10n.settingsLogRetentionInvalid,
      assignError: (message) => _logRetentionError = message,
      save: Get.find<AppSettingsStore>().setLogRetentionDays,
      failure: '保存日志天数失败',
    );
  }

  Future<void> _applyRange({
    required TextEditingController controller,
    required int min,
    required int max,
    required String invalid,
    required void Function(String?) assignError,
    required Future<void> Function(int value) save,
    required String failure,
  }) async {
    final value = int.tryParse(controller.text.trim());
    if (value == null || value < min || value > max) {
      setState(() => assignError(invalid));
      return;
    }
    setState(() => assignError(null));
    try {
      await save(value);
    } catch (error, stackTrace) {
      log.severe(failure, error, stackTrace);
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

  Future<void> _deleteSavedLogs() async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.settingsLogDeleteAllTitle),
        content: Text(l10n.settingsLogDeleteAllMessage),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.settingsLogDeleteAll),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _clearingLogs = true);
    try {
      await deleteSavedLogs();
    } catch (error, stackTrace) {
      log.severe('清理日志文件失败', error, stackTrace);
      if (!mounted) return;
      showAppMessage(
        ScaffoldMessenger.of(context),
        Theme.of(context),
        title: l10n.settingsLogDeleteAll,
        message: l10n.settingsLogDeleteAllFailed('$error'),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _clearingLogs = false);
    }
  }

  Future<void> _setRefreshInBackground(bool value) async {
    try {
      await Get.find<AppSettingsStore>().setRefreshInBackground(value);
    } catch (error, stackTrace) {
      log.severe('保存后台刷新设置失败', error, stackTrace);
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
        final refreshInBackground = settings.refreshInBackground.value;
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
                CheckboxListTile(
                  key: const ValueKey<String>('settings-refresh-in-background'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.settingsRefreshInBackground),
                  subtitle: Text(l10n.settingsRefreshInBackgroundHelp),
                  value: refreshInBackground,
                  onChanged: (value) {
                    if (value == null) return;
                    unawaited(_setRefreshInBackground(value));
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
                  l10n.navLogs,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.settingsLogBuffer,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.settingsLogBufferHelp,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                _numberRow(
                  fieldKey: const ValueKey<String>('settings-log-buffer'),
                  controller: _logBufferController,
                  errorText: _logBufferError,
                  onApply: _applyLogBuffer,
                ),
                const SizedBox(height: 12),
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
                    onPressed: _logDirectory == null
                        ? null
                        : () => unawaited(_openLogDirectory()),
                    icon: const Icon(Icons.folder_open),
                    label: Text(l10n.settingsOpenLogDirectory),
                  ),
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _clearingLogs
                        ? null
                        : () => unawaited(_deleteSavedLogs()),
                    icon: const Icon(Icons.delete_outline),
                    label: Text(l10n.settingsLogDeleteAll),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.settingsLogRetention,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.settingsLogRetentionHelp,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                _numberRow(
                  fieldKey: const ValueKey<String>('settings-log-retention'),
                  controller: _logRetentionController,
                  errorText: _logRetentionError,
                  onApply: _applyLogRetention,
                ),
              ],
            ),
          ),
        );
      }),
    );
  }

  Widget _numberRow({
    required Key fieldKey,
    required TextEditingController controller,
    required String? errorText,
    required Future<void> Function() onApply,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: TextField(
            key: fieldKey,
            controller: controller,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              isDense: true,
              errorText: errorText,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => unawaited(onApply()),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: () => unawaited(onApply()),
          child: Text(context.l10n.settingsApply),
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
