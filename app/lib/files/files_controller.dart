import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../connection/connection_manager.dart';
import '../l10n/generated/fire_adb_localizations.dart';
import '../log/app_log.dart';
import 'data/bean/remote_file.dart';
import 'data/repo/device_file_repository.dart';
import 'data/source/remote_file_commands.dart';

class FileNotice {
  const FileNotice({
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

enum TextReject { tooLarge, binary, directory }

class TextReadResult {
  const TextReadResult.ok(this.text) : reject = null;

  const TextReadResult.reject(this.reject) : text = null;

  final String? text;
  final TextReject? reject;
}

class FileClipboard {
  const FileClipboard({required this.files, required this.cut});

  final List<RemoteFile> files;
  final bool cut;
}

class FileTask {
  FileTask({required this.label, required this.total, this.byBytes = false});

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

/// 一台设备上的文件浏览器。
class FilesController extends GetxController {
  FilesController(this.serial);

  final String serial;
  final TextEditingController pathInput = TextEditingController(
    text: remoteStoragePath,
  );

  final RxString path = remoteStoragePath.obs;
  final RxString keyword = ''.obs;
  final RxList<RemoteFile> entries = <RemoteFile>[].obs;
  final RxBool loading = true.obs;
  final RxBool busy = false.obs;
  final RxBool selecting = false.obs;
  final RxSet<String> selected = <String>{}.obs;
  final Rxn<Object> error = Rxn<Object>();
  final Rxn<FileClipboard> clipboard = Rxn<FileClipboard>();
  final Rxn<FileTask> task = Rxn<FileTask>();
  final RxInt taskTick = 0.obs;

  DeviceFileRepository? _activeRepo;
  DeviceFileRepository? _listRepo;
  DateTime _progressUiAt = DateTime.fromMillisecondsSinceEpoch(0);
  var _generation = 0;
  var _closed = false;

  ConnectionManager get _manager => Get.find<ConnectionManager>();

  bool get searching {
    keyword.value;
    return keyword.value.trim().isNotEmpty;
  }

  List<RemoteFile> get selectedFiles {
    entries.length;
    selected.length;
    return entries.where((file) => selected.contains(file.path)).toList();
  }

  @override
  void onInit() {
    super.onInit();
    unawaited(reload());
  }

  @override
  void onClose() {
    _generation++;
    _closed = true;
    unawaited(_listRepo?.abort());
    unawaited(_activeRepo?.abort());
    pathInput.dispose();
    super.onClose();
  }

  DeviceFileRepository? _repository() {
    final device = _manager.deviceOf(serial);
    if (device == null) return null;
    final profile = _manager.profileOf(serial);
    return DeviceFileRepository(
      device,
      host: profile?.host,
      adbSerial: profile?.adbSerial,
    );
  }

  Future<void> reload() => open(path.value);

  Future<void> open(String nextPath) async {
    final generation = ++_generation;
    final target = normalizeRemotePath(nextPath);
    keyword.value = '';
    path.value = target;
    pathInput.text = target;
    await _load(generation, target);
  }

  Future<void> up() {
    if (searching) return open(path.value);
    return open(parentRemotePath(path.value));
  }

  Future<void> search(String value) async {
    final generation = ++_generation;
    keyword.value = value.trim();
    await _load(generation, path.value);
  }

  Future<void> _load(int generation, String directory) async {
    await _listRepo?.abort();
    final repo = _repository();
    _listRepo = repo;
    loading.value = true;
    error.value = null;
    if (repo == null) {
      loading.value = false;
      entries.clear();
      error.value = const DeviceNotConnectedException();
      return;
    }
    try {
      final query = keyword.value.trim();
      final loaded = query.isEmpty
          ? await repo.list(directory)
          : await repo.search(directory, query);
      if (_closed || generation != _generation) return;
      entries.assignAll(loaded);
      selected.removeWhere((item) => !loaded.any((file) => file.path == item));
      loading.value = false;
    } catch (loadError, stackTrace) {
      log.severe('读取目录失败：$directory', loadError, stackTrace);
      if (_closed || generation != _generation) return;
      loading.value = false;
      if (loadError is! FileOperationCancelled) error.value = loadError;
    }
  }

  void toggleSelecting() {
    selecting.value = !selecting.value;
    if (!selecting.value) selected.clear();
  }

  void startSelecting(RemoteFile file) {
    selecting.value = true;
    selected.add(file.path);
  }

  void toggleSelected(RemoteFile file) {
    if (selected.contains(file.path)) {
      selected.remove(file.path);
    } else {
      selected.add(file.path);
    }
  }

  void selectAllVisible() {
    selected.addAll(entries.map((file) => file.path));
  }

  void clearSelection() => selected.clear();

  void copySelected({required bool cut}) {
    final files = selectedFiles;
    if (files.isEmpty) return;
    clipboard.value = FileClipboard(files: files, cut: cut);
  }

  Future<TextReadResult?> readText(RemoteFile file) async {
    final repo = _repository();
    if (repo == null) return null;
    if (file.canEnter) {
      return const TextReadResult.reject(TextReject.directory);
    }
    try {
      final bytes = await repo.readBytes(
        file.path,
        maxBytes: remoteTextEditLimit,
      );
      if (looksLikeBinary(bytes)) {
        return const TextReadResult.reject(TextReject.binary);
      }
      return TextReadResult.ok(utf8.decode(bytes));
    } on StateError {
      return const TextReadResult.reject(TextReject.tooLarge);
    }
  }

  Future<FileNotice?> writeText(
    FireAdbLocalizations l10n,
    RemoteFile file,
    String text,
  ) {
    final mode = file.mode == 0 ? 0x81a4 : (file.mode & 0x1ff) | 0x8000;
    return _runTask(
      l10n: l10n,
      label: l10n.filesTaskSave,
      total: 1,
      action: () async {
        final repo = _repository();
        if (repo == null) throw const DeviceNotConnectedException();
        _activeRepo = repo;
        await repo.writeBytes(file.path, utf8.encode(text), mode: mode);
        await reload();
        return FileNotice(title: l10n.filesEdit, message: l10n.filesSaved);
      },
    );
  }

  Future<FileNotice?> remove(
    FireAdbLocalizations l10n,
    List<RemoteFile> files,
  ) {
    return _runCounted(
      l10n: l10n,
      label: l10n.filesTaskDelete,
      files: files,
      title: l10n.filesDelete,
      success: (count) => l10n.filesDeleted(count),
      action: (repo, file) => repo.remove(<String>[file.path]),
    );
  }

  Future<FileNotice?> rename(
    FireAdbLocalizations l10n,
    RemoteFile file,
    String name,
  ) {
    if (!isSafeRemoteName(name)) {
      return Future<FileNotice?>.value(
        FileNotice(
          title: l10n.filesRename,
          message: l10n.filesInvalidName,
          isError: true,
        ),
      );
    }
    return _runTask(
      l10n: l10n,
      label: l10n.filesTaskRename,
      total: 1,
      action: () async {
        final repo = _repository();
        if (repo == null) throw const DeviceNotConnectedException();
        _activeRepo = repo;
        await repo.rename(
          file.path,
          joinRemotePath(parentRemotePath(file.path), name),
        );
        await reload();
        return FileNotice(title: l10n.filesRename, message: l10n.filesRenamed);
      },
    );
  }

  Future<FileNotice?> create(
    FireAdbLocalizations l10n, {
    required String name,
    required bool directory,
  }) {
    if (!isSafeRemoteName(name)) {
      return Future<FileNotice?>.value(
        FileNotice(
          title: l10n.filesCreate,
          message: l10n.filesInvalidName,
          isError: true,
        ),
      );
    }
    final target = joinRemotePath(path.value, name);
    return _runTask(
      l10n: l10n,
      label: l10n.filesCreate,
      total: 1,
      action: () async {
        final repo = _repository();
        if (repo == null) throw const DeviceNotConnectedException();
        _activeRepo = repo;
        if (directory) {
          await repo.createDirectory(target);
        } else {
          await repo.createFile(target);
        }
        await reload();
        return FileNotice(
          title: l10n.filesCreate,
          message: l10n.filesCreated(name),
        );
      },
    );
  }

  Future<FileNotice?> changeMode(
    FireAdbLocalizations l10n,
    List<RemoteFile> files,
    String mode,
  ) {
    if (normalizeChmod(mode) == null) {
      return Future<FileNotice?>.value(
        FileNotice(
          title: l10n.filesPermission,
          message: l10n.filesInvalidPermission,
          isError: true,
        ),
      );
    }
    return _runTask(
      l10n: l10n,
      label: l10n.filesPermission,
      total: 1,
      action: () async {
        final repo = _repository();
        if (repo == null) throw const DeviceNotConnectedException();
        _activeRepo = repo;
        await repo.chmod(files.map((file) => file.path), mode);
        await reload();
        return FileNotice(
          title: l10n.filesPermission,
          message: l10n.filesPermissionUpdated,
        );
      },
    );
  }

  Future<FileNotice?> paste(FireAdbLocalizations l10n) {
    final held = clipboard.value;
    if (held == null || held.files.isEmpty) return Future<FileNotice?>.value();
    final destination = path.value;
    for (final file in held.files) {
      if (file.canEnter &&
          (destination == file.path ||
              destination.startsWith('${file.path}/'))) {
        return Future<FileNotice?>.value(
          FileNotice(
            title: l10n.filesPaste,
            message: l10n.filesPasteIntoSelf,
            isError: true,
          ),
        );
      }
    }
    return _runTask(
      l10n: l10n,
      label: held.cut ? l10n.filesTaskMove : l10n.filesTaskCopy,
      total: held.files.length,
      action: () async {
        final repo = _repository();
        if (repo == null) throw const DeviceNotConnectedException();
        _activeRepo = repo;
        final sources = held.files.map((file) => file.path);
        if (held.cut) {
          await repo.moveTo(sources, destination);
          clipboard.value = null;
        } else {
          await repo.copyTo(sources, destination);
        }
        await reload();
        return FileNotice(
          title: l10n.filesPaste,
          message: l10n.filesPasted(held.files.length),
        );
      },
    );
  }

  Future<FileNotice?> export(
    FireAdbLocalizations l10n,
    List<RemoteFile> files,
    String directory,
  ) {
    return _runTask(
      l10n: l10n,
      label: l10n.filesTaskExport,
      total: files.length,
      modal: true,
      action: () => _performExport(l10n, files, directory),
    );
  }

  Future<FileNotice?> upload(
    FireAdbLocalizations l10n,
    List<String> localPaths,
  ) {
    return _runTask(
      l10n: l10n,
      label: l10n.filesTaskUpload,
      total: localPaths.length,
      modal: true,
      action: () => _performUpload(l10n, localPaths),
    );
  }

  Future<FileNotice?> _performExport(
    FireAdbLocalizations l10n,
    List<RemoteFile> files,
    String directory,
  ) async {
    final repo = _repository();
    if (repo == null) throw const DeviceNotConnectedException();
    _activeRepo = repo;
    final current = task.value;
    if (current != null) {
      current.measuring = true;
      current.currentName = files.isEmpty ? '' : files.first.name;
      _publish(force: true);
    }
    late final List<RemoteExportPiece> pieces;
    try {
      pieces = await repo.planExport(files);
    } on FileOperationCancelled {
      return FileNotice(
        title: l10n.filesExport,
        message: l10n.appsTaskCancelled,
      );
    }
    final bytesTotal = pieces.fold<int>(
      0,
      (sum, piece) => sum + (piece.directory ? 0 : piece.size),
    );
    if (current != null) {
      current.measuring = false;
      current.bytesTotal = bytesTotal;
      _publish(force: true);
    }
    var sent = 0;
    try {
      await repo.exportPieces(
        pieces,
        directory,
        isCancelled: () => task.value?.cancelRequested ?? false,
        onProgress: (done, _) {
          if (current == null) return;
          sent = done > bytesTotal ? bytesTotal : done;
          current.bytesDone = sent;
          final piece = _pieceAt(pieces, sent);
          if (piece != null) {
            current.currentName = remoteBaseName(piece.remotePath);
          }
          _publish();
        },
      );
    } on FileOperationCancelled {
      return FileNotice(
        title: l10n.filesExport,
        message: l10n.appsTaskCancelled,
      );
    }
    if (current != null) {
      current.bytesDone = bytesTotal;
      current.completed = files.length;
      _publish(force: true);
    }
    selecting.value = false;
    selected.clear();
    return FileNotice(
      title: l10n.filesExport,
      message: l10n.filesExportSucceeded(directory),
    );
  }

  Future<FileNotice?> _performUpload(
    FireAdbLocalizations l10n,
    List<String> localPaths,
  ) async {
    final repo = _repository();
    if (repo == null) throw const DeviceNotConnectedException();
    _activeRepo = repo;
    final current = task.value;
    final files = localPaths.map(File.new).toList();
    var total = 0;
    for (final file in files) {
      total += await file.length();
    }
    if (current != null) {
      current.bytesTotal = total;
      _publish(force: true);
    }
    var sentBase = 0;
    for (final file in files) {
      if (task.value?.cancelRequested == true) {
        return FileNotice(
          title: l10n.filesUpload,
          message: l10n.appsTaskCancelled,
        );
      }
      final name = file.uri.pathSegments.isEmpty
          ? file.path
          : file.uri.pathSegments.last;
      if (!isSafeRemoteName(name)) {
        throw StateError(l10n.filesInvalidName);
      }
      if (current != null) {
        current.currentName = name;
        _publish(force: true);
      }
      final remote = joinRemotePath(path.value, name);
      final length = await file.length();
      try {
        await repo.uploadFile(
          file,
          remote,
          isCancelled: () => task.value?.cancelRequested ?? false,
          onProgress: (done, _) {
            if (current == null) return;
            final next = sentBase + done;
            current.bytesDone = next > total ? total : next;
            _publish();
          },
        );
      } on FileOperationCancelled {
        return FileNotice(
          title: l10n.filesUpload,
          message: l10n.appsTaskCancelled,
        );
      }
      sentBase += length;
      if (current != null) {
        current.bytesDone = sentBase > total ? total : sentBase;
        current.completed++;
        _publish(force: true);
      }
    }
    await reload();
    return FileNotice(
      title: l10n.filesUpload,
      message: l10n.filesUploadSucceeded(files.length),
    );
  }

  Future<FileNotice?> _runCounted({
    required FireAdbLocalizations l10n,
    required String label,
    required List<RemoteFile> files,
    required String title,
    required String Function(int count) success,
    required Future<void> Function(DeviceFileRepository repo, RemoteFile file)
    action,
  }) {
    return _runTask(
      l10n: l10n,
      label: label,
      total: files.length,
      action: () async {
        final repo = _repository();
        if (repo == null) throw const DeviceNotConnectedException();
        _activeRepo = repo;
        var done = 0;
        for (final file in files) {
          if (task.value?.cancelRequested == true) {
            return FileNotice(
              title: title,
              message: done == 0
                  ? l10n.appsTaskCancelled
                  : l10n.appsTaskCancelledDone(done),
            );
          }
          final current = task.value;
          if (current != null) {
            current.currentName = file.name;
            _publish(force: true);
          }
          await action(repo, file);
          done++;
          if (current != null) {
            current.completed = done;
            _publish(force: true);
          }
        }
        await reload();
        selecting.value = false;
        selected.clear();
        return FileNotice(title: title, message: success(done));
      },
    );
  }

  Future<FileNotice?> _runTask({
    required FireAdbLocalizations l10n,
    required String label,
    required int total,
    required Future<FileNotice?> Function() action,
    bool modal = false,
  }) async {
    if (busy.value) return null;
    busy.value = true;
    task.value = FileTask(label: label, total: total, byBytes: modal);
    _publish(force: true);
    try {
      return await action();
    } on FileOperationCancelled {
      if (_closed) return null;
      return FileNotice(title: label, message: l10n.appsTaskCancelled);
    } catch (taskError, stackTrace) {
      log.severe('文件管理操作失败：$serial', taskError, stackTrace);
      if (_closed) return null;
      return FileNotice(
        title: l10n.filesActionFailed,
        message: taskError is DeviceNotConnectedException
            ? l10n.deviceOverviewNotConnected
            : '$taskError',
        isError: true,
      );
    } finally {
      _activeRepo = null;
      if (!_closed) {
        busy.value = false;
        task.value = null;
        _publish(force: true);
      }
    }
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

  RemoteExportPiece? _pieceAt(List<RemoteExportPiece> pieces, int bytesDone) {
    var cursor = 0;
    for (final piece in pieces) {
      if (piece.directory) continue;
      cursor += piece.size;
      if (cursor >= bytesDone) return piece;
    }
    return pieces.isEmpty ? null : pieces.last;
  }
}
