import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app_feedback.dart';
import '../l10n/fire_adb_localizations_ext.dart';
import '../widgets/adaptive.dart';
import 'app_log.dart';

/// 实时显示本次启动的日志。清理和打开目录放在标题栏。
class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  final ScrollController _scroll = ScrollController();
  String? _directory;
  var _followEnd = true;

  @override
  void initState() {
    super.initState();
    sessionLog.addListener(_onLog);
    _scroll.addListener(_onScroll);
    unawaited(_loadDirectory());
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToEnd());
  }

  @override
  void dispose() {
    sessionLog.removeListener(_onLog);
    _scroll.dispose();
    super.dispose();
  }

  void _onLog() {
    if (!mounted) return;
    final follow = _followEnd;
    setState(() {});
    if (follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToEnd());
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients || !_scroll.position.hasContentDimensions) return;
    _followEnd =
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 48;
  }

  void _jumpToEnd() {
    if (!mounted || !_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  Future<void> _loadDirectory() async {
    final directory = await resolveLogDirectory();
    if (!mounted) return;
    setState(() => _directory = directory);
  }

  Future<void> _clear() async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.logClearTitle),
        content: Text(l10n.logClearMessage),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.logClear),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _followEnd = true;
    sessionLog.clear();
  }

  Future<void> _openDirectory() async {
    final path = _directory;
    if (path == null) return;
    try {
      final directory = await openSavedLogDirectory(context);
      if (!mounted || directory == null) return;
      setState(() => _directory = directory);
    } catch (error, stackTrace) {
      log.severe('打开日志目录失败：$path', error, stackTrace);
      if (!mounted) return;
      _showError(context.l10n.settingsOpenLogDirectoryFailed('$error'));
    }
  }

  void _showError(String message) {
    showAppMessage(
      ScaffoldMessenger.of(context),
      Theme.of(context),
      title: context.l10n.navLogs,
      message: message,
      isError: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final lines = sessionLog.lines;
    final style = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      height: 1.35,
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.navLogs),
        actions: <Widget>[
          IconButton(
            tooltip: l10n.logClear,
            onPressed: () => unawaited(_clear()),
            icon: const Icon(Icons.delete_outline),
          ),
          IconButton(
            tooltip: l10n.settingsOpenLogDirectory,
            onPressed: _directory == null
                ? null
                : () => unawaited(_openDirectory()),
            icon: const Icon(Icons.folder_open),
          ),
          if (!isWide(context))
            IconButton(
              tooltip: l10n.settingsTitle,
              onPressed: () => Get.toNamed<void>('/settings'),
              icon: const Icon(Icons.settings_outlined),
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (sessionLog.truncated)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Text(
                l10n.logTruncated,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          Expanded(
            child: lines.isEmpty
                ? Center(
                    child: Text(
                      l10n.logEmpty,
                      style: TextStyle(color: theme.colorScheme.outline),
                    ),
                  )
                : Scrollbar(
                    controller: _scroll,
                    child: SelectionArea(
                      child: ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(12),
                        itemCount: lines.length,
                        itemBuilder: (context, index) =>
                            Text(lines[index], style: style),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
