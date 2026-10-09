import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../../../connection/model/connected_device.dart';

/// 手机上的 jar 路径。录屏入口也在这一份 jar 里。
const String fireAppServiceRemotePath = '/data/local/tmp/fire-app-service.jar';

/// `app_process` 入口。
const String fireAppServiceMainClass = 'com.fire.adb.appservice.FireAppService';

const String fireAppServiceMagic = 'FAAS';
const int fireAppServiceVersion = 1;
const int fireAppFrameReady = 1;
const int fireAppFrameLabel = 2;
const int fireAppFrameLabelsDone = 3;
const int fireAppFrameIcon = 4;
const int fireAppFrameError = 5;
const int fireAppFrameShow = 6;
const int fireAppFlagSystem = 1;
const int fireAppFlagDisabled = 2;
const int fireAppFlagSuspended = 4;

/// 启动应用信息服务。标准输入输出是二进制帧，不经过 shell 的换行转换。
String fireAppServiceCommand(String remotePath) =>
    'CLASSPATH=$remotePath app_process -Djava.class.path=$remotePath /system/bin $fireAppServiceMainClass';

sealed class FireAppFrame {}

class FireAppReady extends FireAppFrame {}

class FireAppLabel extends FireAppFrame {
  FireAppLabel(this.packageName, this.label);

  final String packageName;
  final String label;
}

class FireAppLabelsDone extends FireAppFrame {}

class FireAppIcon extends FireAppFrame {
  FireAppIcon(this.packageName, this.png);

  final String packageName;
  final Uint8List? png;
}

class FireAppShow extends FireAppFrame {
  FireAppShow({
    required this.packageName,
    required this.label,
    required this.versionName,
    required this.versionCode,
    required this.isSystem,
    required this.isDisabledUser,
    required this.isSuspended,
    required this.png,
  });

  final String packageName;
  final String label;
  final String versionName;
  final int? versionCode;
  final bool isSystem;
  final bool isDisabledUser;
  final bool isSuspended;
  final Uint8List? png;
}

class FireAppServiceError extends FireAppFrame {
  FireAppServiceError(this.message);

  final String message;
}

/// 把陆续到达的字节解析成帧。数据不够时保留，下次再续。
class FireAppFrameReader {
  final _pending = <int>[];

  List<FireAppFrame> add(List<int> chunk) {
    _pending.addAll(chunk);
    final frames = <FireAppFrame>[];
    while (true) {
      final frame = _tryOne();
      if (frame == null) return frames;
      frames.add(frame);
    }
  }

  FireAppFrame? _tryOne() {
    final start = _findMagic();
    if (start < 0) {
      if (_pending.length > 3) {
        _pending.removeRange(0, _pending.length - 3);
      }
      return null;
    }
    if (start > 0) _pending.removeRange(0, start);
    if (_pending.length < 6) return null;
    final version = _pending[4];
    final type = _pending[5];
    if (version != fireAppServiceVersion) {
      throw FormatException('不支持的应用信息服务版本 $version');
    }
    switch (type) {
      case fireAppFrameReady:
      case fireAppFrameLabelsDone:
        _pending.removeRange(0, 6);
        return type == fireAppFrameReady ? FireAppReady() : FireAppLabelsDone();
      case fireAppFrameError:
        final message = _peekString(6);
        if (message == null) return null;
        _pending.removeRange(0, message.next);
        return FireAppServiceError(message.value);
      case fireAppFrameLabel:
        final packageName = _peekString(6);
        if (packageName == null) return null;
        final label = _peekString(packageName.next);
        if (label == null) return null;
        _pending.removeRange(0, label.next);
        return FireAppLabel(packageName.value, label.value);
      case fireAppFrameIcon:
        final iconPackage = _peekString(6);
        if (iconPackage == null) return null;
        final icon = _peekPng(iconPackage.next);
        if (icon == null) return null;
        _pending.removeRange(0, icon.next);
        return FireAppIcon(iconPackage.value, icon.png);
      case fireAppFrameShow:
        final shownPackage = _peekString(6);
        if (shownPackage == null) return null;
        final shownLabel = _peekString(shownPackage.next);
        if (shownLabel == null) return null;
        final shownVersion = _peekString(shownLabel.next);
        if (shownVersion == null) return null;
        final fixed = shownVersion.next;
        if (_pending.length < fixed + 5) return null;
        final versionBits = _uint32(fixed);
        final flags = _pending[fixed + 4];
        final shownIcon = _peekPng(fixed + 5);
        if (shownIcon == null) return null;
        _pending.removeRange(0, shownIcon.next);
        return FireAppShow(
          packageName: shownPackage.value,
          label: shownLabel.value,
          versionName: shownVersion.value,
          versionCode: versionBits == 0xFFFFFFFF ? null : versionBits,
          isSystem: (flags & fireAppFlagSystem) != 0,
          isDisabledUser: (flags & fireAppFlagDisabled) != 0,
          isSuspended: (flags & fireAppFlagSuspended) != 0,
          png: shownIcon.png,
        );
      default:
        throw FormatException('未知的应用信息服务帧 $type');
    }
  }

