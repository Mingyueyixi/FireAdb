import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:get/get.dart';

import '../app_feedback.dart';
import '../apps/data/source/fire_app_service.dart';
import '../connection/connection_manager.dart';
import '../connection/model/connected_device.dart';
import '../files/data/source/remote_file_commands.dart';
import '../l10n/generated/fire_adb_localizations.dart';
import 'capture_notice.dart';
import 'data/capture_paths.dart';
import 'data/capture_store.dart';

enum _RecordPhase { idle, recording, saving }

/// 一次录屏开始后的结果。失败时带提示；成功开始后用 [finished] 等保存完成。
class RecordingStart {
  const RecordingStart.failed(this.notice) : finished = null;

  const RecordingStart.started(this.finished) : notice = null;

  final CaptureNotice? notice;
  final Future<CaptureNotice?>? finished;
}

/// 录制设备屏幕。停止后把 mp4 拉回下载目录，并删除设备上的临时视频。
///
/// [method] 决定用系统程序还是辅助服务里的内置录屏。
/// 系统程序会被策略接管时，改用临时目录里的副本。副本已在就直接用，没有才复制，录完后保留。
class ScreenrecordController extends GetxController {
  ScreenrecordController(this.serial, {CaptureStore? store})
    : _store = store ?? CaptureStore.tryOpen();

  final String serial;
  final CaptureStore? _store;
  final StringBuffer _output = StringBuffer();

  final RxBool loading = true.obs;
  final RxBool preparing = false.obs;
  final RxBool recording = false.obs;
  final RxBool saving = false.obs;
  final RxInt timeLimitSeconds = kMaxScreenrecordSeconds.obs;
  final RxnInt sdk = RxnInt();

  bool get allowsUnlimited =>
      method.value == ScreenRecordMethod.builtin ||
      screenrecordAllowsUnlimited(sdk.value);

  List<int> get timeLimitChoices => allowsUnlimited
      ? const <int>[30, 60, 180, kUnlimitedScreenrecordSeconds]
      : kScreenrecordLimits;
  final Rx<ScreenRecordMethod> method = ScreenRecordMethod.system.obs;
  final Rx<Duration> elapsed = Duration.zero.obs;
  final RxInt bytesDone = 0.obs;
  final RxInt bytesTotal = 0.obs;
  final RxList<CaptureFile> files = <CaptureFile>[].obs;
  final Rxn<String> selectedPath = Rxn<String>();
  final Rxn<Object> loadError = Rxn<Object>();

  _RecordPhase _phase = _RecordPhase.idle;
  Completer<void> _shellDone = Completer<void>();
  Completer<CaptureNotice?>? _finished;
  ConnectedDevice? _deviceSession;
  ConnectedShell? _shell;
  StreamSubscription<List<int>>? _subscription;
  Timer? _timer;
  DateTime _startedAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _progressAt = DateTime.fromMillisecondsSinceEpoch(0);
  FireAdbLocalizations? _l10n;
  String? _remotePath;
  String? _localName;
  Future<void>? _saveTask;
  Future<void>? _stopTask;
  var _generation = 0;
  var _saveStarted = false;
  var _starting = false;
  var _stopRequested = false;
  var _stopCommand = stopScreenrecordCommand();
  var _useShellRecorder = false;
  Future<void>? _detectTask;

  bool get hasDirectory => _store != null;

  String get directoryPath => _store?.directory.path ?? '';

  @override
  void onInit() {
    super.onInit();
    if (!Platform.isAndroid) unawaited(reload());
    _detectTask = _detectRecordMethodBody();
  }

  @override
  void onClose() {
    _timer?.cancel();
    unawaited(stop());
    super.onClose();
  }

  void setTimeLimit(int seconds) {
    if (preparing.value || recording.value || saving.value) return;
    if (!timeLimitChoices.contains(seconds)) return;
    timeLimitSeconds.value = seconds;
  }

  void setMethod(ScreenRecordMethod value) {
    if (preparing.value || recording.value || saving.value) return;
    if (value == ScreenRecordMethod.scrcpy) return;
    method.value = value;
    _clampTimeLimit();
  }

  /// 进入页面时已经开始。重复调用等待同一次结果。
  ///
  /// 只记录系统版本，以及系统录屏是否要改用临时目录里的副本。界面上的选项不变。
  Future<void> detectRecordMethod() {
    return _detectTask ??= _detectRecordMethodBody();
  }

