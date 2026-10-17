import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../app_feedback.dart';
import '../../files/local_file_picker.dart';
import '../../l10n/fire_adb_localizations_ext.dart';
import '../../l10n/generated/fire_adb_localizations.dart';
import '../../log/app_log.dart';
import '../apps_controller.dart';
import '../data/bean/installed_app.dart';
import 'app_details_page.dart';
import 'app_dialogs.dart';
import 'app_freeze_dialogs.dart';
import 'app_list_tile.dart';
import 'app_permissions_page.dart';
import 'app_task_view.dart';
import 'apps_toolbar.dart';

class AppsPage extends StatefulWidget {
  const AppsPage({super.key, required this.serial});

  final String serial;

  @override
  State<AppsPage> createState() => _AppsPageState();
}

class _AppsPageState extends State<AppsPage> {
  late final AppsController controller;

  @override
  void initState() {
    super.initState();
    controller = Get.put(AppsController(widget.serial), tag: widget.serial);
  }

  @override
  void dispose() {
    // sessionEpoch 重建时新旧页同 tag：晚一帧再删，且只删自己那份，避免误删新实例。
    final tag = widget.serial;
    final mine = controller;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!Get.isRegistered<AppsController>(tag: tag)) return;
      if (!identical(Get.find<AppsController>(tag: tag), mine)) return;
      unawaited(Get.delete<AppsController>(tag: tag, force: true));
    });
    super.dispose();
  }

  void _show(AppNotice? notice) {
    if (notice == null || !mounted) return;
    showAppMessage(
      ScaffoldMessenger.of(context),
      Theme.of(context),
      title: notice.title,
      message: notice.message,
      isError: notice.isError,
    );
  }

  Future<void> _showWhenDone(
    Future<AppNotice?> future, {
    bool exportDialog = false,
  }) async {
    if (exportDialog && controller.task.value?.byBytes == true && mounted) {
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (context) => ExportProgressDialog(controller: controller),
        ),
      );
    }
    final notice = await future;
    _show(notice);
  }

  Future<void> _uninstall(InstalledApp app) async {
    if (!await confirmUninstallApp(context, app) || !mounted) return;
    await _showWhenDone(controller.uninstall(context.l10n, app));
  }

  Future<void> _freeze(InstalledApp app) async {
    if (app.isSystem || app.isCoreSystem) {
      final confirmed = await confirmFreezeSystemApp(context, app);
      if (!confirmed || !mounted) return;
    }
    final method = await showFreezeMethodDialog(
      context,
      app: app,
      preferred: controller.freezeMethod.value,
    );
    if (method == null || !mounted) return;
    await _showWhenDone(controller.freeze(context.l10n, app, method));
  }

  Future<void> _unfreeze(InstalledApp app) async {
    await _showWhenDone(controller.unfreeze(context.l10n, app));
  }

  Future<void> _batchUninstall() async {
    final targets = controller.selectedApps;
    if (targets.isEmpty || !mounted) return;
    if (!await confirmBatchUninstall(context, targets) || !mounted) return;
    await _showWhenDone(controller.uninstallMany(context.l10n, targets));
  }

  Future<void> _batchFreeze() async {
    final targets = controller.selectedApps;
    if (targets.isEmpty || !mounted) return;
    final method = await confirmBatchFreeze(
      context,
      apps: targets,
      preferred: controller.freezeMethod.value,
    );
    if (method == null || !mounted) return;
    await _showWhenDone(controller.freezeMany(context.l10n, targets, method));
  }

  Future<void> _export(
    List<InstalledApp> targets, {
    required String prompt,
    bool exitSelection = false,
    bool singlePath = false,
  }) async {
    if (targets.isEmpty || !mounted) return;
    final String? directory;
    try {
      directory = await pickExportDirectory(context, prompt);
    } catch (error, stackTrace) {
      log.severe('选择导出目录失败', error, stackTrace);
      if (!mounted) return;
      _show(
        AppNotice(
          title: context.l10n.appsExportTitle,
          message: '$error',
          isError: true,
        ),
      );
      return;
    }
    if (directory == null || !mounted) return;
    final future = controller.export(
      context.l10n,
      targets,
      directory,
      exitSelection: exitSelection,
      singlePath: singlePath,
    );
    await _showWhenDone(future, exportDialog: true);
  }

  void _openDetails(InstalledApp app) {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (context) => AppDetailsPage(serial: widget.serial, app: app),
        ),
      ),
    );
  }

  void _onAction(InstalledApp app, AppTileAction action) {
    switch (action) {
      case AppTileAction.details:
        _openDetails(app);
      case AppTileAction.permissions:
        unawaited(
          Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (context) =>
                  AppPermissionsPage(serial: widget.serial, app: app),
            ),
          ),
        );
      case AppTileAction.export:
        unawaited(
          _export(
            <InstalledApp>[app],
            prompt: context.l10n.appsExportPrompt(app.displayName),
            singlePath: true,
          ),
        );
      case AppTileAction.uninstall:
        unawaited(_uninstall(app));
      case AppTileAction.freeze:
        unawaited(_freeze(app));
      case AppTileAction.unfreeze:
        unawaited(_unfreeze(app));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final l10n = context.l10n;
      final theme = Theme.of(context);
      final visible = controller.visible;
      final currentTask = controller.task.value;
      final loadError = controller.error.value;
      controller.taskTick.value;
      return Column(
        children: <Widget>[
          AppsToolbar(
            serial: widget.serial,
            search: controller.search,
            filter: controller.filter.value,
            onFilter: controller.setFilter,
            selecting: controller.selecting.value,
            busy: controller.busy.value,
            loading: controller.loading.value,
            visibleCount: visible.length,
            markedCount: controller.selected.length,
            selectedCount: controller.selectedApps.length,
            onToggleSelecting: controller.toggleSelecting,
            onRefresh: () => controller.reload(),
            onSelectAll: controller.selectAllVisible,
            onClearSelection: controller.clearSelection,
            onExport: () => _export(
              controller.selectedApps,
              prompt: l10n.appsBatchExportPrompt(
                controller.selectedApps.length,
              ),
              exitSelection: true,
            ),
            onFreeze: () => _batchFreeze(),
            onUninstall: () => _batchUninstall(),
          ),
          if (currentTask != null && !currentTask.byBytes)
            AppTaskBar(task: currentTask, onCancel: controller.requestCancel),
          if (controller.loading.value && currentTask == null)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _body(
              l10n: l10n,
              theme: theme,
              visible: visible,
              loadError: loadError,
            ),
          ),
        ],
      );
    });
  }

  Widget _body({
    required FireAdbLocalizations l10n,
    required ThemeData theme,
    required List<InstalledApp> visible,
    required Object? loadError,
  }) {
    if (controller.loading.value) {
      return const Center(child: CircularProgressIndicator());
    }
    if (loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10n.appsLoadFailed(
              loadError is DeviceNotConnectedException
                  ? l10n.deviceOverviewNotConnected
                  : '$loadError',
            ),
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
      );
    }
    if (visible.isEmpty) {
      return Center(child: Text(l10n.appsEmpty));
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
      itemCount: visible.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final app = visible[index];
        controller.ensure(app);
        return AppListTile(
          app: app,
          icon: controller.iconOf(app.packageName),
          selecting: controller.selecting.value,
          selected: controller.selected.contains(app.packageName),
          busy: controller.busy.value,
          onToggleSelected: () => controller.toggleSelected(app),
          onStartSelecting: () => controller.startSelecting(app),
          onUnfreeze: () => _unfreeze(app),
          onOpen: () => _openDetails(app),
          onAction: (action) => _onAction(app, action),
        );
      },
    );
  }
}
