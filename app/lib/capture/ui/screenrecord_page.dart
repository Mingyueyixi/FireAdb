import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../files/android_storage_access.dart';
import '../../files/data/source/remote_file_commands.dart';
import '../../l10n/fire_adb_localizations_ext.dart';
import '../../l10n/generated/fire_adb_localizations.dart';
import '../../log/app_log.dart';
import '../capture_notice.dart';
import '../data/capture_paths.dart';
import '../data/capture_store.dart';
import '../data/local_opener.dart';
import '../screenrecord_controller.dart';
import 'capture_widgets.dart';

class ScreenrecordPage extends StatefulWidget {
  const ScreenrecordPage({super.key, required this.serial});

  final String serial;

  @override
  State<ScreenrecordPage> createState() => _ScreenrecordPageState();
}

class _ScreenrecordPageState extends State<ScreenrecordPage> {
  late final ScreenrecordController controller;

  @override
  void initState() {
    super.initState();
    controller = Get.put(
      ScreenrecordController(widget.serial),
      tag: widget.serial,
    );
    if (Platform.isAndroid) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_prepareDirectory());
      });
    }
  }

  Future<void> _prepareDirectory() async {
    if (!mounted) return;
    final granted = await ensureAllFilesAccess(context);
    if (!mounted) return;
    if (!granted) {
      controller.loading.value = false;
      return;
    }
    await controller.reload();
  }

  @override
  void dispose() {
    unawaited(
      Get.delete<ScreenrecordController>(tag: widget.serial, force: true),
    );
    super.dispose();
  }

  Future<void> _start() async {
    if (Platform.isAndroid) {
      final granted = await ensureAllFilesAccess(context);
      if (!granted || !mounted) return;
    }
    final l10n = context.l10n;
    final result = await controller.start(l10n);
    if (!mounted) return;
    if (result.notice != null) {
      showCaptureNotice(context, result.notice);
      return;
    }
    final finished = result.finished;
    if (finished == null) return;
    final notice = await finished;
    if (!mounted) return;
    showCaptureNotice(context, notice);
  }

  Future<void> _openDirectory() async {
    await _open(controller.directoryPath, openFile: false);
  }

  Future<void> _open(String path, {required bool openFile}) async {
    try {
      await openLocalPath(path, openFile: openFile);
    } catch (error, stackTrace) {
      log.severe('打开录像路径失败：$path', error, stackTrace);
      if (!mounted) return;
      showCaptureNotice(
        context,
        captureFailure(context.l10n, context.l10n.captureOpenFailed('$error')),
      );
    }
  }

  Future<void> _delete(CaptureFile file) async {
    final l10n = context.l10n;
    if (!await confirmDeleteCapture(context, file.name) || !mounted) return;
    final notice = await controller.remove(l10n, file);
    if (!mounted) return;
    showCaptureNotice(context, notice);
  }

  @override
  Widget build(BuildContext context) {
    if (!controller.hasDirectory) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            context.l10n.captureDirectoryUnavailable,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Obx(
          () => CaptureDirectoryBar(
            path: controller.directoryPath,
            enabled: !controller.saving.value,
            onOpen: () => unawaited(_openDirectory()),
            onRefresh: () => unawaited(controller.reload()),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Obx(() => _statusCard(context)),
              ),
              Obx(() {
                final saving = controller.saving.value;
                final files = <CaptureFile>[
                  for (final file in controller.files) file,
                ];
                final loadError = controller.loadError.value;
                if (controller.loading.value && files.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                return Column(
                  children: <Widget>[
                    if (loadError != null && files.isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Text(
                          '$loadError',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    CaptureFileList(
                      files: files,
                      emptyText: l10n.captureEmptyRecordings,
                      selectedPath: controller.selectedPath.value,
                      busy: saving,
                      icon: Icons.movie_outlined,
                      embedded: true,
                      onTap: (file) =>
                          unawaited(_open(file.path, openFile: true)),
                      onOpen: (file) =>
                          unawaited(_open(file.path, openFile: true)),
                      onDelete: (file) => unawaited(_delete(file)),
                    ),
                  ],
                );
              }),
            ],
          ),
        ),
      ],
    );
  }

  String _elapsedLabel(FireAdbLocalizations l10n) {
    final elapsed = formatElapsed(controller.elapsed.value);
    final limit = controller.timeLimitSeconds.value;
    if (limit == kUnlimitedScreenrecordSeconds) {
      return '$elapsed / ${l10n.screenrecordLimitNone}';
    }
    return '$elapsed / ${formatElapsed(Duration(seconds: limit))}';
  }

  String _methodTitle(FireAdbLocalizations l10n, ScreenRecordMethod value) {
    return switch (value) {
      ScreenRecordMethod.system => l10n.screenrecordMethodSystem,
      ScreenRecordMethod.builtin => l10n.screenrecordMethodBuiltin,
      ScreenRecordMethod.scrcpy => l10n.screenrecordMethodScrcpy,
    };
  }

  String _methodSubtitle(FireAdbLocalizations l10n, ScreenRecordMethod value) {
    return switch (value) {
      ScreenRecordMethod.system => l10n.screenrecordMethodSystemSubtitle,
      ScreenRecordMethod.builtin => l10n.screenrecordMethodBuiltinSubtitle,
      ScreenRecordMethod.scrcpy => l10n.screenrecordMethodScrcpySubtitle,
    };
  }

  String _timeLimitNote(FireAdbLocalizations l10n) {
    if (controller.method.value == ScreenRecordMethod.builtin) {
      return l10n.screenrecordTimeLimitBuiltin;
    }
    return controller.allowsUnlimited
        ? l10n.screenrecordTimeLimitUnlimited
        : l10n.screenrecordTimeLimitNote;
  }

  String _limitLabel(FireAdbLocalizations l10n, int seconds) {
    return switch (seconds) {
      30 => l10n.screenrecordLimit30,
      60 => l10n.screenrecordLimit60,
      180 => l10n.screenrecordLimit180,
      kUnlimitedScreenrecordSeconds => l10n.screenrecordLimitNone,
      _ => formatElapsed(Duration(seconds: seconds)),
    };
  }

  Widget _statusCard(BuildContext context) {
    final preparing = controller.preparing.value;
    final recording = controller.recording.value;
    final saving = controller.saving.value;
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final idle = !preparing && !recording && !saving;
    final showStop = preparing || recording;
    final total = controller.bytesTotal.value;
    final progress = total <= 0
        ? null
        : (controller.bytesDone.value / total).clamp(0, 1).toDouble();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  recording ? Icons.fiber_manual_record : Icons.videocam,
                  color: recording ? scheme.error : scheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  recording
                      ? l10n.screenrecordRecording
                      : l10n.workspaceScreenrecordTitle,
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (recording)
              Text(_elapsedLabel(l10n), style: theme.textTheme.headlineMedium)
            else if (!saving)
              Text(
                l10n.screenrecordHint,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            if (saving) ...<Widget>[
              Text(l10n.screenrecordSaving, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: progress),
              if (total > 0) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  '${formatFileSize(controller.bytesDone.value)} / ${formatFileSize(total)}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
            const SizedBox(height: 12),
            Text(l10n.screenrecordMethod, style: theme.textTheme.labelLarge),
            RadioGroup<ScreenRecordMethod>(
              groupValue: controller.method.value,
              onChanged: idle
                  ? (value) {
                      if (value != null) controller.setMethod(value);
                    }
                  : (_) {},
              child: Column(
                children: <Widget>[
                  for (final value in ScreenRecordMethod.values)
                    RadioListTile<ScreenRecordMethod>(
                      value: value,
                      enabled: idle && value != ScreenRecordMethod.scrcpy,
                      contentPadding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      title: Text(_methodTitle(l10n, value)),
                      subtitle: Text(_methodSubtitle(l10n, value)),
                    ),
                ],
              ),
            ),
            if (idle) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                l10n.screenrecordTimeLimit,
                style: theme.textTheme.labelLarge,
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: <ButtonSegment<int>>[
                    for (final seconds in controller.timeLimitChoices)
                      ButtonSegment<int>(
                        value: seconds,
                        label: Text(_limitLabel(l10n, seconds)),
                      ),
                  ],
                  selected: <int>{controller.timeLimitSeconds.value},
                  onSelectionChanged: (selection) =>
                      controller.setTimeLimit(selection.first),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _timeLimitNote(l10n),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: saving
                  ? null
                  : showStop
                  ? () => unawaited(controller.stop())
                  : () => unawaited(_start()),
              style: showStop
                  ? FilledButton.styleFrom(
                      backgroundColor: scheme.error,
                      foregroundColor: scheme.onError,
                    )
                  : null,
              icon: preparing || saving
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: showStop ? scheme.onError : scheme.onPrimary,
                      ),
                    )
                  : Icon(showStop ? Icons.stop : Icons.fiber_manual_record),
              label: Text(
                saving
                    ? l10n.screenrecordSaving
                    : showStop
                    ? l10n.screenrecordStop
                    : l10n.screenrecordStart,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
