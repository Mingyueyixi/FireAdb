import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../app_feedback.dart';
import '../../connection/connection_manager.dart';
import '../../l10n/fire_adb_localizations_ext.dart';
import '../../l10n/generated/fire_adb_localizations.dart';
import '../../log/app_log.dart';
import '../data/bean/installed_app.dart';
import '../data/repo/device_app_repository.dart';
import '../data/source/app_permissions.dart';

class AppPermissionsPage extends StatefulWidget {
  const AppPermissionsPage({
    super.key,
    required this.serial,
    required this.app,
  });

  final String serial;
  final InstalledApp app;

  @override
  State<AppPermissionsPage> createState() => _AppPermissionsPageState();
}

class _AppPermissionsPageState extends State<AppPermissionsPage> {
  List<AppPermissionEntry> _entries = const <AppPermissionEntry>[];
  final Set<String> _pending = <String>{};
  var _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  DeviceAppRepository? _repository() {
    if (!Get.isRegistered<ConnectionManager>()) return null;
    final manager = Get.find<ConnectionManager>();
    final device = manager.deviceOf(widget.serial);
    if (device == null) return null;
    final profile = manager.profileOf(widget.serial);
    return DeviceAppRepository(
      device,
      host: profile?.host,
      adbSerial: profile?.adbSerial,
    );
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final repo = _repository();
    if (repo == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = context.l10n.deviceOverviewNotConnected;
      });
      return;
    }
    try {
      final entries = await repo.listAppPermissions(widget.app.packageName);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (error, stackTrace) {
      log.severe('读取应用权限失败：${widget.app.packageName}', error, stackTrace);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is StateError && error.message.isNotEmpty
            ? error.message
            : '$error';
      });
    }
  }

  Future<void> _set(AppPermissionEntry entry, bool granted) async {
    if (_pending.contains(entry.name)) return;
    final repo = _repository();
    if (repo == null || !mounted) return;
    setState(() => _pending.add(entry.name));
    try {
      await repo.setAppPermission(
        widget.app.packageName,
        entry.name,
        granted: granted,
      );
      if (!mounted) return;
      setState(() {
        _entries = <AppPermissionEntry>[
          for (final item in _entries)
            if (item.name == entry.name)
              item.copyWith(granted: granted)
            else
              item,
        ];
      });
    } catch (error, stackTrace) {
      log.severe('修改应用权限失败：${entry.name}', error, stackTrace);
      if (!mounted) return;
      final raw = error is StateError && error.message.isNotEmpty
          ? error.message
          : '$error';
      final detail = shellBlockedRuntimeGrant(raw)
          ? '$raw\n${context.l10n.appsPermissionShellBlocked}'
          : raw;
      showAppMessage(
        ScaffoldMessenger.of(context),
        Theme.of(context),
        title: context.l10n.appsPermissionAction,
        message: detail,
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _pending.remove(entry.name));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    return Scaffold(
      appBar: AppBar(title: Text(l10n.appsPermissionTitle)),
      body: _body(l10n, theme, chinese),
    );
  }

  Widget _body(FireAdbLocalizations l10n, ThemeData theme, bool chinese) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10n.appsPermissionLoadFailed(_error!),
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
      );
    }
    if (_entries.isEmpty) return Center(child: Text(l10n.appsPermissionEmpty));
    final changeable = _entries.where((entry) => entry.changeable).toList();
    final fixed = _entries.where((entry) => !entry.changeable).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
      children: <Widget>[
        if (changeable.isNotEmpty) ...<Widget>[
          _SectionTitle(text: l10n.appsPermissionRuntime),
          for (final entry in changeable)
            _PermissionTile(
              entry: entry,
              title: permissionTitle(entry.name, chinese: chinese),
              pending: _pending.contains(entry.name),
              onChanged: (granted) => unawaited(_set(entry, granted)),
            ),
        ],
        if (fixed.isNotEmpty) ...<Widget>[
          _SectionTitle(text: l10n.appsPermissionInstall),
          for (final entry in fixed)
            ListTile(
              title: Text(
                permissionTitle(entry.name, chinese: chinese),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
              trailing: Text(
                entry.granted
                    ? l10n.appsPermissionGranted
                    : l10n.appsPermissionDenied,
                style: theme.textTheme.bodySmall,
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            ),
        ],
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

class _PermissionTile extends StatelessWidget {
  const _PermissionTile({
    required this.entry,
    required this.title,
    required this.pending,
    required this.onChanged,
  });

  final AppPermissionEntry entry;
  final String title;
  final bool pending;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SwitchListTile(
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        entry.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      secondary: pending
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      value: entry.granted,
      onChanged: pending ? null : onChanged,
    );
  }
}
