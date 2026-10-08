import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:get/get.dart';

import '../app_feedback.dart';
import '../connection/connection_manager.dart';
import '../l10n/generated/fire_adb_localizations.dart';
import 'capture_notice.dart';
import 'data/capture_paths.dart';
import 'data/capture_store.dart';

/// 截取设备屏幕，并把 PNG 保存到下载目录。
class ScreenshotController extends GetxController {
  ScreenshotController(this.serial, {CaptureStore? store})
    : _store = store ?? CaptureStore.tryOpen();

  final String serial;
  final CaptureStore? _store;

  final RxBool loading = true.obs;
  final RxBool busy = false.obs;
  final RxList<CaptureFile> files = <CaptureFile>[].obs;
  final Rxn<String> selectedPath = Rxn<String>();
  final Rxn<Object> loadError = Rxn<Object>();

  bool get hasDirectory => _store != null;

  String get directoryPath => _store?.directory.path ?? '';

  @override
  void onInit() {
    super.onInit();
    if (Platform.isAndroid) return;
    unawaited(reload());
  }

  Future<void> reload({String? prefer}) async {
    final store = _store;
    if (store == null || isClosed) return;
    try {
      await store.ensure();
      final listed = await store.list(extension: 'png');
      if (isClosed) return;
      final own = <CaptureFile>[
        for (final file in listed)
          if (captureFileMatchesDevice(file.name, serial)) file,
      ];
      files.assignAll(own);
      _syncSelection(own, prefer: prefer, selectNewest: prefer == null);
      loadError.value = null;
    } catch (error, stackTrace) {
      logAppError('读取截图列表失败：$serial', error, stackTrace);
      if (!isClosed) loadError.value = error;
    } finally {
      if (!isClosed) loading.value = false;
    }
  }

  Future<CaptureNotice?> capture(FireAdbLocalizations l10n) async {
    if (busy.value) return null;
    final store = _store;
    final device = Get.find<ConnectionManager>().deviceOf(serial);
    if (device == null) return deviceNotConnectedNotice(l10n);
    if (store == null) return directoryUnavailableNotice(l10n);
    busy.value = true;
    try {
      final bytes = await device
          .execOut(kScreencapCommand)
          .timeout(const Duration(seconds: 30));
      if (!looksLikePng(bytes)) {
        final output = briefDeviceOutput(
          utf8.decode(bytes, allowMalformed: true),
        );
        return captureFailure(
          l10n,
          output.isEmpty
              ? l10n.screenshotInvalid
              : l10n.captureDeviceOutput(output),
        );
      }
      final name = captureFileName(
        prefix: 'screenshot',
        time: DateTime.now(),
        serial: serial,
        extension: 'png',
      );
      final file = await store.write(name, bytes);
      await reload(prefer: file.path);
      return captureSavedNotice(
        l10n,
        file.path,
        title: l10n.workspaceScreenshotTitle,
      );
    } catch (error, stackTrace) {
      logAppError('截图失败：$serial', error, stackTrace);
      return captureFailure(l10n, '$error');
    } finally {
      if (!isClosed) busy.value = false;
    }
  }

  Future<CaptureNotice?> remove(
    FireAdbLocalizations l10n,
    CaptureFile file,
  ) async {
    if (busy.value) return null;
    final store = _store;
    if (store == null) return directoryUnavailableNotice(l10n);
    try {
      await store.deleteFile(file);
      if (selectedPath.value == file.path) selectedPath.value = null;
      await reload();
      return CaptureNotice(
        title: l10n.captureDelete,
        message: l10n.captureDeleted(file.name),
      );
    } catch (error, stackTrace) {
      logAppError('删除截图失败：${file.path}', error, stackTrace);
      return captureFailure(l10n, '$error');
    }
  }

  void select(String path) => selectedPath.value = path;

  void _syncSelection(
    List<CaptureFile> listed, {
    required String? prefer,
    required bool selectNewest,
  }) {
    if (prefer != null) {
      selectedPath.value = prefer;
      return;
    }
    final selected = selectedPath.value;
    if (selected != null && listed.any((file) => file.path == selected)) {
      return;
    }
    selectedPath.value = selectNewest && listed.isNotEmpty
        ? listed.first.path
        : null;
  }
}
