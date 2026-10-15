import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../connection/connection_manager.dart';
import '../l10n/generated/fire_adb_localizations.dart';
import '../log/app_log.dart';
import 'data/bean/app_freeze.dart';
import 'data/bean/installed_app.dart';
import 'data/repo/device_app_repository.dart';
import 'data/source/app_freeze_settings.dart';
import 'data/source/app_inventory.dart';
import 'data/source/fire_app_service.dart';
import 'loader/app_display_loader.dart';

/// 一次操作结束后给界面看的提示。
class AppNotice {
  const AppNotice({
    required this.title,
    required this.message,
    this.isError = false,
  });

  final String title;
  final String message;
  final bool isError;
}

class DeviceNotConnectedException implements Exception {
  const DeviceNotConnectedException();
}

/// 正在执行的卸载、冻结或导出。
class AppTask {
  AppTask({required this.label, required this.total, this.byBytes = false});

  final String label;
  final int total;
  final bool byBytes;
  int completed = 0;
  String currentName = '';
  int bytesDone = 0;
  int bytesTotal = 0;
  bool measuring = false;
  bool cancelRequested = false;

  int get countPercent {
    if (total <= 0) return 0;
    return (completed * 100 / total).round().clamp(0, 100);
  }

  int get bytePercent {
    if (bytesTotal <= 0) return 0;
    return (bytesDone * 100 / bytesTotal).round().clamp(0, 100);
  }
}

/// 一台设备上的应用列表：过滤、多选、详情加载和批量任务。
class AppsController extends GetxController {
  AppsController(this.serial);

  final String serial;
  final TextEditingController search = TextEditingController();
  late final AppDisplayLoader _display;

  final RxString query = ''.obs;
  final RxList<InstalledApp> apps = <InstalledApp>[].obs;
  final Rx<AppListFilter> filter = AppListFilter.user.obs;
  final Rx<AppFreezeMethod> freezeMethod = AppFreezeMethod.disableUser.obs;
  final RxBool loading = true.obs;
  final RxBool busy = false.obs;
  final RxBool selecting = false.obs;
  final RxSet<String> selected = <String>{}.obs;
  final Rxn<Object> error = Rxn<Object>();
  final Rxn<AppTask> task = Rxn<AppTask>();
  final RxInt taskTick = 0.obs;

  DeviceAppRepository? _activeRepo;
  DateTime _progressUiAt = DateTime.fromMillisecondsSinceEpoch(0);
  var _generation = 0;
  var _closed = false;

  ConnectionManager get _manager => Get.find<ConnectionManager>();

  List<InstalledApp> get visible {
    apps.length;
    return filterInstalledApps(apps, filter: filter.value, query: query.value);
  }

  List<InstalledApp> get selectedApps {
    apps.length;
    selected.length;
    return apps.where((app) => selected.contains(app.packageName)).toList();
  }

  Uint8List? iconOf(String packageName) => _display.iconOf(packageName);

  void ensure(InstalledApp app) => _display.ensure(app);

  void setFilter(AppListFilter value) => filter.value = value;

  @override
  void onInit() {
    super.onInit();
    _display = AppDisplayLoader(
      onUpdated: _onDisplayUpdated,
      deviceOf: () => _manager.deviceOf(serial),
      repositoryOf: _repository,
      appOf: _appByName,
    );
    search.addListener(_onSearch);
    unawaited(_loadFreezeMethod());
    unawaited(reload());
  }

  @override
  void onClose() {
    _generation++;
    _closed = true;
    _display.dispose();
    search.removeListener(_onSearch);
    search.dispose();
    super.onClose();
  }

  void _onSearch() {
    if (_closed) return;
    query.value = search.text;
  }

  Future<void> _loadFreezeMethod() async {
    try {
      freezeMethod.value = await AppFreezeSettings.loadMethod();
    } catch (error, stackTrace) {
      log.severe('读取应用冻结方式失败', error, stackTrace);
    }
  }

  Future<void> _saveFreezeMethod(AppFreezeMethod method) async {
    freezeMethod.value = method;
    try {
      await AppFreezeSettings.saveMethod(method);
    } catch (error, stackTrace) {
      log.severe('保存应用冻结方式失败', error, stackTrace);
    }
  }

