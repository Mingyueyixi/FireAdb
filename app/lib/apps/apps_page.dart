import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fire_adb/connection/connection_manager.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../app_feedback.dart';
import '../l10n/fire_adb_localizations_ext.dart';
import '../widgets/locale_selector.dart';
import 'app_freeze.dart';
import 'app_freeze_settings.dart';
import 'app_inventory.dart';
import 'device_app_repository.dart';
import 'installed_app.dart';

class AppsPage extends StatefulWidget {
  const AppsPage({super.key, required this.serial});

  final String serial;

  @override
  State<AppsPage> createState() => _AppsPageState();
}

class _AppsPageState extends State<AppsPage> {
  ConnectionManager get _manager => Get.find<ConnectionManager>();

  final TextEditingController _search = TextEditingController();
  final Map<String, Uint8List> _icons = <String, Uint8List>{};
  List<InstalledApp> _apps = const <InstalledApp>[];
  AppListFilter _filter = AppListFilter.user;
  AppFreezeMethod _freezeMethod = AppFreezeMethod.disableUser;
  Object? _error;
  bool _loading = true;
  bool _busy = false;
  _AppTask? _task;
  DeviceAppRepository? _activeRepo;
  final ValueNotifier<int> _taskTick = ValueNotifier<int>(0);
  DateTime _progressUiAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _selecting = false;
  final Set<String> _selected = <String>{};
  int _iconGeneration = 0;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    unawaited(_loadFreezeMethod());
    unawaited(_reload());
  }

  @override
  void didUpdateWidget(covariant AppsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serial != widget.serial) {
      unawaited(_reload());
    }
  }

  @override
  void dispose() {
    _iconGeneration++;
    _search.dispose();
    _taskTick.dispose();
    super.dispose();
  }

  Future<void> _loadFreezeMethod() async {
    try {
      final method = await AppFreezeSettings.loadMethod();
      if (mounted) setState(() => _freezeMethod = method);
    } catch (error, stackTrace) {
      logAppError('读取应用冻结方式失败', error, stackTrace);
    }
  }

  Future<void> _saveFreezeMethod(AppFreezeMethod method) async {
    setState(() => _freezeMethod = method);
    try {
      await AppFreezeSettings.saveMethod(method);
    } catch (error, stackTrace) {
      logAppError('保存应用冻结方式失败', error, stackTrace);
    }
  }

  DeviceAppRepository? _repository() {
    final device = _manager.deviceOf(widget.serial);
    if (device == null) return null;
    return DeviceAppRepository(device);
  }

  Future<void> _reload() async {
    final repo = _repository();
    setState(() {
      _loading = true;
      _error = null;
      _apps = const <InstalledApp>[];
      _icons.clear();
    });
    if (repo == null) {
      setState(() {
        _loading = false;
        _error = const _DeviceNotConnectedException();
      });
      return;
    }
    try {
      final apps = await repo.listApps();
      if (!mounted) return;
      setState(() {
        _apps = apps;
        _loading = false;
        _selected.removeWhere(
          (name) => !apps.any((app) => app.packageName == name),
        );
      });
      unawaited(_prefetchIcons(repo, apps));
    } catch (error, stackTrace) {
      logAppError('读取应用列表失败：${widget.serial}', error, stackTrace);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  Future<void> _prefetchIcons(
    DeviceAppRepository repo,
    List<InstalledApp> apps,
  ) async {
    final generation = ++_iconGeneration;
    final visible = filterInstalledApps(
      apps,
      filter: _filter,
      query: _search.text,
    );
    final queue = [...visible, ...apps.where((app) => !visible.contains(app))];
    const concurrency = 3;
    var next = 0;
    Future<void> worker() async {
      while (mounted && generation == _iconGeneration) {
        if (next >= queue.length) return;
        final app = queue[next++];
        if (_icons.containsKey(app.packageName)) continue;
        final bytes = await repo.loadIcon(app);
        if (!mounted || generation != _iconGeneration || bytes == null) {
          continue;
        }
        setState(() => _icons[app.packageName] = bytes);
      }
    }

    await Future.wait(
      List<Future<void>>.generate(concurrency, (_) => worker()),
    );
  }

  List<InstalledApp> get _visible =>
      filterInstalledApps(_apps, filter: _filter, query: _search.text);

  List<InstalledApp> get _selectedApps =>
      _apps.where((app) => _selected.contains(app.packageName)).toList();

  void _toggleSelecting() {
    setState(() {
      _selecting = !_selecting;
      if (!_selecting) _selected.clear();
    });
  }

  void _toggleSelected(InstalledApp app) {
    setState(() {
      if (!_selected.add(app.packageName)) {
        _selected.remove(app.packageName);
      }
    });
  }

  void _selectAllVisible() {
    setState(() {
      _selecting = true;
      for (final app in _visible) {
        _selected.add(app.packageName);
      }
    });
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  String _appNameList(Iterable<InstalledApp> apps) {
    final separator = Localizations.localeOf(context).languageCode == 'zh'
        ? '、'
        : ', ';
    final names = apps.map((app) => app.displayName).toList();
    if (names.length <= 6) return names.join(separator);
    return '${names.take(6).join(separator)}…';
  }

  ButtonStyle _dangerButtonStyle(ColorScheme scheme) {
    return FilledButton.styleFrom(
      backgroundColor: scheme.error,
      foregroundColor: scheme.onError,
    );
  }

  void _showMessage({
    required String title,
    required String message,
    bool isError = false,
  }) {
    if (!mounted) return;
    showAppMessage(
      ScaffoldMessenger.of(context),
      Theme.of(context),
      title: title,
      message: message,
      isError: isError,
    );
  }

  Future<void> _confirmUninstall(InstalledApp app) async {
    final l10n = context.l10n;
    final system = app.isSystem || app.isCoreSystem;
    final core = app.isCoreSystem;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return AlertDialog(
          title: Text(
            core
                ? l10n.appsUninstallCoreTitle
                : system
                ? l10n.appsUninstallSystemTitle
                : l10n.appsUninstallTitle,
          ),
          content: Text(
            core
                ? l10n.appsUninstallCoreConfirm(
                    app.displayName,
                    app.packageName,
                  )
                : system
                ? l10n.appsUninstallSystemConfirm(
                    app.displayName,
                    app.packageName,
                  )
                : l10n.appsUninstallConfirm(app.displayName, app.packageName),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              style: system
                  ? FilledButton.styleFrom(
                      backgroundColor: scheme.error,
                      foregroundColor: scheme.onError,
                    )
                  : null,
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                system
                    ? l10n.appsUninstallConfirmAction
                    : l10n.appsUninstallAction,
              ),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    await _runTask(
      label: l10n.appsTaskUninstall,
      total: 1,
      action: () async {
        final result = await _runBatch([app], (repo, app) {
          return repo.uninstall(app.packageName);
        });
        _finishTask(
          result,
          title: l10n.appsUninstallAction,
          success: l10n.appsUninstallSucceeded(app.displayName),
        );
        await _reload();
      },
    );
  }

  Future<bool> _confirmFreezeSystemApp(InstalledApp app) async {
    final l10n = context.l10n;
    final core = app.isCoreSystem;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return AlertDialog(
          title: Text(
            core ? l10n.appsFreezeCoreTitle : l10n.appsFreezeSystemTitle,
          ),
          content: Text(
            core
                ? l10n.appsFreezeCoreConfirm(app.displayName, app.packageName)
                : l10n.appsFreezeSystemConfirm(
                    app.displayName,
                    app.packageName,
                  ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.appsFreezeConfirmAction),
            ),
          ],
        );
      },
    );
    return confirmed == true;
  }

  Future<void> _freeze(InstalledApp app) async {
    if (app.isSystem || app.isCoreSystem) {
      final confirmed = await _confirmFreezeSystemApp(app);
      if (!confirmed || !mounted) return;
    }
    final method = await showFreezeMethodDialog(
      context,
      app: app,
      preferred: _freezeMethod,
    );
    if (method == null || !mounted) return;
    await _saveFreezeMethod(method);
    if (!mounted) return;
    final l10n = context.l10n;
    await _runTask(
      label: l10n.appsTaskFreeze,
      total: 1,
      action: () async {
        final result = await _runBatch([app], (repo, app) {
          return repo.setFrozen(app.packageName, frozen: true, method: method);
        });
        _finishTask(
          result,
          title: l10n.appsFreezeAction,
          success: l10n.appsFreezeSucceeded(app.displayName),
        );
        await _reload();
      },
    );
  }

  Future<void> _unfreeze(InstalledApp app) async {
    final methods = app.activeFreezeMethods;
    if (methods.isEmpty) return;
    final l10n = context.l10n;
    await _runTask(
      label: l10n.appsTaskUnfreeze,
      total: 1,
      action: () async {
        final result = await _runBatch([app], (repo, app) async {
          if (_task?.cancelRequested == true) {
            throw const AppOperationCancelled();
          }
          for (final method in methods) {
            if (_task?.cancelRequested == true) {
              throw const AppOperationCancelled();
            }
            await repo.setFrozen(
              app.packageName,
              frozen: false,
              method: method,
            );
          }
        });
        _finishTask(
          result,
          title: l10n.appsUnfreezeAction,
          success: l10n.appsUnfreezeSucceeded(app.displayName),
        );
        await _reload();
      },
    );
  }

  Future<void> _batchUninstall() async {
    final apps = _selectedApps;
    if (apps.isEmpty || !mounted) return;
    final l10n = context.l10n;
    final risk = systemAppRisk(apps);
    final danger = risk != SystemAppRisk.none;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return AlertDialog(
          title: Text(switch (risk) {
            SystemAppRisk.core => l10n.appsUninstallCoreTitle,
            SystemAppRisk.system => l10n.appsUninstallSystemTitle,
            SystemAppRisk.none => l10n.appsUninstallTitle,
          }),
          content: Text(switch (risk) {
            SystemAppRisk.core => l10n.appsBatchUninstallCoreConfirm(
              apps.length,
              _appNameList(apps.where((app) => app.isCoreSystem)),
            ),
            SystemAppRisk.system => l10n.appsBatchUninstallSystemConfirm(
              apps.length,
              _appNameList(
                apps.where((app) => app.isSystem || app.isCoreSystem),
              ),
            ),
            SystemAppRisk.none => l10n.appsBatchUninstallConfirm(apps.length),
          }, style: danger ? TextStyle(color: scheme.error) : null),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              style: danger ? _dangerButtonStyle(scheme) : null,
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                danger
                    ? l10n.appsUninstallConfirmAction
                    : l10n.appsUninstallAction,
              ),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    await _runTask(
      label: l10n.appsTaskUninstall,
      total: apps.length,
      action: () async {
        final result = await _runBatch(apps, (repo, app) {
          return repo.uninstall(app.packageName);
        });
        _finishTask(
          result,
          title: l10n.appsUninstallAction,
          success: l10n.appsBatchUninstallSucceeded(result.succeeded),
          exitSelection: true,
        );
        await _reload();
      },
    );
  }

  Future<void> _batchFreeze() async {
    final apps = _selectedApps;
    if (apps.isEmpty || !mounted) return;
    final l10n = context.l10n;
    final risk = systemAppRisk(apps);
    final danger = risk != SystemAppRisk.none;
    final method = await showBatchFreezeDialog(
      context,
      title: switch (risk) {
        SystemAppRisk.core => l10n.appsFreezeCoreTitle,
        SystemAppRisk.system => l10n.appsFreezeSystemTitle,
        SystemAppRisk.none => l10n.appsFreezeTitle,
      },
      message: switch (risk) {
        SystemAppRisk.core => l10n.appsBatchFreezeCoreConfirm(
          apps.length,
          _appNameList(apps.where((app) => app.isCoreSystem)),
        ),
        SystemAppRisk.system => l10n.appsBatchFreezeSystemConfirm(
          apps.length,
          _appNameList(apps.where((app) => app.isSystem || app.isCoreSystem)),
        ),
        SystemAppRisk.none => l10n.appsBatchFreezeConfirm(apps.length),
      },
      confirmLabel: danger
          ? l10n.appsFreezeConfirmAction
          : l10n.appsFreezeAction,
      danger: danger,
      preferred: _freezeMethod,
    );
    if (method == null || !mounted) return;
    await _saveFreezeMethod(method);
    if (!mounted) return;
    await _runTask(
      label: l10n.appsTaskFreeze,
      total: apps.length,
      action: () async {
        final result = await _runBatch(apps, (repo, app) {
          return repo.setFrozen(app.packageName, frozen: true, method: method);
        });
        _finishTask(
          result,
          title: l10n.appsFreezeAction,
          success: l10n.appsBatchFreezeSucceeded(result.succeeded),
          exitSelection: true,
        );
        await _reload();
      },
    );
  }

  Future<void> _batchExport() async {
    final apps = _selectedApps;
    if (apps.isEmpty || !mounted) return;
    final l10n = context.l10n;
    final directory = await _askExportDirectory(
      l10n.appsBatchExportPrompt(apps.length),
    );
    if (directory == null || !mounted) return;
    await _runExport(apps, directory, exitSelection: true);
  }

  Future<_BatchOutcome> _runBatch(
    List<InstalledApp> apps,
    Future<void> Function(DeviceAppRepository repo, InstalledApp app) action,
  ) async {
    final repo = _repository();
    if (repo == null) throw const _DeviceNotConnectedException();
    _activeRepo = repo;
    final outcome = _BatchOutcome();
    try {
      for (final app in apps) {
        final task = _task;
        if (task?.cancelRequested == true) {
          outcome.cancelled = true;
          break;
        }
        if (task != null) {
          task.currentName = app.displayName;
          _publishTask(force: true);
        }
        try {
          await action(repo, app);
          outcome.succeeded++;
        } on AppOperationCancelled {
          outcome.cancelled = true;
          _publishTask(force: true);
          break;
        } catch (error, stackTrace) {
          if (_task?.cancelRequested == true) {
            outcome.cancelled = true;
            break;
          }
          outcome.failed++;
          outcome.firstError ??= error;
          logAppError('批量操作失败：${app.packageName}', error, stackTrace);
        }
        if (task != null) {
          task.completed = outcome.succeeded + outcome.failed;
          _publishTask(force: true);
        }
      }
      return outcome;
    } finally {
      if (identical(_activeRepo, repo)) _activeRepo = null;
    }
  }

  void _finishTask(
    _BatchOutcome result, {
    required String title,
    required String success,
    bool exitSelection = false,
  }) {
    final l10n = context.l10n;
    if (result.cancelled && result.succeeded == 0 && result.failed == 0) {
      _showMessage(title: title, message: l10n.appsTaskCancelled);
      return;
    }
    if (result.succeeded == 0) {
      throw result.firstError ?? StateError(l10n.appsActionFailed);
    }
    final message = result.failed > 0
        ? l10n.appsBatchPartial(result.succeeded, result.failed)
        : result.cancelled
        ? l10n.appsTaskCancelledDone(result.succeeded)
        : success;
    _showMessage(title: title, message: message, isError: result.failed > 0);
    if (exitSelection && !result.cancelled && result.failed == 0) {
      _exitSelection();
    }
  }

  Future<void> _exportApp(InstalledApp app) async {
    final l10n = context.l10n;
    final directory = await _askExportDirectory(
      l10n.appsExportPrompt(app.displayName),
    );
    if (directory == null || !mounted) return;
    await _runExport([app], directory, singlePath: true);
  }

  Future<void> _runExport(
    List<InstalledApp> apps,
    String directory, {
    bool exitSelection = false,
    bool singlePath = false,
  }) async {
    final l10n = context.l10n;
    await _runTask(
      label: l10n.appsTaskExport,
      total: apps.length,
      modal: true,
      action: () async {
        final repo = _repository();
        if (repo == null) throw const _DeviceNotConnectedException();
        _activeRepo = repo;
        final outcome = _BatchOutcome();
        final planned = <(InstalledApp, List<AppExportFile>)>[];
        final task = _task;
        if (task != null) {
          task.measuring = true;
          _publishTask(force: true);
        }
        for (final app in apps) {
          if (_task?.cancelRequested == true) {
            outcome.cancelled = true;
            break;
          }
          if (task != null) {
            task.currentName = app.displayName;
            _publishTask(force: true);
          }
          try {
            final files = await repo.listExportFiles(
              app,
              isCancelled: () => _task?.cancelRequested ?? false,
            );
            planned.add((app, files));
            task?.bytesTotal += files.fold<int>(
              0,
              (sum, file) => sum + file.size,
            );
            _publishTask(force: true);
          } on AppOperationCancelled {
            outcome.cancelled = true;
            break;
          } catch (error, stackTrace) {
            if (_task?.cancelRequested == true) {
              outcome.cancelled = true;
              break;
            }
            outcome.failed++;
            outcome.firstError ??= error;
            logAppError('计算导出大小失败：${app.packageName}', error, stackTrace);
          }
        }
        if (task != null) {
          task.measuring = false;
          _publishTask(force: true);
        }
        var doneBytes = 0;
        String? exportedPath;
        if (!outcome.cancelled) {
          for (final entry in planned) {
            final app = entry.$1;
            final files = entry.$2;
            if (_task?.cancelRequested == true) {
              outcome.cancelled = true;
              break;
            }
            if (task != null) {
              task.currentName = app.displayName;
              _publishTask(force: true);
            }
            try {
              final written = await repo.exportToDirectory(
                app,
                directory,
                files: files,
                isCancelled: () => _task?.cancelRequested ?? false,
                onProgress: (done, _) {
                  final current = task;
                  if (current == null) return;
                  final next = doneBytes + done;
                  current.bytesDone = next > current.bytesTotal
                      ? current.bytesTotal
                      : next;
                  _publishTask();
                },
              );
              exportedPath ??= written.first.path;
              outcome.succeeded++;
              doneBytes += files.fold<int>(0, (sum, file) => sum + file.size);
              if (task != null) {
                task.bytesDone = doneBytes > task.bytesTotal
                    ? task.bytesTotal
                    : doneBytes;
                task.completed = outcome.succeeded + outcome.failed;
                _publishTask(force: true);
              }
            } on AppOperationCancelled {
              outcome.cancelled = true;
              break;
            } catch (error, stackTrace) {
              if (_task?.cancelRequested == true) {
                outcome.cancelled = true;
                break;
              }
              outcome.failed++;
              outcome.firstError ??= error;
              logAppError('批量操作失败：${app.packageName}', error, stackTrace);
              if (task != null) {
                task.completed = outcome.succeeded + outcome.failed;
                _publishTask(force: true);
              }
            }
          }
        }
        if (identical(_activeRepo, repo)) _activeRepo = null;
        _finishTask(
          outcome,
          title: l10n.appsExportAction,
          success: singlePath
              ? l10n.appsExportSucceeded(exportedPath ?? directory)
              : l10n.appsBatchExportSucceeded(outcome.succeeded, directory),
          exitSelection: exitSelection,
        );
      },
    );
  }

  Future<String?> _askExportDirectory(String prompt) async {
    final l10n = context.l10n;
    final controller = TextEditingController(text: _defaultExportDirectory());
    final directory = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.appsExportTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(prompt),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: l10n.appsExportDirectory,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(l10n.appsExportAction),
          ),
        ],
      ),
    );
    controller.dispose();
    if (directory == null || directory.isEmpty) return null;
    return directory;
  }

  String _defaultExportDirectory() {
    final home =
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    if (home.isEmpty) return Directory.systemTemp.path;
    return '$home${Platform.pathSeparator}Downloads';
  }

  Future<void> _runTask({
    required String label,
    required int total,
    required Future<void> Function() action,
    bool modal = false,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _task = _AppTask(label: label, total: total, byBytes: modal);
    });
    _publishTask(force: true);
    if (modal && mounted) {
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (context) => _ExportProgressDialog(
            tick: _taskTick,
            taskOf: () => _task,
            onCancel: _requestCancel,
          ),
        ),
      );
    }
    try {
      await action();
    } catch (error, stackTrace) {
      logAppError('应用管理操作失败：${widget.serial}', error, stackTrace);
      if (!mounted) return;
      final l10n = context.l10n;
      _showMessage(
        title: l10n.appsActionFailed,
        message: error is _DeviceNotConnectedException
            ? l10n.deviceOverviewNotConnected
            : '$error',
        isError: true,
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _task = null;
        });
        _publishTask(force: true);
      }
    }
  }

  void _requestCancel() {
    final task = _task;
    if (task == null || task.cancelRequested) return;
    task.cancelRequested = true;
    unawaited(_activeRepo?.abort());
  }

  void _publishTask({bool force = false}) {
    final now = DateTime.now();
    if (!force &&
        now.difference(_progressUiAt) < const Duration(milliseconds: 120)) {
      return;
    }
    _progressUiAt = now;
    _taskTick.value++;
    if (mounted) setState(() {});
  }

  int _countPercent(_AppTask task) {
    if (task.total <= 0) return 0;
    return (task.completed * 100 / task.total).round().clamp(0, 100);
  }

  Widget _buildTaskBar(BuildContext context, _AppTask task) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final name = task.currentName.isEmpty ? '…' : task.currentName;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                LinearProgressIndicator(
                  value: task.total <= 0 ? null : task.completed / task.total,
                  minHeight: 4,
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.appsTaskProgress(
                    task.label,
                    name,
                    task.completed,
                    task.total,
                    _countPercent(task),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: task.completed >= task.total ? null : _requestCancel,
            child: Text(l10n.appsCancelTask),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              TextField(
                controller: _search,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: l10n.appsSearchHint,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final entry in <(AppListFilter, String)>[
                        (AppListFilter.user, l10n.appsFilterUser),
                        (AppListFilter.system, l10n.appsFilterSystem),
                        (AppListFilter.frozen, l10n.appsFilterFrozen),
                        (AppListFilter.all, l10n.appsFilterAll),
                      ])
                        FilterChip(
                          label: Text(entry.$2),
                          selected: _filter == entry.$1,
                          onSelected: (_) => setState(() => _filter = entry.$1),
                        ),
                    ],
                  ),
                  IconButton(
                    tooltip: _selecting ? l10n.appsSelectDone : l10n.appsSelect,
                    onPressed: _busy ? null : _toggleSelecting,
                    icon: Icon(_selecting ? Icons.close : Icons.checklist),
                  ),
                  IconButton(
                    tooltip: l10n.appsRefresh,
                    onPressed: _loading || _busy ? null : _reload,
                    icon: const Icon(Icons.refresh),
                  ),
                  Text(
                    l10n.appsCount(_visible.length),
                    style: theme.textTheme.bodySmall,
                  ),
                  if (_selecting)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        Text(
                          l10n.appsSelectedCount(_selectedApps.length),
                          style: theme.textTheme.bodySmall,
                        ),
                        TextButton(
                          onPressed: _busy ? null : _selectAllVisible,
                          child: Text(l10n.appsSelectAll),
                        ),
                        TextButton(
                          onPressed: _busy || _selected.isEmpty
                              ? null
                              : () => setState(_selected.clear),
                          child: Text(l10n.appsSelectClear),
                        ),
                        TextButton(
                          onPressed: _busy || _selectedApps.isEmpty
                              ? null
                              : () => unawaited(_batchExport()),
                          child: Text(l10n.appsExportAction),
                        ),
                        TextButton(
                          onPressed: _busy || _selectedApps.isEmpty
                              ? null
                              : () => unawaited(_batchFreeze()),
                          child: Text(l10n.appsFreezeAction),
                        ),
                        TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: theme.colorScheme.error,
                          ),
                          onPressed: _busy || _selectedApps.isEmpty
                              ? null
                              : () => unawaited(_batchUninstall()),
                          child: Text(l10n.appsUninstallAction),
                        ),
                      ],
                    ),
                ],
              ),
            ],
          ),
        ),
        if (_task case final task? when !task.byBytes)
          _buildTaskBar(context, task),
        if (_loading && _task == null)
          const LinearProgressIndicator(minHeight: 2),
        Expanded(child: _buildBody(context)),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10n.appsLoadFailed(
              _error is _DeviceNotConnectedException
                  ? l10n.deviceOverviewNotConnected
                  : '$_error',
            ),
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
      );
    }
    final apps = _visible;
    if (apps.isEmpty) {
      return Center(child: Text(l10n.appsEmpty));
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
      itemCount: apps.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final app = apps[index];
        final icon = _icons[app.packageName];
        final version = [
          if (app.versionName != null && app.versionName!.isNotEmpty)
            app.versionName,
          if (app.versionCode != null) '${app.versionCode}',
        ].join(' · ');
        final details = <String>[
          app.packageName,
          if (version.isNotEmpty) l10n.appsVersion(version),
          if (app.sizeBytes != null)
            l10n.appsSize(formatByteSize(app.sizeBytes!)),
          if (app.primaryPath != null) l10n.appsPath(app.primaryPath!),
        ];
        final selected = _selected.contains(app.packageName);
        final avatar = CircleAvatar(
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
          backgroundImage: icon == null ? null : MemoryImage(icon),
          child: icon == null ? const Icon(Icons.android) : null,
        );
        return ListTile(
          selected: _selecting && selected,
          onTap: !_selecting || _busy ? null : () => _toggleSelected(app),
          onLongPress: _busy
              ? null
              : () {
                  setState(() {
                    _selecting = true;
                    _selected.add(app.packageName);
                  });
                },
          leading: _selecting
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    IgnorePointer(
                      child: Checkbox(
                        value: selected,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged: (_) {},
                      ),
                    ),
                    avatar,
                  ],
                )
              : avatar,
          title: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Expanded(
                child: Text(
                  app.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (app.isDisabledUser) ...<Widget>[
                const SizedBox(width: 8),
                _AppMetaTag(label: l10n.appsDisabledBadge),
              ],
              if (app.isSuspended) ...<Widget>[
                const SizedBox(width: 8),
                _AppMetaTag(label: l10n.appsSuspendedBadge),
              ],
              if (app.isAmFrozen) ...<Widget>[
                const SizedBox(width: 8),
                _AppMetaTag(label: l10n.appsAmFrozenBadge),
              ],
              if (app.isFrozen) ...<Widget>[
                const SizedBox(width: 8),
                _AppMetaTag.button(
                  label: l10n.appsUnfreezeAction,
                  onPressed: _busy ? null : () => unawaited(_unfreeze(app)),
                ),
              ],
            ],
          ),
          subtitle: Text(
            details.join('\n'),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
          isThreeLine: true,
          trailing: PopupMenuButton<_AppAction>(
            enabled: !_busy,
            onSelected: (action) {
              switch (action) {
                case _AppAction.export:
                  unawaited(_exportApp(app));
                case _AppAction.uninstall:
                  unawaited(_confirmUninstall(app));
                case _AppAction.freeze:
                  unawaited(_freeze(app));
                case _AppAction.unfreeze:
                  unawaited(_unfreeze(app));
              }
            },
            itemBuilder: (context) => <PopupMenuEntry<_AppAction>>[
              PopupMenuItem(
                value: _AppAction.export,
                child: Text(l10n.appsExportAction),
              ),
              PopupMenuItem(
                value: _AppAction.freeze,
                child: Text(l10n.appsFreezeAction),
              ),
              if (app.isFrozen)
                PopupMenuItem(
                  value: _AppAction.unfreeze,
                  child: Text(l10n.appsUnfreezeAction),
                ),
              PopupMenuItem(
                value: _AppAction.uninstall,
                child: Text(l10n.appsUninstallAction),
              ),
            ],
          ),
        );
      },
    );
  }
}

