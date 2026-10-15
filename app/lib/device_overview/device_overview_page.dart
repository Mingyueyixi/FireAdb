import 'dart:async';

import 'package:fire_adb/connection/connection_manager.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app_feedback.dart';
import '../l10n/fire_adb_localizations_ext.dart';
import '../log/app_log.dart';
import '../shell/device_root.dart';
import '../shell/device_root_store.dart';

/// 设备基本信息面板（连接后按需读取 getprop）。
class DeviceOverviewPage extends StatefulWidget {
  const DeviceOverviewPage({
    super.key,
    required this.serial,
  });

  final String serial;

  @override
  State<DeviceOverviewPage> createState() => _DeviceOverviewPageState();
}

class _DeviceOverviewPageState extends State<DeviceOverviewPage> {
  ConnectionManager get _manager => Get.find<ConnectionManager>();

  static String _fieldLabel(BuildContext context, String key) {
    final l10n = context.l10n;
    return switch (key) {
      'ro.product.model' => l10n.deviceOverviewModel,
      'ro.product.manufacturer' => l10n.deviceOverviewManufacturer,
      'ro.product.brand' => l10n.deviceOverviewBrand,
      'ro.build.version.release' => l10n.deviceOverviewAndroidVersion,
      'ro.build.version.sdk' => l10n.deviceOverviewApiLevel,
      'ro.product.cpu.abi' => 'ABI',
      _ => key,
    };
  }

  Map<String, String> _props = const <String, String>{};
  Object? _error;
  bool _loaded = false;
  var _rootBusy = false;
  String? _suError;
  late final TextEditingController _suController;
  late final FocusNode _suFocus;

  DeviceRootStore get _root => Get.find<DeviceRootStore>();

  @override
  void initState() {
    super.initState();
    _suController = TextEditingController(
      text: _root.of(widget.serial).suCommand,
    );
    _suFocus = FocusNode()..addListener(_onSuFocus);
    _load();
  }

  @override
  void dispose() {
    _suFocus
      ..removeListener(_onSuFocus)
      ..dispose();
    _suController.dispose();
    super.dispose();
  }

  void _onSuFocus() {
    if (_suFocus.hasFocus || _rootBusy) return;
    _applySuCommand(_suController.text);
  }

