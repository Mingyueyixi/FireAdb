import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../../../connection/model/connected_device.dart';
import '../../../log/app_log.dart';

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
const int fireAppFrameApp = 7;
const int fireAppFrameCatalogDone = 8;
const int fireAppFlagSystem = 1;
const int fireAppFlagDisabled = 2;
const int fireAppFlagSuspended = 4;
const int fireAppFlagDebug = 8;

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

class FireAppCatalogDone extends FireAppFrame {}

class FireAppIcon extends FireAppFrame {
  FireAppIcon(this.packageName, this.png);

  final String packageName;
  final Uint8List? png;
}

/// 列表阶段一次取回的应用信息，不含图标和目录。
class FireAppSummary extends FireAppFrame {
  FireAppSummary({
    required this.packageName,
    required this.label,
    required this.versionName,
    required this.versionCode,
    required this.isSystem,
    required this.isDisabledUser,
    required this.isSuspended,
    required this.isDebuggable,
    this.apkPaths = const <String>[],
    this.sizeBytes,
  });

  final String packageName;
  final String label;
  final String versionName;
  final int? versionCode;
  final bool isSystem;
  final bool isDisabledUser;
  final bool isSuspended;
  final bool isDebuggable;
  final List<String> apkPaths;
  final int? sizeBytes;

  FireAppSummary withLabel(String label) {
    return FireAppSummary(
      packageName: packageName,
      label: label,
      versionName: versionName,
      versionCode: versionCode,
      isSystem: isSystem,
      isDisabledUser: isDisabledUser,
      isSuspended: isSuspended,
      isDebuggable: isDebuggable,
      apkPaths: apkPaths,
      sizeBytes: sizeBytes,
    );
  }
}

/// 列表读取各段耗时。［读取］不含把结果画到界面上的时间。
class FireAppListTiming {
  var jarMs = 0;
  var readyMs = 0;
  var listMs = 0;
  var nameMs = 0;
  var readMs = 0;
}

