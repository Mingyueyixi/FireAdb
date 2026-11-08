import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../l10n/generated/fireadb_localizations.dart';
import '../log/app_log.dart';
import 'data/repo/device_file_repository.dart';
import 'data/source/remote_file_commands.dart';
import 'file_backend.dart';
import 'file_entry.dart';
import 'local_file_backend.dart';
import 'remote_file.dart';
import 'remote_file_backend.dart';

export 'file_backend.dart' show DeviceNotConnectedException;

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

enum TextReject { tooLarge, binary, directory }

class TextReadResult {
  const TextReadResult.ok(this.text) : reject = null;

  const TextReadResult.reject(this.reject) : text = null;

  final String? text;
  final TextReject? reject;
}

class FileClipboard {
  const FileClipboard({required this.files, required this.cut});

  final List<FileEntry> files;
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

/// 一个文件浏览器。[root] 不为空时不能走到该目录外面。
/// 经由 [FileBackend] 驱动：设备走 ADB（[RemoteFileBackend]），
/// 本机目录走 dart:io（[LocalFileBackend]，日志目录页用）。
class FilesController extends GetxController {
  FilesController(this.backend, {String? root, this.serial = ''})
    : root = root == null ? null : backend.normalize(root),
      pathInput = TextEditingController(
        text: root == null ? backend.initialPath : backend.normalize(root),
      ),
      path = (root == null ? backend.initialPath : backend.normalize(root)).obs;

  /// 设备文件管理。
  factory FilesController.forDevice(String serial, {String? root}) =>
      FilesController(RemoteFileBackend(serial), root: root, serial: serial);

  final FileBackend backend;

  /// 页面标识：设备场景是 serial，本机场景留空。
  final String serial;

  /// 固定根。文件管理为空，可以从存储根开始。
  final String? root;
  final TextEditingController pathInput;
  final RxString path;
  final RxString keyword = ''.obs;
  final RxList<FileEntry> entries = <FileEntry>[].obs;
  final RxBool loading = true.obs;
  final RxBool busy = false.obs;
  final RxBool selecting = false.obs;
  final RxSet<String> selected = <String>{}.obs;
  final Rxn<Object> error = Rxn<Object>();
  final Rxn<FileClipboard> clipboard = Rxn<FileClipboard>();
  final Rxn<FileTask> task = Rxn<FileTask>();
  final RxInt taskTick = 0.obs;

  FileBackend? _activeBackend;
  DateTime _progressUiAt = DateTime.fromMillisecondsSinceEpoch(0);
  var _generation = 0;
  var _closed = false;

  bool get searching {
    keyword.value;
    return keyword.value.trim().isNotEmpty;
  }

  List<FileEntry> get selectedFiles {
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
    unawaited(_activeBackend?.abort());
    pathInput.dispose();
    super.onClose();
  }

  Future<void> reload() => open(path.value);

  Future<void> open(String nextPath) async {
    final generation = ++_generation;
    final target = backend.fence(root, nextPath);
    keyword.value = '';
    path.value = target;
    pathInput.text = target;
    await _load(generation, target);
  }

  Future<void> up() {
    if (searching) return open(path.value);
    final fence = root;
    if (fence != null && backend.normalize(path.value) == fence) {
      return Future<void>.value();
    }
    return open(backend.parent(path.value));
  }

  Future<void> search(String value) async {
    final generation = ++_generation;
    keyword.value = value.trim();
    await _load(generation, path.value);
  }

