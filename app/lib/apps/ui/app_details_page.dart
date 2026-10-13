import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../app_feedback.dart';
import '../../connection/connection_manager.dart';
import '../../files/local_file_picker.dart';
import '../../l10n/fire_adb_localizations_ext.dart';
import '../../log/app_log.dart';
import '../apps_controller.dart';
import '../data/bean/installed_app.dart';
import '../data/source/app_inventory.dart';
import '../data/source/fire_app_service.dart';
import '../loader/app_display_loader.dart';
import 'app_data_page.dart';
import 'app_task_view.dart';

class AppDetailsPage extends StatefulWidget {
  const AppDetailsPage({super.key, required this.serial, required this.app});

  final String serial;
  final InstalledApp app;

  @override
  State<AppDetailsPage> createState() => _AppDetailsPageState();
}

class _AppDetailsPageState extends State<AppDetailsPage> {
  late InstalledApp _app = widget.app;
  Uint8List? _icon;
  var _loading = true;
  var _exporting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final device = Get.find<ConnectionManager>().deviceOf(widget.serial);
    if (device == null) {
      if (!mounted) return;
      setState(() => _loading = false);
      return;
    }
    try {
      final shown = await loadFireAppShow(device, widget.app.packageName);
      if (!mounted) return;
      final png = shown.png;
      setState(() {
        _loading = false;
        _icon = png == null || png.isEmpty ? null : png;
        _app = applyAppDisplay(
          widget.app,
          AppDisplay(
            label: shown.label,
            versionName: shown.versionName,
            versionCode: shown.versionCode,
            png: png,
            sizeBytes: widget.app.sizeBytes,
            isSystem: shown.isSystem,
            isDisabledUser: shown.isDisabledUser,
            isSuspended: shown.isSuspended,
            isDebuggable: shown.isDebuggable,
            dataDir: _directory(shown.dataDir),
            cacheDir: _directory(shown.cacheDir),
            externalDir: _directory(shown.externalDir),
          ),
        );
      });
    } catch (error, stackTrace) {
      log.severe('读取应用详情失败：${widget.app.packageName}', error, stackTrace);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  String? _directory(String path) {
    final value = path.trim();
    return value.isEmpty ? null : value;
  }

  void _browse(String title, String? path, {required bool runAs}) {
    final directory = path;
    if (directory == null) return;
    if (runAs && !_app.isDebuggable) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => AppDataPage(
          serial: widget.serial,
          packageName: _app.packageName,
          root: directory,
          title: title,
        ),
      ),
    );
  }

  Future<void> _exportApk() async {
    if (_exporting) return;
    final l10n = context.l10n;
    final AppsController controller;
    try {
      controller = Get.find<AppsController>(tag: widget.serial);
    } catch (error, stackTrace) {
      log.severe('导出 APK 失败：${_app.packageName}', error, stackTrace);
      if (!mounted) return;
      _message(l10n.appsActionFailed, '$error', error: true);
      return;
    }
    final String? directory;
    try {
      directory = await pickExportDirectory(
        context,
        l10n.appsExportPrompt(_app.displayName),
      );
    } catch (error, stackTrace) {
      log.severe('选择导出目录失败', error, stackTrace);
      if (!mounted) return;
      _message(l10n.appsActionFailed, '$error', error: true);
      return;
    }
    if (directory == null || !mounted) return;
    setState(() => _exporting = true);
    final future = controller.export(
      l10n,
      <InstalledApp>[_app],
      directory,
      singlePath: true,
    );
    if (controller.task.value?.byBytes == true) {
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (context) => ExportProgressDialog(controller: controller),
        ),
      );
    }
    final notice = await future;
    if (!mounted) return;
    setState(() => _exporting = false);
    if (notice == null) return;
    _message(notice.title, notice.message, error: notice.isError);
  }

  void _message(String title, String text, {bool error = false}) {
    showAppMessage(
      ScaffoldMessenger.of(context),
      Theme.of(context),
      title: title,
      message: text,
      isError: error,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final version = _app.versionLabel;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.appsDetailsTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: <Widget>[
          Row(
            children: <Widget>[
              CircleAvatar(
                radius: 28,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                backgroundImage: _icon == null ? null : MemoryImage(_icon!),
                child: _icon == null ? const Icon(Icons.android) : null,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(_app.displayName, style: theme.textTheme.titleLarge),
                    Text(_app.packageName),
                    if (_app.isDebuggable)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Chip(label: Text(l10n.appsDebugBadge)),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          const SizedBox(height: 12),
          if (version.isNotEmpty)
            ListTile(title: Text(l10n.appsVersion(version))),
          if (_app.sizeBytes != null)
            ListTile(
              title: Text(l10n.appsSize(formatByteSize(_app.sizeBytes!))),
            ),
          ListTile(
            title: Text(
              _app.primaryPath == null
                  ? l10n.appsPath(l10n.appsDirectoryUnknown)
                  : l10n.appsPath(_app.primaryPath!),
            ),
            trailing: TextButton(
              onPressed: _exporting ? null : _exportApk,
              child: Text(l10n.appsExportAction),
            ),
          ),
          const Divider(),
          _DirectoryTile(
            title: l10n.appsDataDirectory,
            path: _app.dataDir,
            unknown: l10n.appsDirectoryUnknown,
            browse: l10n.appsBrowseDirectory,
            canBrowse: _app.isDebuggable && _app.dataDir != null,
            onBrowse: () =>
                _browse(l10n.appsDataDirectory, _app.dataDir, runAs: true),
          ),
          _DirectoryTile(
            title: l10n.appsExternalDirectory,
            path: _app.externalDir,
            unknown: l10n.appsDirectoryUnknown,
            browse: l10n.appsBrowseDirectory,
            canBrowse: _app.externalDir != null,
            onBrowse: () => _browse(
              l10n.appsExternalDirectory,
              _app.externalDir,
              runAs: false,
            ),
          ),
          if (!_app.isDebuggable)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                l10n.appsDebugOnlyHint,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DirectoryTile extends StatelessWidget {
  const _DirectoryTile({
    required this.title,
    required this.path,
    required this.unknown,
    required this.browse,
    required this.canBrowse,
    required this.onBrowse,
  });

  final String title;
  final String? path;
  final String unknown;
  final String browse;
  final bool canBrowse;
  final VoidCallback onBrowse;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      subtitle: Text(path ?? unknown),
      trailing: canBrowse
          ? TextButton(onPressed: onBrowse, child: Text(browse))
          : null,
    );
  }
}