  Future<void> _detectRecordMethodBody() async {
    try {
      final device = Get.find<ConnectionManager>().deviceOf(serial);
      if (device == null) return;
      final output = await device.shell(recordingDeviceProbeCommand());
      if (isClosed) return;
      final probe = parseRecordingDeviceProbe(output);
      sdk.value = probe.sdk;
      _useShellRecorder = probe.needsShellCopy;
      _clampTimeLimit();
    } catch (error, stackTrace) {
      logAppError('检查录屏程序标签失败：$serial', error, stackTrace);
    }
  }

  void _clampTimeLimit() {
    if (!allowsUnlimited &&
        timeLimitSeconds.value == kUnlimitedScreenrecordSeconds) {
      timeLimitSeconds.value = kMaxScreenrecordSeconds;
    }
  }

  Future<void> reload() async {
    final store = _store;
    if (store == null || isClosed) return;
    try {
      await store.ensure();
      final listed = await store.list(extension: 'mp4');
      if (isClosed) return;
      final own = <CaptureFile>[
        for (final file in listed)
          if (captureFileMatchesDevice(file.name, serial)) file,
      ];
      files.assignAll(own);
      final selected = selectedPath.value;
      if (selected != null && !own.any((file) => file.path == selected)) {
        selectedPath.value = null;
      }
      loadError.value = null;
    } catch (error, stackTrace) {
      logAppError('读取录像列表失败：$serial', error, stackTrace);
      if (!isClosed) loadError.value = error;
    } finally {
      if (!isClosed) loading.value = false;
    }
  }

  Future<RecordingStart> start(FireAdbLocalizations l10n) async {
    if (_phase != _RecordPhase.idle || _starting) {
      return const RecordingStart.failed(null);
    }
    final store = _store;
    final device = Get.find<ConnectionManager>().deviceOf(serial);
    if (device == null) {
      return RecordingStart.failed(deviceNotConnectedNotice(l10n));
    }
    if (store == null) {
      return RecordingStart.failed(directoryUnavailableNotice(l10n));
    }

    final name = captureFileName(
      prefix: 'screenrecord',
      time: DateTime.now(),
      serial: serial,
      extension: 'mp4',
    );
    _starting = true;
    _stopRequested = false;
    _l10n = l10n;
    if (!isClosed) preparing.value = true;
    try {
      await detectRecordMethod();
      if (_stopRequested || isClosed) {
        return const RecordingStart.failed(null);
      }
      ConnectedShell shell;
      try {
        final selected = method.value;
        final useShellRecorder =
            selected == ScreenRecordMethod.system && _useShellRecorder;
        final prepared = switch (selected) {
          ScreenRecordMethod.system when useShellRecorder =>
            await _prepareShellRecorder(device, l10n, name),
          ScreenRecordMethod.system => await _prepareSystemRecorder(
            device,
            l10n,
            name,
          ),
          ScreenRecordMethod.builtin => await _prepareBuiltinRecorder(
            device,
            name,
          ),
          ScreenRecordMethod.scrcpy => (
            remote: null,
            notice: captureFailure(l10n, l10n.screenrecordMethodScrcpySubtitle),
          ),
        };
        if (prepared.notice != null) {
          return RecordingStart.failed(prepared.notice);
        }
        final remote = prepared.remote;
        if (remote == null) return const RecordingStart.failed(null);
        final unlimited = allowsUnlimited;
        final limit = timeLimitSeconds.value;
        final command = switch (selected) {
          ScreenRecordMethod.system when useShellRecorder =>
            shellRecorderCommand(
              remotePath: remote,
              timeLimitSeconds: limit,
              allowUnlimited: unlimited,
            ),
          ScreenRecordMethod.builtin => builtinRecordCommand(
            remotePath: remote,
            timeLimitSeconds: limit,
          ),
          _ => screenrecordCommand(
            remotePath: remote,
            timeLimitSeconds: limit,
            allowUnlimited: unlimited,
          ),
        };
        _stopCommand = switch (selected) {
          ScreenRecordMethod.system when useShellRecorder =>
            stopScreenrecordCommand(kShellRecorderName),
          ScreenRecordMethod.builtin => stopBuiltinRecordCommand(),
          _ => stopScreenrecordCommand(),
        };
        if (_stopRequested || isClosed) {
          return const RecordingStart.failed(null);
        }
        shell = selected == ScreenRecordMethod.builtin
            ? await device.openExec(command)
            : await device.openShell(command);
        _beginSession(device, shell, remote: remote, name: name, l10n: l10n);
      } catch (error, stackTrace) {
        logAppError('开始录屏失败：$serial', error, stackTrace);
        return RecordingStart.failed(captureFailure(l10n, '$error'));
      }
      if (_stopRequested || isClosed) {
        _stopTask = null;
        await stop();
      }
      final finished = _finished?.future;
      if (finished == null) return const RecordingStart.failed(null);
      return RecordingStart.started(finished);
    } finally {
      _starting = false;
      if (!isClosed) preparing.value = false;
    }
  }