enum _AppAction { export, uninstall, freeze, unfreeze }

class _AppTask {
  _AppTask({required this.label, required this.total, this.byBytes = false});

  final String label;
  final int total;
  final bool byBytes;
  int completed = 0;
  String currentName = '';
  int bytesDone = 0;
  int bytesTotal = 0;
  bool measuring = false;
  bool cancelRequested = false;

  int get bytePercent {
    if (bytesTotal <= 0) return 0;
    return (bytesDone * 100 / bytesTotal).round().clamp(0, 100);
  }
}

class _BatchOutcome {
  int succeeded = 0;
  int failed = 0;
  Object? firstError;
  bool cancelled = false;
}

class _ExportProgressDialog extends StatefulWidget {
  const _ExportProgressDialog({
    required this.tick,
    required this.taskOf,
    required this.onCancel,
  });

  final ValueNotifier<int> tick;
  final _AppTask? Function() taskOf;
  final VoidCallback onCancel;

  @override
  State<_ExportProgressDialog> createState() => _ExportProgressDialogState();
}

class _ExportProgressDialogState extends State<_ExportProgressDialog> {
  var _popped = false;

  void _popIfDone() {
    if (_popped || widget.taskOf() != null || !mounted) return;
    _popped = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ValueListenableBuilder<int>(
      valueListenable: widget.tick,
      builder: (context, _, _) {
        final task = widget.taskOf();
        if (task == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _popIfDone());
          return const SizedBox.shrink();
        }
        final percent = task.bytePercent;
        return PopScope(
          canPop: false,
          child: AlertDialog(
            title: Text(task.label),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    task.currentName.isEmpty ? '…' : task.currentName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 16),
                  LinearProgressIndicator(
                    value: task.measuring || task.bytesTotal <= 0
                        ? null
                        : percent / 100,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    task.measuring
                        ? l10n.appsExportMeasuring
                        : '${l10n.appsExportPercent(percent)}  ${l10n.appsExportBytes(formatByteSize(task.bytesDone), formatByteSize(task.bytesTotal))}',
                  ),
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: widget.onCancel,
                child: Text(l10n.appsCancelTask),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 应用状态标签与解冻按钮共用尺寸，保证同一行里等高。
class _AppMetaTag extends StatelessWidget {
  const _AppMetaTag({required this.label}) : onPressed = null, _button = false;

  const _AppMetaTag.button({required this.label, required this.onPressed})
    : _button = true;

  final String label;
  final VoidCallback? onPressed;
  final bool _button;

  static const double height = 32;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = !_button || onPressed != null;
    final background = _button && enabled
        ? scheme.secondaryContainer
        : scheme.surfaceContainerHighest;
    final foreground = _button && enabled
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant;
    final radius = BorderRadius.circular(height / 2);
    final child = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: height, maxHeight: height),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Center(
          child: Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(color: foreground),
          ),
        ),
      ),
    );
    return Material(
      color: background,
      borderRadius: radius,
      child: _button
          ? InkWell(onTap: onPressed, borderRadius: radius, child: child)
          : child,
    );
  }
}

class _DeviceNotConnectedException implements Exception {
  const _DeviceNotConnectedException();
}

/// 移动端全屏应用管理页。
class AppsFeaturePage extends StatelessWidget {
  const AppsFeaturePage({super.key, required this.serial});

  final String serial;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.workspaceAppsTitle),
        actions: const <Widget>[LocaleSelector()],
      ),
      body: AppsPage(serial: serial),
    );
  }
}
