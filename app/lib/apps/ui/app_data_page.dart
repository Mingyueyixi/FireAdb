import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../connection/connection_manager.dart';
import '../../connection/model/connected_device.dart';
import '../../files/data/source/remote_file_commands.dart';
import '../../files/local_file_picker.dart';
import '../../l10n/fire_adb_localizations_ext.dart';
import '../../l10n/generated/fire_adb_localizations.dart';
import '../../log/app_log.dart';
import '../data/source/run_as_files.dart';

/// 用 `run-as` 浏览和修改一个 debug 应用的数据目录。
class AppDataPage extends StatefulWidget {
  const AppDataPage({
    super.key,
    required this.serial,
    required this.packageName,
    required this.root,
    required this.title,
  });

  final String serial;
  final String packageName;
  final String root;
  final String title;

  @override
  State<AppDataPage> createState() => _AppDataPageState();
}

class _AppDataPageState extends State<AppDataPage> {
  late String _root = widget.root;
  late String _path = widget.root;
  List<RunAsEntry> _entries = const <RunAsEntry>[];
  var _loading = true;
  String? _error;

  ConnectedDevice? get _device =>
      Get.find<ConnectionManager>().deviceOf(widget.serial);

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final device = _device;
    setState(() {
      _loading = true;
      _error = null;
    });
    if (device == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = context.l10n.deviceOverviewNotConnected;
      });
      return;
    }
    try {
      final page = await listAppDirectory(
        device: device,
        packageName: widget.packageName,
        root: _root,
        directory: _path,
      );
      if (!mounted) return;
      setState(() {
        _root = page.root;
        _path = page.directory;
        _entries = page.entries;
        _loading = false;
      });
    } catch (error, stackTrace) {
      log.severe('读取应用目录失败：$_path', error, stackTrace);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<void> _open(RunAsEntry entry) async {
    if (!entry.canEnter) {
      await _showFile(entry);
      return;
    }
    if (!isWithinAppRoot(_root, entry.path)) return;
    setState(() => _path = entry.path);
    await _reload();
  }

  Future<void> _up() async {
    if (normalizeRemotePath(_path) == normalizeRemotePath(_root)) return;
    setState(() => _path = parentRemotePath(_path));
    await _reload();
  }

  Future<void> _delete(RunAsEntry entry) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.appsDeleteTitle),
        content: Text(l10n.appsDeleteConfirm(entry.name)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.appsDeleteAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final device = _device;
    if (device == null) return;
    try {
      await deleteAppPath(
        device: device,
        packageName: widget.packageName,
        root: _root,
        path: entry.path,
      );
    } catch (error, stackTrace) {
      log.severe('删除应用文件失败：${entry.path}', error, stackTrace);
      if (!mounted) return;
      _message(context.l10n.appsDataFailed('$error'), error: true);
      return;
    }
    await _reload();
  }

  Future<void> _showFile(RunAsEntry entry) async {
    final l10n = context.l10n;
    final device = _device;
    if (device == null) return;
    if (entry.size > remoteTextEditLimit) {
      _message(l10n.appsFileTooLarge(formatFileSize(remoteTextEditLimit)));
      return;
    }
    try {
      final bytes = await readAppFile(
        device: device,
        packageName: widget.packageName,
        root: _root,
        path: entry.path,
      );
      if (!mounted) return;
      if (looksLikeBinary(bytes)) {
        _message(l10n.appsFileNotText);
        return;
      }
      final text = utf8.decode(bytes);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(entry.name),
          content: SingleChildScrollView(child: SelectableText(text)),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.commonCancel),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                unawaited(_export(entry, bytes));
              },
              child: Text(l10n.appsExportFile),
            ),
          ],
        ),
      );
    } catch (error, stackTrace) {
      log.severe('读取应用文件失败：${entry.path}', error, stackTrace);
      if (!mounted) return;
      _message(l10n.appsDataFailed('$error'), error: true);
    }
  }

  Future<void> _export(RunAsEntry entry, Uint8List bytes) async {
    final l10n = context.l10n;
    final directory = await pickExportDirectory(context, l10n.appsExportFile);
    if (directory == null || !mounted) return;
    final file = File('$directory${Platform.pathSeparator}${entry.name}');
    await file.writeAsBytes(bytes, flush: true);
    if (!mounted) return;
    _message(l10n.appsExportFileDone(file.path));
  }

  void _message(String text, {bool error = false}) {
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          text,
          style: TextStyle(color: error ? theme.colorScheme.onError : null),
        ),
        backgroundColor: error ? theme.colorScheme.error : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final atRoot = normalizeRemotePath(_path) == normalizeRemotePath(_root);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: <Widget>[
          if (!atRoot)
            IconButton(
              tooltip: l10n.filesUp,
              onPressed: _up,
              icon: const Icon(Icons.arrow_upward),
            ),
          IconButton(
            tooltip: l10n.appsRefresh,
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(_path),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _body(l10n)),
        ],
      ),
    );
  }

  Widget _body(FireAdbLocalizations l10n) {
    final theme = Theme.of(context);
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10n.appsDataFailed(_error!),
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
      );
    }
    if (!_loading && _entries.isEmpty) {
      return Center(child: Text(l10n.appsDataEmpty));
    }
    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final entry = _entries[index];
        return ListTile(
          leading: Icon(
            entry.canEnter ? Icons.folder : Icons.insert_drive_file,
          ),
          title: Text(entry.name),
          subtitle: entry.directory ? null : Text(formatFileSize(entry.size)),
          trailing: IconButton(
            tooltip: l10n.appsDeleteAction,
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(entry),
          ),
          onTap: () => _open(entry),
        );
      },
    );
  }
}