  int _findMagic() {
    if (_pending.length < fireAppServiceMagic.length) return -1;
    final marker = ascii.encode(fireAppServiceMagic);
    final last = _pending.length - marker.length;
    for (var index = 0; index <= last; index++) {
      var matched = true;
      for (var part = 0; part < marker.length; part++) {
        if (_pending[index + part] != marker[part]) {
          matched = false;
          break;
        }
      }
      if (matched) return index;
    }
    return -1;
  }

  ({String value, int next})? _peekString(int offset) {
    if (_pending.length < offset + 2) return null;
    final length = (_pending[offset] << 8) | _pending[offset + 1];
    final end = offset + 2 + length;
    if (_pending.length < end) return null;
    final value = utf8.decode(
      _pending.sublist(offset + 2, end),
      allowMalformed: true,
    );
    return (value: value, next: end);
  }

  ({Uint8List? png, int next})? _peekPng(int offset) {
    if (_pending.length < offset + 4) return null;
    final pngLength = _uint32(offset);
    if (pngLength > 2 * 1024 * 1024) {
      throw FormatException('应用图标过大');
    }
    final pngEnd = offset + 4 + pngLength;
    if (_pending.length < pngEnd) return null;
    Uint8List? png;
    if (pngLength > 0) {
      png = Uint8List.fromList(_pending.sublist(offset + 4, pngEnd));
    }
    return (png: png, next: pngEnd);
  }

  int _uint32(int offset) =>
      (_pending[offset] << 24) |
      (_pending[offset + 1] << 16) |
      (_pending[offset + 2] << 8) |
      _pending[offset + 3];
}

/// 把辅助服务 jar 推到设备。大小相同就跳过，避免每次都重传。
Future<void> ensureFireAppService(ConnectedDevice device) async {
  final data = await rootBundle.load('assets/fire-app-service.jar');
  final jar = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  final sync = await device.openSync();
  try {
    final stat = await sync.client.stat(fireAppServiceRemotePath);
    if (stat.mode != 0 && stat.size == jar.length) {
      try {
        await sync.client.quit();
      } catch (_) {}
      return;
    }
    await sync.client.push(jar, fireAppServiceRemotePath);
    try {
      await sync.client.quit();
    } catch (_) {}
  } finally {
    await sync.close();
  }
}

/// 同一台设备上排队取应用信息。当前这批取完就关掉 `exec:`，进程随即退出。
Future<FireAppShow> loadFireAppShow(
  ConnectedDevice device,
  String packageName,
) {
  final gate = _showGates.putIfAbsent(
    device.serial,
    () => _FireAppShowGate(device),
  );
  return gate.load(device, packageName);
}

final _showGates = <String, _FireAppShowGate>{};

class _ShowJob {
  _ShowJob(this.packageName);