  Future<void> stop() {
    final current = _stopTask;
    if (current != null) return current;
    final task = _stopBody();
    // 还没开始录时，停止只是打个标记，不能占住下一次真正的停止。
    if (_phase != _RecordPhase.idle || _saveStarted) {
      _stopTask = task;
    }
    return task;
  }

  Future<({String? remote, CaptureNotice? notice})> _prepareSystemRecorder(
    ConnectedDevice device,
    FireAdbLocalizations l10n,
    String name,
  ) async {
    final output = await device.shell(resolveScreenrecordDirCommand());
    final directory = parseWritableDir(output);
    if (directory == null) {
      final brief = briefDeviceOutput(output);
      return (
        remote: null,
        notice: captureFailure(
          l10n,
          brief.isEmpty
              ? l10n.screenrecordNoWritableDir
              : l10n.captureDeviceOutput(brief),
        ),
      );
    }
    return (remote: joinRemoteCapturePath(directory, name), notice: null);
  }

  Future<({String? remote, CaptureNotice? notice})> _prepareShellRecorder(
    ConnectedDevice device,
    FireAdbLocalizations l10n,
    String name,
  ) async {
    final output = await device.shell(installShellRecorderCommand());
    if (shellRecorderContextIsSafe(output)) {
      return (remote: joinRemoteCapturePath(kShellTempDir, name), notice: null);
    }
    if (output.contains('screen_record')) {
      return (
        remote: null,
        notice: captureFailure(l10n, l10n.screenrecordShellUnsafe),
      );
    }
    final brief = briefDeviceOutput(output);
    return (
      remote: null,
      notice: captureFailure(
        l10n,
        brief.isEmpty
            ? l10n.screenrecordShellCopyFailed
            : l10n.captureDeviceOutput(brief),
      ),
    );
  }

  Future<({String? remote, CaptureNotice? notice})> _prepareBuiltinRecorder(
    ConnectedDevice device,
    String name,
  ) async {
    await ensureFireAppService(device);
    return (remote: joinRemoteCapturePath(kShellTempDir, name), notice: null);
  }