  Future<void> _load(int generation, String directory) async {
    await _activeBackend?.abort();
    loading.value = true;
    error.value = null;
    try {
      final query = keyword.value.trim();
      final loaded = query.isEmpty
          ? await backend.list(directory)
          : await backend.search(directory, query);
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

  void startSelecting(FileEntry file) {
    selecting.value = true;
    selected.add(file.path);
  }

  void toggleSelected(FileEntry file) {
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

  Future<TextReadResult?> readText(FileEntry file) async {
    if (file.canEnter) {
      return const TextReadResult.reject(TextReject.directory);
    }
    try {
      final bytes = await backend.readBytes(
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
    FileEntry file,
    String text,
  ) {
    final mode = file.mode == 0 ? 0x81a4 : (file.mode & 0x1ff) | 0x8000;
    return _runTask(
      l10n: l10n,
      label: l10n.filesTaskSave,
      total: 1,
      action: () async {
        _activeBackend = backend;
        await backend.writeBytes(file.path, utf8.encode(text), mode: mode);
        await reload();
        return FileNotice(title: l10n.filesEdit, message: l10n.filesSaved);
      },
    );
  }

  Future<FileNotice?> remove(
    FireAdbLocalizations l10n,
    List<FileEntry> files,
  ) {
    return _runCounted(
      l10n: l10n,
      label: l10n.filesTaskDelete,
      files: files,
      title: l10n.filesDelete,
      success: (count) => l10n.filesDeleted(count),
      action: (file) => backend.remove(<String>[file.path]),
    );
  }

  Future<FileNotice?> rename(
    FireAdbLocalizations l10n,
    FileEntry file,
    String name,
  ) {
    if (!backend.isSafeName(name)) {
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
        _activeBackend = backend;
        await backend.rename(
          file.path,
          backend.join(backend.parent(file.path), name),
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
    if (!backend.isSafeName(name)) {
      return Future<FileNotice?>.value(
        FileNotice(
          title: l10n.filesCreate,
          message: l10n.filesInvalidName,
          isError: true,
        ),
      );
    }
    final target = backend.join(path.value, name);
    return _runTask(
      l10n: l10n,
      label: l10n.filesCreate,
      total: 1,
      action: () async {
        _activeBackend = backend;
        if (directory) {
          await backend.createDirectory(target);
        } else {
          await backend.createFile(target);
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
    List<FileEntry> files,
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
        _activeBackend = backend;
        await backend.chmod(files.map((file) => file.path), mode);
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
        _activeBackend = backend;
        final sources = held.files.map((file) => file.path);
        if (held.cut) {
          await backend.moveTo(sources, destination);
          clipboard.value = null;
        } else {
          await backend.copyTo(sources, destination);
        }
        await reload();
        return FileNotice(
          title: l10n.filesPaste,
          message: l10n.filesPasted(held.files.length),
        );
      },
    );
  }

  /// 导出到主机。跨机传输，仅设备后端支持；UI 已按能力隐藏入口。
  Future<FileNotice?> export(
    FireAdbLocalizations l10n,
    List<FileEntry> files,
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

  /// 从主机上传。跨机传输，仅设备后端支持；UI 已按能力隐藏入口。
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

  RemoteFileBackend get _transfer {
    if (backend is! RemoteFileBackend) {
      throw StateError('此后端不支持跨机传输');
    }
    return backend as RemoteFileBackend;
  }

  Future<FileNotice?> _performExport(
    FireAdbLocalizations l10n,
    List<FileEntry> files,
    String directory,
  ) async {
    final transfer = _transfer;
    _activeBackend = transfer;
    final current = task.value;
    if (current != null) {
      current.measuring = true;
      current.currentName = files.isEmpty ? '' : files.first.name;
      _publish(force: true);
    }
    late final List<RemoteExportPiece> pieces;
    try {
      pieces = await transfer.planExport(files);
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
      await transfer.exportPieces(
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
    final transfer = _transfer;
    _activeBackend = transfer;
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
        await transfer.uploadFile(
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
    required List<FileEntry> files,
    required String title,
    required String Function(int count) success,
    required Future<void> Function(FileEntry file) action,
  }) {
    return _runTask(
      l10n: l10n,
      label: label,
      total: files.length,
      action: () async {
        _activeBackend = backend;
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
          await action(file);
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
            : taskError is StateError
            ? taskError.message
            : '$taskError',
        isError: true,
      );
    } finally {
      _activeBackend = null;
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
    unawaited(_activeBackend?.abort());
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
