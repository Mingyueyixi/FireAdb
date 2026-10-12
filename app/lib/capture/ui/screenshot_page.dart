import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../files/android_storage_access.dart';
import '../../l10n/fire_adb_localizations_ext.dart';
import '../../log/app_log.dart';
import '../capture_notice.dart';
import '../data/capture_store.dart';
import '../data/local_opener.dart';
import '../screenshot_controller.dart';
import 'capture_widgets.dart';

class ScreenshotPage extends StatefulWidget {
  const ScreenshotPage({super.key, required this.serial});

  final String serial;

  @override
  State<ScreenshotPage> createState() => _ScreenshotPageState();
}

class _ScreenshotPageState extends State<ScreenshotPage> {
  late final ScreenshotController controller;

  @override
  void initState() {
    super.initState();
    controller = Get.put(
      ScreenshotController(widget.serial),
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
      Get.delete<ScreenshotController>(tag: widget.serial, force: true),
    );
    super.dispose();
  }

  Future<void> _capture() async {
    if (Platform.isAndroid) {
      final granted = await ensureAllFilesAccess(context);
      if (!granted || !mounted) return;
    }
    final l10n = context.l10n;
    final notice = await controller.capture(l10n);
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
      log.severe('打开截图路径失败：$path', error, stackTrace);
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
    return Obx(() {
      final busy = controller.busy.value;
      final preview = controller.selectedPath.value;
      final loadError = controller.loadError.value;
      final files = <CaptureFile>[for (final file in controller.files) file];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          CaptureDirectoryBar(
            path: controller.directoryPath,
            enabled: !busy,
            onOpen: () => unawaited(_openDirectory()),
            onRefresh: () => unawaited(controller.reload()),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: busy ? null : () => unawaited(_capture()),
                icon: busy
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Theme.of(context).colorScheme.onPrimary,
                        ),
                      )
                    : const Icon(Icons.screenshot_monitor),
                label: Text(
                  busy ? l10n.screenshotCapturing : l10n.screenshotCapture,
                ),
              ),
            ),
          ),
          if (preview != null)
            Expanded(flex: 3, child: _preview(context, preview)),
          if (loadError != null && files.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '$loadError',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: controller.loading.value && files.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : CaptureFileList(
                    files: files,
                    emptyText: l10n.captureEmptyScreenshots,
                    selectedPath: preview,
                    busy: busy,
                    icon: Icons.image_outlined,
                    onTap: (file) => controller.select(file.path),
                    onOpen: (file) =>
                        unawaited(_open(file.path, openFile: true)),
                    onDelete: (file) => unawaited(_delete(file)),
                  ),
          ),
        ],
      );
    });
  }

  Widget _preview(BuildContext context, String path) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.file(
            File(path),
            key: ValueKey<String>(path),
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) {
              return Center(
                child: Icon(Icons.broken_image_outlined, color: scheme.outline),
              );
            },
          ),
        ),
      ),
    );
  }
}