  DeviceAppRepository? _repository() {
    final device = _manager.deviceOf(serial);
    if (device == null) return null;
    final profile = _manager.profileOf(serial);
    return DeviceAppRepository(
      device,
      host: profile?.host,
      adbSerial: profile?.adbSerial,
    );
  }

  Future<void> reload() async {
    final generation = ++_generation;
    _display.reset();
    final repo = _repository();
    loading.value = true;
    error.value = null;
    apps.clear();
    if (repo == null) {
      loading.value = false;
      error.value = const DeviceNotConnectedException();
      return;
    }
    try {
      final device = _manager.deviceOf(serial);
      if (device == null) {
        loading.value = false;
        error.value = const DeviceNotConnectedException();
        return;
      }
      final began = Stopwatch()..start();
      var shownAtMs = -1;
      await loadFireAppSummaries(
        device,
        onCatalog: (items, timing) {
          if (_closed || generation != _generation) return;
          _replaceApps(items);
          final count = items.length;
          final jarMs = timing.jarMs;
          final readyMs = timing.readyMs;
          final listMs = timing.listMs;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_closed || generation != _generation || shownAtMs >= 0) return;
            shownAtMs = began.elapsedMilliseconds;
            final uiMs = shownAtMs - jarMs - readyMs - listMs;
            final startup = jarMs == 0 && readyMs == 0
                ? '进程仍在'
                : 'jar $jarMs，进程就绪 $readyMs';
            log.info(
              '应用列表已显示 $count 个，距开始 $shownAtMs ms'
              '（$startup，列表 $listMs，界面 $uiMs）',
            );
          });
        },
        onNames: (items, timing) {
          if (_closed || generation != _generation) return;
          _replaceApps(items);
          final named = items
              .where(
                (item) =>
                    item.label.isNotEmpty && item.label != item.packageName,
              )
              .length;
          void logNames() {
            if (_closed || generation != _generation) return;
            final now = began.elapsedMilliseconds;
            final nameMs = shownAtMs < 0 ? 0 : now - shownAtMs;
            log.info(
              '应用名称已更新：有名称 $named 个，距开始 $now ms（名称 $nameMs）',
            );
          }

          if (shownAtMs >= 0) {
            logNames();
          } else {
            WidgetsBinding.instance.addPostFrameCallback((_) => logNames());
          }
        },
      );
      if (_closed || generation != _generation) return;
      unawaited(_loadAmFrozen(generation, repo));
    } catch (loadError, stackTrace) {
      log.severe('读取应用列表失败：$serial', loadError, stackTrace);
      if (_closed || generation != _generation) return;
      loading.value = false;
      error.value = loadError;
    }
  }

  void _replaceApps(List<FireAppSummary> summaries) {
    final loaded =
        <InstalledApp>[
          for (final summary in summaries) installedAppFromSummary(summary),
        ]..sort(
          (a, b) => a.packageName.toLowerCase().compareTo(
            b.packageName.toLowerCase(),
          ),
        );
    apps.assignAll(loaded);
    loading.value = false;
    selected.removeWhere((name) => !apps.any((app) => app.packageName == name));
  }

  Future<void> _loadAmFrozen(int generation, DeviceAppRepository repo) async {
    try {
      final frozen = await repo.listAmFrozenPackages();
      if (_closed || generation != _generation || frozen.isEmpty) return;
      apps.assignAll(<InstalledApp>[
        for (final app in apps)
          if (frozen.contains(app.packageName))
            app.copyWith(isAmFrozen: true)
          else
            app,
      ]);
    } catch (error, stackTrace) {
      log.severe('读取 AM 冻结列表失败：$serial', error, stackTrace);
    }
  }

  void _onDisplayUpdated() {
    if (_closed) return;
    final current = apps.toList();
    apps.assignAll(<InstalledApp>[
      for (final app in current)
        switch (_display[app.packageName]) {
          final details? => applyAppDisplay(app, details),
          _ => app,
        },
    ]);
  }

  InstalledApp? _appByName(String packageName) {
    for (final app in apps) {
      if (app.packageName == packageName) return app;
    }
    return null;
  }

  void toggleSelecting() {
    selecting.value = !selecting.value;
    if (!selecting.value) selected.clear();
  }

  void toggleSelected(InstalledApp app) {
    if (!selected.add(app.packageName)) {
      selected.remove(app.packageName);
    }
  }

  void selectAllVisible() {
    selecting.value = true;
    for (final app in visible) {
      selected.add(app.packageName);
    }
  }

  void clearSelection() => selected.clear();

  void startSelecting(InstalledApp app) {
    selecting.value = true;
    selected.add(app.packageName);
  }

  void _exitSelection() {
    selecting.value = false;
    selected.clear();
  }

  Future<AppNotice?> uninstall(FireAdbLocalizations l10n, InstalledApp app) {
    return _runTask(
      l10n: l10n,
      label: l10n.appsTaskUninstall,
      total: 1,
      action: () async {
        final result = await _runBatch(<InstalledApp>[app], (repo, item) {
          return repo.uninstall(item.packageName);
        });
        final notice = _finishTask(
          l10n,
          result,
          title: l10n.appsUninstallAction,
          success: l10n.appsUninstallSucceeded(app.displayName),
        );
        await reload();
        if (result.failed == 0) {
          _throwIfUninstallRemains(l10n, <InstalledApp>[app]);
        }
        return notice;
      },
    );
  }

  Future<AppNotice?> freeze(
    FireAdbLocalizations l10n,
    InstalledApp app,
    AppFreezeMethod method,
  ) async {
    await _saveFreezeMethod(method);
    if (_closed) return null;
    return _runTask(
      l10n: l10n,
      label: l10n.appsTaskFreeze,
      total: 1,
      action: () async {
        final result = await _runBatch(<InstalledApp>[app], (repo, item) {
          return repo.setFrozen(item.packageName, frozen: true, method: method);
        });
        final notice = _finishTask(
          l10n,
          result,
          title: l10n.appsFreezeAction,
          success: l10n.appsFreezeSucceeded(app.displayName),
        );
        await reload();
        return notice;
      },
    );
  }

  Future<AppNotice?> unfreeze(FireAdbLocalizations l10n, InstalledApp app) {
    final methods = app.activeFreezeMethods;
    if (methods.isEmpty) return Future<AppNotice?>.value();
    return _runTask(
      l10n: l10n,
      label: l10n.appsTaskUnfreeze,
      total: 1,
      action: () async {
        final result = await _runBatch(<InstalledApp>[app], (repo, item) async {
          if (task.value?.cancelRequested == true) {
            throw const AppOperationCancelled();
          }
          for (final method in methods) {
            if (task.value?.cancelRequested == true) {
              throw const AppOperationCancelled();
            }
            await repo.setFrozen(
              item.packageName,
              frozen: false,
              method: method,
            );
          }
        });
        final notice = _finishTask(
          l10n,
          result,
          title: l10n.appsUnfreezeAction,
          success: l10n.appsUnfreezeSucceeded(app.displayName),
        );
        await reload();
        return notice;
      },
    );
  }

  Future<AppNotice?> uninstallMany(
    FireAdbLocalizations l10n,
    List<InstalledApp> targets,
  ) {
    return _runTask(
      l10n: l10n,
      label: l10n.appsTaskUninstall,
      total: targets.length,
      action: () async {
        final result = await _runBatch(targets, (repo, item) {
          return repo.uninstall(item.packageName);
        });
        final notice = _finishTask(
          l10n,
          result,
          title: l10n.appsUninstallAction,
          success: l10n.appsBatchUninstallSucceeded(result.succeeded),
          exitSelection: true,
        );
        await reload();
        if (result.failed == 0) {
          _throwIfUninstallRemains(l10n, targets);
        }
        return notice;
      },
    );
  }

  Future<AppNotice?> freezeMany(
    FireAdbLocalizations l10n,
    List<InstalledApp> targets,
    AppFreezeMethod method,
  ) async {
    await _saveFreezeMethod(method);
    if (_closed) return null;
    return _runTask(
      l10n: l10n,
      label: l10n.appsTaskFreeze,
      total: targets.length,
      action: () async {
        final result = await _runBatch(targets, (repo, item) {
          return repo.setFrozen(item.packageName, frozen: true, method: method);
        });
        final notice = _finishTask(
          l10n,
          result,
          title: l10n.appsFreezeAction,
          success: l10n.appsBatchFreezeSucceeded(result.succeeded),
          exitSelection: true,
        );
        await reload();
        return notice;
      },
    );
  }

  Future<AppNotice?> export(
    FireAdbLocalizations l10n,
    List<InstalledApp> targets,
    String directory, {
    bool exitSelection = false,
    bool singlePath = false,
  }) {
    return _runTask(
      l10n: l10n,
      label: l10n.appsTaskExport,
      total: targets.length,
      modal: true,
      action: () => _performExport(
        l10n,
        targets,
        directory,
        exitSelection: exitSelection,
        singlePath: singlePath,
      ),
    );
  }

  Future<AppNotice?> _performExport(
    FireAdbLocalizations l10n,
    List<InstalledApp> targets,
    String directory, {
    required bool exitSelection,
    required bool singlePath,
  }) async {
    final repo = _repository();
    if (repo == null) throw const DeviceNotConnectedException();
    _activeRepo = repo;
    final outcome = _BatchOutcome();
    final planned = <(InstalledApp, List<AppExportFile>)>[];
    final current = task.value;
    if (current != null) {
      current.measuring = true;
      _publish(force: true);
    }
    for (final app in targets) {
      if (task.value?.cancelRequested == true) {
        outcome.cancelled = true;
        break;
      }
      if (current != null) {
        current.currentName = app.displayName;
        _publish(force: true);
      }
      try {
        final files = await repo.listExportFiles(
          app,
          isCancelled: () => task.value?.cancelRequested ?? false,
        );
        planned.add((app, files));
        current?.bytesTotal += files.fold<int>(
          0,
          (sum, file) => sum + file.size,
        );
        _publish(force: true);
      } on AppOperationCancelled {
        outcome.cancelled = true;
        break;
      } catch (exportError, stackTrace) {
        if (task.value?.cancelRequested == true) {
          outcome.cancelled = true;
          break;
        }
        outcome.failed++;
        outcome.firstError ??= exportError;
        log.severe('计算导出大小失败：${app.packageName}', exportError, stackTrace);
      }
    }
    if (current != null) {
      current.measuring = false;
      _publish(force: true);
    }
    var doneBytes = 0;
    String? exportedPath;
    if (!outcome.cancelled) {
      for (final entry in planned) {
        final app = entry.$1;
        final files = entry.$2;
        if (task.value?.cancelRequested == true) {
          outcome.cancelled = true;
          break;
        }
        if (current != null) {
          current.currentName = app.displayName;
          _publish(force: true);
        }
        try {
          final written = await repo.exportToDirectory(
            app,
            directory,
            files: files,
            isCancelled: () => task.value?.cancelRequested ?? false,
            onProgress: (done, _) {
              if (current == null) return;
              final next = doneBytes + done;
              current.bytesDone = next > current.bytesTotal
                  ? current.bytesTotal
                  : next;
              _publish();
            },
          );
          exportedPath ??= written.first.path;
          outcome.succeeded++;
          doneBytes += files.fold<int>(0, (sum, file) => sum + file.size);
          if (current != null) {
            current.bytesDone = doneBytes > current.bytesTotal
                ? current.bytesTotal
                : doneBytes;
            current.completed = outcome.succeeded + outcome.failed;
            _publish(force: true);
          }
        } on AppOperationCancelled {
          outcome.cancelled = true;
          break;
        } catch (exportError, stackTrace) {
          if (task.value?.cancelRequested == true) {
            outcome.cancelled = true;
            break;
          }
          outcome.failed++;
          outcome.firstError ??= exportError;
          log.severe('批量操作失败：${app.packageName}', exportError, stackTrace);
          if (current != null) {
            current.completed = outcome.succeeded + outcome.failed;
            _publish(force: true);
          }
        }
      }
    }
    if (identical(_activeRepo, repo)) _activeRepo = null;
    final notice = _finishTask(
      l10n,
      outcome,
      title: l10n.appsExportAction,
      success: singlePath
          ? l10n.appsExportSucceeded(exportedPath ?? directory)
          : l10n.appsBatchExportSucceeded(outcome.succeeded, directory),
      exitSelection: exitSelection,
    );
    return notice;
  }

  Future<_BatchOutcome> _runBatch(
    List<InstalledApp> targets,
    Future<void> Function(DeviceAppRepository repo, InstalledApp app) action,
  ) async {
    final repo = _repository();
    if (repo == null) throw const DeviceNotConnectedException();
    _activeRepo = repo;
    final outcome = _BatchOutcome();
    try {
      for (final app in targets) {
        final current = task.value;
        if (current?.cancelRequested == true) {
          outcome.cancelled = true;
          break;
        }
        if (current != null) {
          current.currentName = app.displayName;
          _publish(force: true);
        }
        try {
          await action(repo, app);
          outcome.succeeded++;
        } on AppOperationCancelled {
          outcome.cancelled = true;
          _publish(force: true);
          break;
        } catch (batchError, stackTrace) {
          if (task.value?.cancelRequested == true) {
            outcome.cancelled = true;
            break;
          }
          outcome.failed++;
          outcome.firstError ??= batchError;
          log.severe('批量操作失败：${app.packageName}', batchError, stackTrace);
        }
        if (current != null) {
          current.completed = outcome.succeeded + outcome.failed;
          _publish(force: true);
        }
      }
      return outcome;
    } finally {
      if (identical(_activeRepo, repo)) _activeRepo = null;
    }
  }

  AppNotice _finishTask(
    FireAdbLocalizations l10n,
    _BatchOutcome result, {
    required String title,
    required String success,
    bool exitSelection = false,
  }) {
    if (result.cancelled && result.succeeded == 0 && result.failed == 0) {
      return AppNotice(title: title, message: l10n.appsTaskCancelled);
    }
    if (result.succeeded == 0) {
      throw result.firstError ?? StateError(l10n.appsActionFailed);
    }
    final message = result.failed > 0
        ? _partialFailureMessage(l10n, result)
        : result.cancelled
        ? l10n.appsTaskCancelledDone(result.succeeded)
        : success;
    if (exitSelection && !result.cancelled && result.failed == 0) {
      _exitSelection();
    }
    return AppNotice(
      title: title,
      message: message,
      isError: result.failed > 0,
    );
  }

  Future<AppNotice?> _runTask({
    required FireAdbLocalizations l10n,
    required String label,
    required int total,
    required Future<AppNotice?> Function() action,
    bool modal = false,
  }) async {
    if (busy.value) return null;
    busy.value = true;
    task.value = AppTask(label: label, total: total, byBytes: modal);
    _publish(force: true);
    try {
      return await action();
    } catch (taskError, stackTrace) {
      log.severe('应用管理操作失败：$serial', taskError, stackTrace);
      if (_closed) return null;
      return AppNotice(
        title: l10n.appsActionFailed,
        message: _operationErrorText(l10n, taskError),
        isError: true,
      );
    } finally {
      if (!_closed) {
        busy.value = false;
        task.value = null;
        _publish(force: true);
      }
    }
  }

  void _throwIfUninstallRemains(
    FireAdbLocalizations l10n,
    List<InstalledApp> targets,
  ) {
    if (_closed || error.value != null) return;
    final names = <String>[
      for (final item in targets)
        if (apps.any((app) => app.packageName == item.packageName))
          item.displayName,
    ];
    if (names.isEmpty) return;
    throw StateError(l10n.appsUninstallRemains(names.join('、')));
  }

  String _partialFailureMessage(FireAdbLocalizations l10n, _BatchOutcome result) {
    final summary = l10n.appsBatchPartial(result.succeeded, result.failed);
    final detail = result.firstError;
    if (detail == null) return summary;
    return '$summary\n${_operationErrorText(l10n, detail)}';
  }

  String _operationErrorText(FireAdbLocalizations l10n, Object error) {
    return switch (error) {
      DeviceNotConnectedException() => l10n.deviceOverviewNotConnected,
      StateError(:final message) when message.isNotEmpty => message,
      _ => '$error',
    };
  }

  void requestCancel() {
    final current = task.value;
    if (current == null || current.cancelRequested) return;
    current.cancelRequested = true;
    unawaited(_activeRepo?.abort());
  }

  void _publish({bool force = false}) {
    if (_closed) return;
    final now = DateTime.now();
    if (!force &&
        now.difference(_progressUiAt) < const Duration(milliseconds: 120)) {
      return;
    }
    _progressUiAt = now;
    task.refresh();
    taskTick.value++;
  }
}

class _BatchOutcome {
  int succeeded = 0;
  int failed = 0;
  Object? firstError;
  bool cancelled = false;
}
