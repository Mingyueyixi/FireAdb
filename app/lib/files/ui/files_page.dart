import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../app_feedback.dart';
import '../../l10n/fire_adb_localizations_ext.dart';
import '../../l10n/generated/fire_adb_localizations.dart';
import '../../log/app_log.dart';
import '../data/bean/remote_file.dart';
import '../data/source/remote_file_commands.dart';
import '../files_controller.dart';
import '../local_file_picker.dart';
import 'file_dialogs.dart';
import 'file_list_tile.dart';
import 'file_task_view.dart';
import 'files_toolbar.dart';

class FilesPage extends StatefulWidget {
  const FilesPage({super.key, required this.serial});

  final String serial;

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  late final FilesController controller;

  @override
  void initState() {
    super.initState();
    controller = Get.put(FilesController(widget.serial), tag: widget.serial);
  }

  @override
  void dispose() {
    unawaited(Get.delete<FilesController>(tag: widget.serial, force: true));
    super.dispose();
  }

  void _show(FileNotice? notice) {
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
    Future<FileNotice?> future, {
    bool transferDialog = false,
  }) async {
    if (transferDialog && controller.task.value?.byBytes == true && mounted) {
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (context) => FileTransferDialog(controller: controller),
        ),
      );
    }
    _show(await future);
  }

  Future<void> _export(List<RemoteFile> files) async {
    if (files.isEmpty || !mounted) return;
    final l10n = context.l10n;
    final prompt = files.length == 1
        ? l10n.filesExportPrompt(files.first.name)
        : l10n.filesBatchExportPrompt(files.length);
    final String? directory;
    try {
      directory = await pickExportDirectory(context, prompt);
    } catch (error, stackTrace) {
      log.severe('选择导出目录失败', error, stackTrace);
      if (!mounted) return;
      _show(
        FileNotice(title: l10n.filesExport, message: '$error', isError: true),
      );
      return;
    }
    if (directory == null || !mounted) return;
    final future = controller.export(l10n, files, directory);
    await _showWhenDone(future, transferDialog: true);
  }

  Future<void> _upload() async {
    final l10n = context.l10n;
    final List<String> paths;
    try {
      paths = await pickLocalFiles(context);
    } catch (error, stackTrace) {
      log.severe('选择上传文件失败', error, stackTrace);
      if (!mounted) return;
      _show(
        FileNotice(title: l10n.filesUpload, message: '$error', isError: true),
      );
      return;
    }
    if (paths.isEmpty || !mounted) return;
    final names = paths.map(_localName).toList();
    final existing = names
        .where((name) => controller.entries.any((entry) => entry.name == name))
        .toList();
    if (existing.isNotEmpty) {
      final confirmed = await confirmOverwrite(context, existing.join(', '));
      if (!confirmed || !mounted) return;
    }
    final future = controller.upload(l10n, paths);
    await _showWhenDone(future, transferDialog: true);
  }

  Future<void> _delete(List<RemoteFile> files) async {
    if (files.isEmpty || !mounted) return;
    final confirmed = await confirmDeleteFiles(
      context,
      name: files.length == 1 ? files.first.name : null,
      count: files.length,
    );
    if (!confirmed || !mounted) return;
    await _showWhenDone(controller.remove(context.l10n, files));
  }

  Future<void> _rename(RemoteFile file) async {
    final name = await askRemoteName(
      context,
      title: context.l10n.filesRename,
      action: context.l10n.filesRename,
      initial: file.name,
    );
    if (name == null || !mounted) return;
    await _showWhenDone(controller.rename(context.l10n, file, name));
  }

  Future<void> _create() async {
    final created = await askCreateEntry(context);
    if (created == null || !mounted) return;
    await _showWhenDone(
      controller.create(
        context.l10n,
        name: created.name,
        directory: created.directory,
      ),
    );
  }

  Future<void> _permission(List<RemoteFile> files) async {
    if (files.isEmpty || !mounted) return;
    final current = files.length == 1 ? formatPermission(files.first.mode) : '';
    final mode = await askPermission(context, current);
    if (mode == null || !mounted) return;
    await _showWhenDone(controller.changeMode(context.l10n, files, mode));
  }

  Future<void> _edit(RemoteFile file) async {
    final l10n = context.l10n;
    final result = await controller.readText(file);
    if (!mounted || result == null) return;
    switch (result.reject) {
      case TextReject.tooLarge:
        _show(
          FileNotice(
            title: l10n.filesEdit,
            message: l10n.filesEditTooLarge,
            isError: true,
          ),
        );
        return;
      case TextReject.binary:
        _show(
          FileNotice(
            title: l10n.filesEdit,
            message: l10n.filesEditBinary,
            isError: true,
          ),
        );
        return;
      case TextReject.directory:
        return;
      case null:
        break;
    }
    final text = await editRemoteText(
      context,
      name: file.name,
      text: result.text ?? '',
    );
    if (text == null || !mounted) return;
    await _showWhenDone(controller.writeText(l10n, file, text));
  }

  Future<void> _search() async {
    final keyword = await askSearchKeyword(context);
    if (keyword == null || !mounted) return;
    await controller.search(keyword);
  }

  void _hold(RemoteFile file, {required bool cut}) {
    controller.clipboard.value = FileClipboard(
      files: <RemoteFile>[file],
      cut: cut,
    );
    final l10n = context.l10n;
    _show(
      FileNotice(
        title: cut ? l10n.filesCut : l10n.filesCopy,
        message: cut ? l10n.filesClipboardCut(1) : l10n.filesClipboardCopied(1),
      ),
    );
  }

  void _onAction(RemoteFile file, FileTileAction action) {
    switch (action) {
      case FileTileAction.open:
        unawaited(controller.open(file.path));
      case FileTileAction.export:
        unawaited(_export(<RemoteFile>[file]));
      case FileTileAction.rename:
        unawaited(_rename(file));
      case FileTileAction.copy:
        _hold(file, cut: false);
      case FileTileAction.cut:
        _hold(file, cut: true);
      case FileTileAction.edit:
        unawaited(_edit(file));
      case FileTileAction.permission:
        unawaited(_permission(<RemoteFile>[file]));
      case FileTileAction.delete:
        unawaited(_delete(<RemoteFile>[file]));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final l10n = context.l10n;
      final theme = Theme.of(context);
      final currentTask = controller.task.value;
      final loadError = controller.error.value;
      final searching = controller.searching;
      controller.taskTick.value;
      final visible = controller.entries.toList();
      return Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: controller.pathInput,
                    decoration: InputDecoration(
                      isDense: true,
                      border: const OutlineInputBorder(),
                      labelText: l10n.filesPath,
                    ),
                    onSubmitted: (value) => controller.open(value),
                  ),
                ),
                IconButton(
                  tooltip: l10n.filesUp,
                  onPressed: controller.busy.value
                      ? null
                      : () => controller.up(),
                  icon: const Icon(Icons.arrow_upward),
                ),
                IconButton(
                  tooltip: l10n.filesRefresh,
                  onPressed: controller.busy.value
                      ? null
                      : () => controller.reload(),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: <Widget>[
                ActionChip(
                  label: Text(l10n.filesLocationsStorage),
                  onPressed: () => controller.open(remoteStoragePath),
                ),
                const SizedBox(width: 8),
                ActionChip(
                  label: Text(l10n.filesLocationsTemp),
                  onPressed: () => controller.open(remoteTempPath),
                ),
                const SizedBox(width: 8),
                ActionChip(
                  label: Text(l10n.filesLocationsRoot),
                  onPressed: () => controller.open('/'),
                ),
              ],
            ),
          ),
          FilesToolbar(
            selecting: controller.selecting.value,
            busy: controller.busy.value,
            searching: searching,
            canPaste: controller.clipboard.value != null,
            selectedCount: controller.selectedFiles.length,
            onUpload: () => unawaited(_upload()),
            onCreate: () => unawaited(_create()),
            onSearch: () => unawaited(_search()),
            onClearSearch: () => controller.open(controller.path.value),
            onToggleSelecting: controller.toggleSelecting,
            onSelectAll: controller.selectAllVisible,
            onExport: () => unawaited(_export(controller.selectedFiles)),
            onDelete: () => unawaited(_delete(controller.selectedFiles)),
            onCopy: () {
              controller.copySelected(cut: false);
              _show(
                FileNotice(
                  title: l10n.filesCopy,
                  message: l10n.filesClipboardCopied(
                    controller.selectedFiles.length,
                  ),
                ),
              );
            },
            onCut: () {
              controller.copySelected(cut: true);
              _show(
                FileNotice(
                  title: l10n.filesCut,
                  message: l10n.filesClipboardCut(controller.selected.length),
                ),
              );
            },
            onPaste: () => unawaited(_showWhenDone(controller.paste(l10n))),
            onPermission: () =>
                unawaited(_permission(controller.selectedFiles)),
          ),
          if (searching)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  l10n.filesSearching(controller.keyword.value),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          if (currentTask != null && !currentTask.byBytes)
            FileTaskBar(task: currentTask, onCancel: controller.requestCancel),
          if (controller.loading.value && currentTask == null)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _body(
              l10n: l10n,
              theme: theme,
              visible: visible,
              searching: searching,
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
    required List<RemoteFile> visible,
    required bool searching,
    required Object? loadError,
  }) {
    if (controller.loading.value && visible.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (loadError != null && visible.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10n.filesLoadFailed(
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
      return Center(
        child: Text(searching ? l10n.filesSearchEmpty : l10n.filesEmpty),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
      itemCount: visible.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final file = visible[index];
        return FileListTile(
          file: file,
          showPath: searching,
          selecting: controller.selecting.value,
          selected: controller.selected.contains(file.path),
          busy: controller.busy.value,
          onToggleSelected: () => controller.toggleSelected(file),
          onStartSelecting: () => controller.startSelecting(file),
          onTap: () {
            if (controller.selecting.value) {
              controller.toggleSelected(file);
              return;
            }
            if (file.canEnter) unawaited(controller.open(file.path));
          },
          onAction: (action) => _onAction(file, action),
        );
      },
    );
  }
}

String _localName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  if (slash < 0 || slash == normalized.length - 1) return path;
  return normalized.substring(slash + 1);
}