/// 刷新列表时，还在排队的单条查询会被丢掉。
class FireAppLoadCancelled implements Exception {
  const FireAppLoadCancelled();
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
    required this.isDebuggable,
    required this.png,
    required this.dataDir,
    required this.cacheDir,
    required this.externalDir,
  });

  final String packageName;
  final String label;
  final String versionName;
  final int? versionCode;
  final bool isSystem;
  final bool isDisabledUser;
  final bool isSuspended;
  final bool isDebuggable;
  final Uint8List? png;
  final String dataDir;
  final String cacheDir;
  final String externalDir;
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
      case fireAppFrameCatalogDone:
        _pending.removeRange(0, 6);
        return switch (type) {
          fireAppFrameReady => FireAppReady(),
          fireAppFrameCatalogDone => FireAppCatalogDone(),
          _ => FireAppLabelsDone(),
        };
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
        final dataDir = _peekString(shownIcon.next);
        if (dataDir == null) return null;
        final cacheDir = _peekString(dataDir.next);
        if (cacheDir == null) return null;
        final externalDir = _peekString(cacheDir.next);
        if (externalDir == null) return null;
        _pending.removeRange(0, externalDir.next);
        return FireAppShow(
          packageName: shownPackage.value,
          label: shownLabel.value,
          versionName: shownVersion.value,
          versionCode: versionBits == 0xFFFFFFFF ? null : versionBits,
          isSystem: (flags & fireAppFlagSystem) != 0,
          isDisabledUser: (flags & fireAppFlagDisabled) != 0,
          isSuspended: (flags & fireAppFlagSuspended) != 0,
          isDebuggable: (flags & fireAppFlagDebug) != 0,
          png: shownIcon.png,
          dataDir: dataDir.value,
          cacheDir: cacheDir.value,
          externalDir: externalDir.value,
        );
      case fireAppFrameApp:
        final appPackage = _peekString(6);
        if (appPackage == null) return null;
        final appLabel = _peekString(appPackage.next);
        if (appLabel == null) return null;
        final appVersion = _peekString(appLabel.next);
        if (appVersion == null) return null;
        final appFixed = appVersion.next;
        if (_pending.length < appFixed + 5) return null;
        final appVersionBits = _uint32(appFixed);
        final appFlags = _pending[appFixed + 4];
        final apk = _peekString(appFixed + 5);
        if (apk == null) return null;
        if (_pending.length < apk.next + 8) return null;
        final sizeBits = _uint64(apk.next);
        _pending.removeRange(0, apk.next + 8);
        return FireAppSummary(
          packageName: appPackage.value,
          label: appLabel.value,
          versionName: appVersion.value,
          versionCode: appVersionBits == 0xFFFFFFFF ? null : appVersionBits,
          isSystem: (appFlags & fireAppFlagSystem) != 0,
          isDisabledUser: (appFlags & fireAppFlagDisabled) != 0,
          isSuspended: (appFlags & fireAppFlagSuspended) != 0,
          isDebuggable: (appFlags & fireAppFlagDebug) != 0,
          apkPaths: _apkPaths(apk.value),
          sizeBytes: sizeBits <= 0 ? null : sizeBits,
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

  List<String> _apkPaths(String value) {
    if (value.isEmpty) return const <String>[];
    return <String>[
      for (final line in value.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
  }

  int _uint32(int offset) =>
      (_pending[offset] << 24) |
      (_pending[offset + 1] << 16) |
      (_pending[offset + 2] << 8) |
      _pending[offset + 3];

  int _uint64(int offset) {
    var value = 0;
    for (var index = 0; index < 8; index++) {
      value = (value << 8) | _pending[offset + index];
    }
    return value;
  }
}

Uint8List? _cachedJar;
final _jarPushed = <String, int>{};

/// 把辅助服务 jar 推到设备。大小相同就跳过，避免每次都重传。
/// 本进程里确认过的设备不再查远程大小。
Future<void> ensureFireAppService(ConnectedDevice device) async {
  final jar = _cachedJar ??= await _loadFireAppJar();
  if (_jarPushed[device.serial] == jar.length) return;
  final sync = await device.openSync();
  try {
    final stat = await sync.client.stat(fireAppServiceRemotePath);
    if (stat.mode != 0 && stat.size == jar.length) {
      try {
        await sync.client.quit();
      } catch (_) {}
      _jarPushed[device.serial] = jar.length;
      return;
    }
    await sync.client.push(jar, fireAppServiceRemotePath);
    try {
      await sync.client.quit();
    } catch (_) {}
    _jarPushed[device.serial] = jar.length;
  } finally {
    await sync.close();
  }
}

Future<Uint8List> _loadFireAppJar() async {
  final data = await rootBundle.load('assets/fire-app-service.jar');
  return Uint8List.fromList(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  );
}

typedef FireAppListProgress = void Function(
  List<FireAppSummary> items,
  FireAppListTiming timing,
);

class FireAppListLoad {
  const FireAppListLoad({required this.summaries, required this.timing});

  final List<FireAppSummary> summaries;
  final FireAppListTiming timing;
}

/// 一次取回全部应用的名称、版本、标记、APK 路径和体积。
/// 服务进程会留给随后的图标查询，避免再启动一次。
Future<FireAppListLoad> loadFireAppSummaries(
  ConnectedDevice device, {
  FireAppListProgress? onCatalog,
  FireAppListProgress? onNames,
}) {
  return _hub(device).list(device, onCatalog: onCatalog, onNames: onNames);
}

/// 同一台设备上的图标查询走已经打开的服务进程。
Future<FireAppShow> loadFireAppShow(
  ConnectedDevice device,
  String packageName,
) {
  return _hub(device).show(device, packageName);
}

final _hubs = <String, _FireAppHub>{};

_FireAppHub _hub(ConnectedDevice device) =>
    _hubs.putIfAbsent(device.serial, _FireAppHub.new);

class _FireAppHub {
  Future<void> _chain = Future<void>.value();
  ConnectedShell? _shell;
  StreamSubscription<List<int>>? _subscription;
  FireAppFrameReader? _reader;
  final _frames = <FireAppFrame>[];
  Completer<void>? _wait;
  var _epoch = 0;
  var _session = 0;
  var _listenEpoch = 0;
  Timer? _idle;

  Future<FireAppListLoad> list(
    ConnectedDevice device, {
    FireAppListProgress? onCatalog,
    FireAppListProgress? onNames,
  }) {
    _epoch++;
    return _run(() async {
      _bumpSession();
      try {
        return await _listBody(device, onCatalog, onNames);
      } catch (error) {
        await _dropShell();
        rethrow;
      } finally {
        _scheduleIdle();
      }
    });
  }

  Future<FireAppShow> show(ConnectedDevice device, String packageName) {
    final epoch = _epoch;
    return _run(() async {
      try {
        if (epoch != _epoch) throw const FireAppLoadCancelled();
        _bumpSession();
        try {
          return await _showBody(device, packageName);
        } catch (error) {
          if (error is FireAppLoadCancelled) rethrow;
          await _dropShell();
          if (epoch != _epoch) throw const FireAppLoadCancelled();
          return await _showBody(device, packageName);
        }
      } finally {
        _scheduleIdle();
      }
    });
  }

  Future<T> _run<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _chain = _chain.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      }
    });
    return completer.future;
  }

  Future<FireAppListLoad> _listBody(
    ConnectedDevice device,
    FireAppListProgress? onCatalog,
    FireAppListProgress? onNames,
  ) async {
    final timing = FireAppListTiming();
    final opened = await _ensureShell(device);
    timing.jarMs = opened.jarMs;
    timing.readyMs = opened.readyMs;
    final shell = _shell;
    if (shell == null) throw StateError('应用信息服务没有就绪');
    final readClock = Stopwatch()..start();
    await shell.write(utf8.encode('LIST\n'));
    final summaries = <FireAppSummary>[];
    final labels = <String, String>{};
    var catalogSent = false;

    void sendCatalog() {
      if (catalogSent) return;
      catalogSent = true;
      timing.listMs = readClock.elapsedMilliseconds;
      timing.readMs = timing.listMs;
      onCatalog?.call(List<FireAppSummary>.of(summaries), timing);
    }

    List<FireAppSummary> withNames() {
      if (labels.isEmpty) return List<FireAppSummary>.of(summaries);
      return <FireAppSummary>[
        for (final item in summaries)
          switch (labels[item.packageName]) {
            final name? => item.withLabel(name),
            _ => item,
          },
      ];
    }

    void sendNames() {
      if (labels.isEmpty) return;
      timing.readMs = readClock.elapsedMilliseconds;
      timing.nameMs = timing.readMs - timing.listMs;
      onNames?.call(withNames(), timing);
    }

    while (true) {
      final FireAppFrame frame;
      try {
        frame = await _next().timeout(const Duration(seconds: 60));
      } on StateError catch (error) {
        await _dropShell();
        if (summaries.isEmpty || !'$error'.contains('应用信息服务已结束')) {
          rethrow;
        }
        log.warning('应用列表提前结束，已收到 ${summaries.length} 个', error);
        sendCatalog();
        final named = withNames();
        if (labels.isNotEmpty) sendNames();
        timing.readMs = readClock.elapsedMilliseconds;
        return FireAppListLoad(summaries: named, timing: timing);
      }
      if (frame is FireAppSummary) {
        summaries.add(frame);
        continue;
      }
      if (frame is FireAppCatalogDone) {
        sendCatalog();
        continue;
      }
      if (frame is FireAppLabel) {
        if (!catalogSent) sendCatalog();
        final name = frame.label.trim();
        if (name.isNotEmpty) labels[frame.packageName] = name;
        continue;
      }
      if (frame is FireAppLabelsDone) {
        if (!catalogSent) sendCatalog();
        final named = withNames();
        sendNames();
        return FireAppListLoad(summaries: named, timing: timing);
      }
      if (frame is FireAppServiceError) {
        throw StateError(frame.message.isEmpty ? '读取应用列表失败' : frame.message);
      }
      throw StateError('应用列表响应无效');
    }
  }

  Future<FireAppShow> _showBody(
    ConnectedDevice device,
    String packageName,
  ) async {
    await _ensureShell(device);
    final shell = _shell;
    if (shell == null) throw StateError('应用信息服务没有就绪');
    await shell.write(utf8.encode('SHOW $packageName\n'));
    final frame = await _next().timeout(const Duration(seconds: 20));
    if (frame is FireAppShow) return frame;
    if (frame is FireAppServiceError) {
      throw StateError(frame.message.isEmpty ? '读取应用信息失败' : frame.message);
    }
    throw StateError('应用信息响应无效');
  }

  Future<({int jarMs, int readyMs})> _ensureShell(
    ConnectedDevice device,
  ) async {
    if (_shell != null) return (jarMs: 0, readyMs: 0);
    final clock = Stopwatch()..start();
    await ensureFireAppService(device);
    final jarMs = clock.elapsedMilliseconds;
    clock.reset();
    final shell = await device.openExec(
      fireAppServiceCommand(fireAppServiceRemotePath),
    );
    _shell = shell;
    _listen(shell);
    try {
      final ready = await _next().timeout(const Duration(seconds: 30));
      if (ready is FireAppServiceError) {
        throw StateError(ready.message.isEmpty ? '应用信息服务启动失败' : ready.message);
      }
      if (ready is! FireAppReady) {
        throw StateError('应用信息服务没有就绪');
      }
      return (jarMs: jarMs, readyMs: clock.elapsedMilliseconds);
    } catch (error) {
      await _dropShell();
      rethrow;
    }
  }

  void _listen(ConnectedShell shell) {
    final epoch = ++_listenEpoch;
    _reader = FireAppFrameReader();
    _frames.clear();
    _subscription = shell.readStream.listen(
      (chunk) {
        if (epoch != _listenEpoch) return;
        final reader = _reader;
        if (reader == null) return;
        try {
          _frames.addAll(reader.add(chunk));
        } catch (error, stackTrace) {
          final pending = _wait;
          if (pending != null && !pending.isCompleted) {
            pending.completeError(error, stackTrace);
          }
          return;
        }
        final pending = _wait;
        if (pending != null && !pending.isCompleted) pending.complete();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (epoch != _listenEpoch) return;
        final pending = _wait;
        if (pending != null && !pending.isCompleted) {
          pending.completeError(error, stackTrace);
        }
      },
      onDone: () {
        if (epoch != _listenEpoch) return;
        final pending = _wait;
        if (pending != null && !pending.isCompleted) {
          pending.completeError(StateError('应用信息服务已结束'));
        }
      },
    );
  }

  Future<FireAppFrame> _next() async {
    while (_frames.isEmpty) {
      final pending = Completer<void>();
      _wait = pending;
      if (_frames.isNotEmpty && !pending.isCompleted) pending.complete();
      try {
        await pending.future;
      } finally {
        if (identical(_wait, pending)) _wait = null;
      }
    }
    return _frames.removeAt(0);
  }

  void _bumpSession() {
    _session++;
    _idle?.cancel();
    _idle = null;
  }

  void _scheduleIdle() {
    _idle?.cancel();
    final session = _session;
    _idle = Timer(const Duration(seconds: 20), () {
      unawaited(
        _run(() async {
          if (session != _session) return;
          await _quit();
        }),
      );
    });
  }

  Future<void> _quit() async {
    final shell = _shell;
    if (shell == null) return;
    try {
      await shell
          .write(utf8.encode('QUIT\n'))
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
    await _dropShell();
  }

  Future<void> _dropShell() async {
    _listenEpoch++;
    final subscription = _subscription;
    final shell = _shell;
    _subscription = null;
    _shell = null;
    _reader = null;
    _frames.clear();
    final pending = _wait;
    _wait = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('应用信息服务已结束'));
    }
    await subscription?.cancel();
    if (shell == null) return;
    try {
      await shell.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
}
