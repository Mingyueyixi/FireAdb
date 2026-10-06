import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adb_core/adb_core.dart';

import '../../../connection/model/connected_device.dart';
import '../../../files/remote_file_export.dart';
import '../bean/app_freeze.dart';
import '../bean/installed_app.dart';
import '../source/app_inventory.dart';

/// 通过 ADB shell / sync 读取并管理设备应用。
class DeviceAppRepository {
  DeviceAppRepository(this._device);

  final ConnectedDevice _device;
  var _cancelled = false;
  ConnectedShell? _shellSession;
  ConnectedSync? _syncSession;
  static const _shellTimeout = Duration(seconds: 20);
  static const _slowShellTimeout = Duration(seconds: 60);

  /// 首屏列出用户应用和 APK 路径。名称、图标、版本和体积在行显示时再取。
  Future<List<InstalledApp>> listApps() async {
    final listed = parsePmListPackages(
      await _device
          .shell(pmListUserPackagesCommand())
          .timeout(_slowShellTimeout),
      withPath: true,
    );
    final apps = listed.values.toList()
      ..sort(
        (a, b) =>
            a.packageName.toLowerCase().compareTo(b.packageName.toLowerCase()),
      );
    return apps;
  }

  /// 系统应用（含路径）与已停用包。不含 `dumpsys package`。
  Future<
    ({
      Set<String> systemPackages,
      Map<String, List<String>> systemPaths,
      Set<String> disabledPackages,
    })
  >
  loadPackageFlags() async {
    final output = await _device
        .shell(pmListFlagsCommand())
        .timeout(_slowShellTimeout);
    return parsePmFlagLists(output);
  }

  /// 按已有路径补体积。
  Future<List<InstalledApp>> loadPackageSizes(List<InstalledApp> apps) {
    return _fillSizes(apps);
  }

  Future<List<InstalledApp>> _fillSizes(List<InstalledApp> apps) async {
    final files = <String>[];
    final dirs = <String>[];
    for (final app in apps) {
      final path = app.primaryPath;
      if (path == null || path.isEmpty) continue;
      (path.toLowerCase().endsWith('.apk') ? files : dirs).add(path);
    }
    final sizes = <String, int>{};
    await _collectStatSizes(files, sizes);
    await _collectDuSizes(dirs, sizes);
    if (sizes.isEmpty) return apps;
    return [
      for (var i = 0; i < apps.length; i++)
        apps[i].copyWith(sizeBytes: sizes[apps[i].primaryPath]),
    ];
  }

  Future<void> _collectStatSizes(
    List<String> files,
    Map<String, int> sizes,
  ) async {
    const chunkSize = 20;
    for (var offset = 0; offset < files.length; offset += chunkSize) {
      final chunk = files.sublist(
        offset,
        offset + chunkSize > files.length ? files.length : offset + chunkSize,
      );
      final args = chunk.map(quoteShellArg).join(' ');
      try {
        final output = await _device
            .shell('stat -c \'%s %n\' $args')
            .timeout(_shellTimeout);
        for (final raw in const LineSplitterCompat().convert(output)) {
          final line = raw.trim();
          final space = line.indexOf(' ');
          if (space <= 0) continue;
          final size = int.tryParse(line.substring(0, space));
          final path = line.substring(space + 1);
          if (size != null) sizes[path] = size;
        }
      } catch (_) {
        // 单批失败不影响列表。
      }
    }
  }

  Future<void> _collectDuSizes(
    List<String> dirs,
    Map<String, int> sizes,
  ) async {
    const chunkSize = 15;
    for (var offset = 0; offset < dirs.length; offset += chunkSize) {
      final chunk = dirs.sublist(
        offset,
        offset + chunkSize > dirs.length ? dirs.length : offset + chunkSize,
      );
      final args = chunk.map(quoteShellArg).join(' ');
      try {
        final output = await _device
            .shell('du -sb $args')
            .timeout(_shellTimeout);
        for (final raw in const LineSplitterCompat().convert(output)) {
          final line = raw.trim();
          final tab = line.indexOf('\t');
          final space = line.indexOf(' ');
          final sep = tab >= 0 ? tab : space;
          if (sep <= 0) continue;
          final size = int.tryParse(line.substring(0, sep));
          final path = line.substring(sep + 1).trim();
          if (size != null) sizes[path] = size;
        }
      } catch (_) {}
    }
  }

  /// 关掉当前这条 shell 或 sync 连接，读取会马上结束。
  Future<void> abort() async {
    _cancelled = true;
    final shell = _shellSession;
    final sync = _syncSession;
    _shellSession = null;
    _syncSession = null;
    try {
      await shell?.close();
    } catch (_) {}
    try {
      await sync?.close();
    } catch (_) {}
  }

  Future<AdbFileStat> _stat(String path) async {
    final sync = await _device.openSync();
    _syncSession = sync;
    try {
      if (_cancelled) throw const AppOperationCancelled();
      final stat = await sync.client.stat(path);
      if (_cancelled) throw const AppOperationCancelled();
      await sync.client.quit();
      return stat;
    } catch (error) {
      if (_cancelled) throw const AppOperationCancelled();
      rethrow;
    } finally {
      if (identical(_syncSession, sync)) _syncSession = null;
      await sync.close();
    }
  }