  final String packageName;
  final Completer<FireAppShow> done = Completer<FireAppShow>();
  var attempts = 0;
}

class _FireAppShowGate {
  _FireAppShowGate(this._device);

  ConnectedDevice _device;
  final _waiters = <_ShowJob>[];
  var _running = false;

  Future<FireAppShow> load(ConnectedDevice device, String packageName) {
    _device = device;
    final job = _ShowJob(packageName);
    _waiters.add(job);
    _kick();
    return job.done.future;
  }

  void _kick() {
    if (_running) return;
    _running = true;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    final reader = FireAppFrameReader();
    final frames = <FireAppFrame>[];
    Completer<void>? wait;
    var failed = false;
    ConnectedShell? shell;
    StreamSubscription<List<int>>? subscription;
    try {
      await ensureFireAppService(_device);
      shell = await _device.openExec(
        fireAppServiceCommand(fireAppServiceRemotePath),
      );
      subscription = shell.readStream.listen(
        (chunk) {
          try {
            frames.addAll(reader.add(chunk));
          } catch (error, stackTrace) {
            final pending = wait;
            if (pending != null && !pending.isCompleted) {
              pending.completeError(error, stackTrace);
            }
            return;
          }
          final pending = wait;
          if (pending != null && !pending.isCompleted) pending.complete();
        },
        onError: (Object _) {
          final pending = wait;
          if (pending != null && !pending.isCompleted) {
            pending.completeError(StateError('应用信息服务已结束'));
          }
        },
        onDone: () {
          final pending = wait;
          if (pending != null && !pending.isCompleted) {
            pending.completeError(StateError('应用信息服务已结束'));
          }
        },
      );
      final ready = await _next(frames, (value) => wait = value)
          .timeout(const Duration(seconds: 30));
      if (ready is FireAppServiceError) {
        throw StateError(ready.message.isEmpty ? '应用信息服务启动失败' : ready.message);
      }
      if (ready is! FireAppReady) {
        throw StateError('应用信息服务没有就绪');
      }
      while (_waiters.isNotEmpty) {
        final job = _waiters.removeAt(0);
        job.attempts++;
        try {
          await shell.write(utf8.encode('SHOW ${job.packageName}\n'));
          final frame = await _next(frames, (value) => wait = value)
              .timeout(const Duration(seconds: 20));
          if (frame is FireAppShow) {
            job.done.complete(frame);
            continue;
          }
          if (frame is FireAppServiceError) {
            job.done.completeError(
              StateError(frame.message.isEmpty ? '读取应用信息失败' : frame.message),
            );
            continue;
          }
          job.done.completeError(StateError('应用信息响应无效'));
        } catch (error, stackTrace) {
          failed = true;
          if (job.attempts < 2 && !job.done.isCompleted) {
            _waiters.insert(0, job);
          } else if (!job.done.isCompleted) {
            job.done.completeError(error, stackTrace);
          }
          break;
        }
      }
    } catch (error, stackTrace) {
      failed = true;
      for (final job in _waiters) {
        if (!job.done.isCompleted) {
          job.done.completeError(error, stackTrace);
        }
      }
      _waiters.clear();
    } finally {
      if (!failed) {
        try {
          await shell?.write(utf8.encode('QUIT\n')).timeout(
            const Duration(seconds: 2),
          );
        } catch (_) {}
      }
      await subscription?.cancel();
      try {
        await shell?.close().timeout(const Duration(seconds: 2));
      } catch (_) {}
      _running = false;
      if (_waiters.isNotEmpty) _kick();
    }
  }

  Future<FireAppFrame> _next(
    List<FireAppFrame> frames,
    void Function(Completer<void>?) writeWait,
  ) async {
    while (frames.isEmpty) {
      final pending = Completer<void>();
      writeWait(pending);
      if (frames.isNotEmpty && !pending.isCompleted) pending.complete();
      try {
        await pending.future;
      } finally {
        writeWait(null);
      }
    }
    return frames.removeAt(0);
  }
}