  Future<CaptureNotice?> remove(
    FireAdbLocalizations l10n,
    CaptureFile file,
  ) async {
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
      logAppError('删除录像失败：${file.path}', error, stackTrace);
      return captureFailure(l10n, '$error');
    }
  }

  void select(String path) => selectedPath.value = path;

  void _beginSession(
    ConnectedDevice device,
    ConnectedShell shell, {
    required String remote,
    required String name,
    required FireAdbLocalizations l10n,
  }) {
    final generation = ++_generation;
    final finished = Completer<CaptureNotice?>();
    _finished = finished;
    _deviceSession = device;
    _shell = shell;
    _remotePath = remote;
    _localName = name;
    _l10n = l10n;
    _output.clear();
    _shellDone = Completer<void>();
    _saveStarted = false;
    _saveTask = null;
    _phase = _RecordPhase.recording;
    _startedAt = DateTime.now();
    if (!isClosed) {
      recording.value = true;
      elapsed.value = Duration.zero;
      bytesDone.value = 0;
      bytesTotal.value = 0;
    }
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (isClosed || _phase != _RecordPhase.recording) return;
      elapsed.value = DateTime.now().difference(_startedAt);
    });
    _subscription = shell.readStream.listen(
      _addChunk,
      onDone: _markShellDone,
      onError: (Object error, StackTrace stackTrace) {
        logAppError('录屏输出中断：$remote', error, stackTrace);
        _addText('$error');
        _markShellDone();
      },
      cancelOnError: true,
    );
    unawaited(
      _shellDone.future.then((_) {
        if (generation != _generation) return Future<void>.value();
        return _save();
      }),
    );
  }

  Future<void> _stopBody() async {
    _stopRequested = true;
    try {
      if (_phase == _RecordPhase.recording) {
        await _signalStop();
        await _save();
        return;
      }
      final task = _saveTask;
      if (task != null) await task;
    } finally {
      if (!_saveStarted) _stopTask = null;
    }
  }

  Future<void> _signalStop() async {
    final device = _deviceSession;
    if (device == null) return;
    try {
      await device.shell(_stopCommand);
      if (_shellDone.isCompleted) return;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (_shellDone.isCompleted) return;
      await device.shell(_stopCommand);
    } catch (error, stackTrace) {
      logAppError('发送录屏停止信号失败：${_remotePath ?? serial}', error, stackTrace);
    }
  }

  void _markShellDone() {
    if (!_shellDone.isCompleted) _shellDone.complete();
  }

  Future<void> _save() {
    if (_saveStarted) return _saveTask ?? Future<void>.value();
    _saveStarted = true;
    _phase = _RecordPhase.saving;
    _timer?.cancel();
    if (!isClosed) {
      recording.value = false;
      saving.value = true;
    }
    final task = _saveBody();
    _saveTask = task;
    return task;
  }

  Future<void> _saveBody() async {
    final l10n = _l10n;
    final finished = _finished;
    CaptureNotice? notice;
    try {
      await _waitForShell();
      notice = await _pullAndStore(l10n);
    } catch (error, stackTrace) {
      logAppError('保存录像失败：${_remotePath ?? serial}', error, stackTrace);
      if (l10n != null) {
        final remote = _remotePath;
        notice = remote == null
            ? captureFailure(l10n, '$error')
            : captureFailure(
                l10n,
                l10n.captureFailedWithRemote('$error', remote),
              );
      }
    } finally {
      await _closeShell();
      _saveStarted = false;
      _saveTask = null;
      _stopTask = null;
      _phase = _RecordPhase.idle;
      _deviceSession = null;
      _remotePath = null;
      _localName = null;
      if (!isClosed) {
        recording.value = false;
        saving.value = false;
        preparing.value = false;
        bytesDone.value = 0;
        bytesTotal.value = 0;
      }
      if (finished != null && !finished.isCompleted) {
        finished.complete(notice);
      }
    }
  }

  Future<void> _waitForShell() async {
    if (_shellDone.isCompleted) return;
    try {
      await _shellDone.future.timeout(const Duration(seconds: 8));
    } on TimeoutException {
      await _closeShell();
    }
  }

  Future<CaptureNotice?> _pullAndStore(FireAdbLocalizations? l10n) async {
    final device = _deviceSession;
    final store = _store;
    final remote = _remotePath;
    final name = _localName;
    if (l10n == null ||
        device == null ||
        store == null ||
        remote == null ||
        name == null) {
      return l10n == null ? null : deviceNotConnectedNotice(l10n);
    }
    final stat = await device.stat(remote);
    if (stat.mode == 0 || stat.size <= 0) return _missing(l10n);
    if (stat.size > kMaxRecordingBytes) {
      return captureFailure(
        l10n,
        l10n.screenrecordTooLarge(formatFileSize(stat.size), remote),
      );
    }
    final bytes = await device.pull(remote, onProgress: _onProgress);
    if (!looksLikeMp4(bytes)) {
      final output = briefDeviceOutput(_output.toString());
      return captureFailure(
        l10n,
        output.isEmpty
            ? l10n.screenrecordInvalid(remote)
            : l10n.captureDeviceOutput(output),
      );
    }
    final file = await store.write(name, bytes);
    if (!isClosed) {
      await reload();
      selectedPath.value = file.path;
    }
    try {
      await device.shell(removeRemoteFileCommand(remote));
    } catch (error, stackTrace) {
      logAppError('删除设备上的临时录像失败：$remote', error, stackTrace);
    }
    return captureSavedNotice(
      l10n,
      file.path,
      title: l10n.workspaceScreenrecordTitle,
    );
  }

  CaptureNotice _missing(FireAdbLocalizations l10n) {
    final output = briefDeviceOutput(_output.toString());
    if (output.isNotEmpty) {
      return captureFailure(l10n, l10n.captureDeviceOutput(output));
    }
    return captureFailure(l10n, l10n.screenrecordMissing);
  }

  void _onProgress(int done, int total) {
    if (isClosed) return;
    final now = DateTime.now();
    final finished = total > 0 && done >= total;
    if (!finished &&
        now.difference(_progressAt) < const Duration(milliseconds: 100)) {
      return;
    }
    _progressAt = now;
    bytesDone.value = done;
    bytesTotal.value = total;
  }

  void _addChunk(List<int> chunk) {
    _addText(utf8.decode(chunk, allowMalformed: true));
  }

  void _addText(String text) {
    const limit = 4000;
    if (_output.length >= limit || text.isEmpty) return;
    final room = limit - _output.length;
    _output.write(text.length <= room ? text : text.substring(0, room));
  }

  Future<void> _closeShell() async {
    _markShellDone();
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) {
      try {
        await subscription.cancel();
      } catch (error, stackTrace) {
        logAppError('取消录屏输出订阅失败：$serial', error, stackTrace);
      }
    }
    final shell = _shell;
    _shell = null;
    if (shell == null) return;
    try {
      await shell.close();
    } catch (error, stackTrace) {
      logAppError('关闭录屏命令流失败：$serial', error, stackTrace);
    }
  }
}