  Future<int> _pullTo(
    String path,
    IOSink sink, {
    void Function(int done, int total)? onProgress,
  }) async {
    final sync = await _device.openSync();
    _syncSession = sync;
    try {
      if (_cancelled) throw const AppOperationCancelled();
      final received = await sync.client.pullTo(
        path,
        sink,
        onProgress: onProgress,
      );
      if (_cancelled) throw const AppOperationCancelled();
      try {
        await sync.client.quit();
      } catch (_) {}
      return received;
    } catch (error) {
      if (_cancelled) throw const AppOperationCancelled();
      rethrow;
    } finally {
      if (identical(_syncSession, sync)) _syncSession = null;
      await sync.close();
    }
  }

  Future<String> _shell(String command, {Duration? timeout}) async {
    final shell = await _device.openShell(command);
    _shellSession = shell;
    try {
      if (_cancelled) throw const AppOperationCancelled();
      final bytes = await shell.readStream
          .expand((chunk) => chunk)
          .toList()
          .timeout(timeout ?? _shellTimeout);
      if (_cancelled) throw const AppOperationCancelled();
      return utf8.decode(bytes, allowMalformed: true);
    } catch (error) {
      if (_cancelled) throw const AppOperationCancelled();
      rethrow;
    } finally {
      if (identical(_shellSession, shell)) _shellSession = null;
      await shell.close();
    }
  }

  Future<void> uninstall(String packageName, {bool keepData = false}) async {
    final options = keepData ? ' -k' : '';
    final output = await _shell(
      'pm uninstall$options ${quoteShellArg(packageName)}',
    );
    ensurePmSuccess(output);
  }

  Future<void> setFrozen(
    String packageName, {
    required bool frozen,
    required AppFreezeMethod method,
  }) async {
    final command = frozen
        ? method.freezeCommand(packageName)
        : method.unfreezeCommand(packageName);
    final output = await _shell(command);
    ensureFreezeCommandSuccess(output);
  }

  /// 尝试列出被 `am freeze` 冻结的包名；旧系统或无 freezer dumpsys 时返回空。
  Future<Set<String>> listAmFrozenPackages() async {
    try {
      final output = await _device
          .shell('dumpsys activity freezer')
          .timeout(_shellTimeout);
      return parseAmFrozenPackages(output);
    } catch (_) {
      return const <String>{};
    }
  }

  /// 解析要导出的 APK，并用 `stat` 得到每个文件的大小。
  Future<List<AppExportFile>> listExportFiles(
    InstalledApp app, {
    bool Function()? isCancelled,
  }) async {
    if (_cancelled || isCancelled?.call() == true) {
      throw const AppOperationCancelled();
    }
    var paths = parsePmPath(
      await _shell('pm path ${quoteShellArg(app.packageName)}'),
    );
    if (paths.isEmpty) {
      paths = app.apkPaths
          .where((p) => p.toLowerCase().endsWith('.apk'))
          .toList();
    }
    if (paths.isEmpty) {
      throw StateError('未找到可导出的 APK 路径');
    }
    final files = <AppExportFile>[];
    for (final remote in paths) {
      if (_cancelled || isCancelled?.call() == true) {
        throw const AppOperationCancelled();
      }
      final stat = await _stat(remote);
      files.add(AppExportFile(remote: remote, size: stat.size));
    }
    return files;
  }

  Future<List<File>> exportToDirectory(
    InstalledApp app,
    String directory, {
    List<AppExportFile>? files,
    void Function(int bytesDone, int bytesTotal)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final planned =
        files ?? await listExportFiles(app, isCancelled: isCancelled);
    final bytesTotal = planned.fold<int>(0, (sum, file) => sum + file.size);
    if (isCancelled?.call() == true) throw const AppOperationCancelled();
    final destDir = Directory(directory);
    await destDir.create(recursive: true);
    final written = <File>[];
    final useSubdir = planned.length > 1;
    final packageDir = useSubdir
        ? Directory(
            '${destDir.path}${Platform.pathSeparator}${app.packageName}',
          )
        : destDir;
    if (useSubdir) await packageDir.create(recursive: true);
    var sent = 0;
    for (final file in planned) {
      if (_cancelled || isCancelled?.call() == true) {
        throw const AppOperationCancelled();
      }
      final name = file.remote.split('/').last;
      final local = File(
        useSubdir
            ? '${packageDir.path}${Platform.pathSeparator}$name'
            : '${destDir.path}${Platform.pathSeparator}${app.packageName}.apk',
      );
      final exported = await exportRemoteFile(
        remotePath: file.remote,
        localFile: local,
        shell: (command) => _shell(command),
        pullTo: (remote, sink, progress) =>
            _pullTo(remote, sink, onProgress: progress),
        onProgress: (done, _) {
          final current = sent + done;
          onProgress?.call(
            current > bytesTotal ? bytesTotal : current,
            bytesTotal,
          );
        },
        isCancelled: () => _cancelled || (isCancelled?.call() ?? false),
        cancelledException: () => const AppOperationCancelled(),
      );
      sent += file.size > 0 ? file.size : exported.bytes;
      if (sent > bytesTotal) sent = bytesTotal;
      onProgress?.call(sent, bytesTotal);
      written.add(local);
    }
    return written;
  }
}

/// 待导出的远端 APK 及其字节大小。
class AppExportFile {
  const AppExportFile({required this.remote, required this.size});

  final String remote;
  final int size;
}

/// 操作被取消。当前这条连接会被关掉，已经完成的文件不会回滚。
class AppOperationCancelled implements Exception {
  const AppOperationCancelled();
}