  Future<void> _load() async {
    final device = _manager.deviceOf(widget.serial);
    if (device == null) {
      setState(() => _error = const _DeviceNotConnectedException());
      return;
    }
    try {
      final props = await device.getProperties().timeout(
        const Duration(seconds: 10),
      );
      if (!mounted) return;
      setState(() {
        _props = props;
        _loaded = true;
      });
    } catch (error, stackTrace) {
      log.severe('读取设备信息失败：${widget.serial}', error, stackTrace);
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final profile = _manager.profileOf(widget.serial);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Card(
          child: ListTile(
            leading: Icon(Icons.phonelink, color: theme.colorScheme.primary),
            title: Text(widget.serial, style: theme.textTheme.titleMedium),
            subtitle: Text(
              profile != null && profile.host != null
                  ? l10n.deviceOverviewNetworkConnection(profile.host!, profile.port!)
                  : l10n.deviceOverviewConnected,
            ),
          ),
        ),
        const SizedBox(height: 16),
        _rootCard(context),
        const SizedBox(height: 16),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              l10n.deviceOverviewInfoReadFailed(
                _error is _DeviceNotConnectedException
                    ? l10n.deviceOverviewNotConnected
                    : '$_error',
              ),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          )
        else if (!_loaded)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          Card(
            child: Column(
              children: <Widget>[
                ListTile(
                  title: Text(l10n.deviceOverviewBasicInformation, style: theme.textTheme.titleMedium),
                ),
                const Divider(height: 1),
                for (final key in const <String>[
                  'ro.product.model',
                  'ro.product.manufacturer',
                  'ro.product.brand',
                  'ro.build.version.release',
                  'ro.build.version.sdk',
                  'ro.product.cpu.abi',
                ])
                  _InfoRow(
                    label: _fieldLabel(context, key),
                    value: _props[key],
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _rootCard(BuildContext context) {
    final l10n = context.l10n;
    final connected = _manager.deviceOf(widget.serial) != null;
    return Card(
      child: Obx(() {
        final options = _root.of(widget.serial);
        final enabled = connected && !_rootBusy;
        return Column(
          children: <Widget>[
            SwitchListTile(
              title: Text(l10n.deviceAdbRoot),
              subtitle: Text(l10n.deviceAdbRootHelp),
              value: options.adbRoot,
              onChanged: enabled ? _setAdbRoot : null,
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: TextField(
                key: const ValueKey<String>('device-su-command'),
                controller: _suController,
                focusNode: _suFocus,
                enabled: enabled,
                decoration: InputDecoration(
                  labelText: l10n.deviceSuCommand,
                  helperText: l10n.deviceSuCommandHelp,
                  errorText: _suError,
                ),
                onSubmitted: _applySuCommand,
              ),
            ),
          ],
        );
      }),
    );
  }

  void _showSuFailure(Object error) {
    final l10n = context.l10n;
    final detail = switch (error) {
      StateError(:final message) when message.isNotEmpty => message,
      String() => error,
      _ => l10n.deviceSuFailed,
    };
    setState(() => _suError = detail);
    showAppMessage(
      ScaffoldMessenger.of(context),
      Theme.of(context),
      title: l10n.deviceSuCommand,
      message: detail,
      isError: true,
    );
  }

  Future<void> _setAdbRoot(bool value) async {
    setState(() => _rootBusy = true);
    try {
      if (!value) {
        final detail = await deactivateAdbRoot(widget.serial);
        if (!mounted || detail.isEmpty) return;
        showAppMessage(
          ScaffoldMessenger.of(context),
          Theme.of(context),
          title: context.l10n.deviceAdbRoot,
          message: detail,
          isError: true,
        );
        return;
      }
      final result = await activateAdbRoot(widget.serial);
      if (!mounted) return;
      final l10n = context.l10n;
      final message = switch (result.outcome) {
        AdbRootOutcome.enabled => null,
        AdbRootOutcome.keptNormal => result.detail.isEmpty
            ? l10n.deviceAdbRootKeptNormal
            : result.detail,
        AdbRootOutcome.disconnected => result.detail.isEmpty
            ? l10n.deviceAdbRootDisconnected
            : result.detail,
      };
      if (message == null) return;
      showAppMessage(
        ScaffoldMessenger.of(context),
        Theme.of(context),
        title: l10n.deviceAdbRoot,
        message: message,
        isError: true,
      );
    } catch (error, stackTrace) {
      log.severe('切换 adb root 失败：${widget.serial}', error, stackTrace);
      if (!mounted) return;
      showAppMessage(
        ScaffoldMessenger.of(context),
        Theme.of(context),
        title: context.l10n.deviceAdbRoot,
        message: '$error',
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _rootBusy = false);
    }
  }

  Future<void> _applySuCommand(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.contains('\n') || trimmed.length > 128) {
      _showSuFailure(context.l10n.deviceSuCommandInvalid);
      return;
    }
    if (trimmed == _root.of(widget.serial).suCommand) {
      setState(() => _suError = null);
      return;
    }
    setState(() => _rootBusy = true);
    try {
      await updateDeviceSuCommand(widget.serial, trimmed);
      if (mounted) setState(() => _suError = null);
    } catch (error, stackTrace) {
      log.severe('保存 su 命令失败：${widget.serial}', error, stackTrace);
      if (!mounted) return;
      _showSuFailure(error);
    } finally {
      if (mounted) setState(() => _rootBusy = false);
    }
  }
}

class _DeviceNotConnectedException implements Exception {
  const _DeviceNotConnectedException();
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      title: Text(label),
      trailing: Text(
        value ?? '-',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }
}