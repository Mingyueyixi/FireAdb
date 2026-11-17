import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:libadb/libadb.dart';

import '../appservice/fire_app_launch.dart';
import '../appservice/fire_app_session.dart';
import '../appservice/protocol/fire_app_message.dart';
import '../connection/model/connected_device.dart';
import '../log/app_log.dart';

/// 每台手机上 adbd 监听的端口。桌面为每台设备另分配本机端口。
const int deviceLinkPort = 28170;

/// 已经在跑的应用服务另外听这个本机端口。后来的客户端从这里接入，不再起第二个进程。
const int deviceServicePort = 28171;

/// 设备上那个进程的标记。和 jar 里的路径一致。
const String fireAppServicePidPath = '/data/local/tmp/fire-app-service.pid';
const String fireAppServiceOwnerPath = '/data/local/tmp/fire-app-service.owner';

/// `cmdline` 里是不是常驻的应用服务。短命的录屏进程不是。
bool fireAppServiceProcess(String cmdline) {
  final text = cmdline.replaceAll('\u0000', ' ');
  if (text.contains('ScreenRecorder') || text.contains(' LIST')) return false;
  return text.contains('com.fire.adb.appservice.FireAppService');
}

/// 手机应用和 FireAppService 连上桌面后的第一条消息。
const String linkHelloName = 'session.hello';

/// 一条已经通过 hello 的连接。
class LinkPeer {
  LinkPeer(this.socket);

  final Socket socket;
  final Map<int, Completer<FireDataResponse>> pending =
      <int, Completer<FireDataResponse>>{};
  Future<void> writeChain = Future<void>.value();
  var nextId = 1;

  Future<void> write(List<int> bytes) {
    final done = Completer<void>();
    writeChain = writeChain.catchError((Object _) {}).then((_) async {
      try {
        socket.add(bytes);
        await socket.flush();
        if (!done.isCompleted) done.complete();
      } catch (error, stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      }
    });
    return done.future;
  }

  void failPending(Object error) {
    final waiting = pending.values.toList();
    pending.clear();
    for (final waiter in waiting) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
  }
}

/// 桌面侧：每台设备一个本机端口。连上来的第一条必须是 hello。
class DeviceLink {
  DeviceLink._();

  static final Map<String, _DeviceDoor> _doors = <String, _DeviceDoor>{};
  static var _peerSpliceInstalled = false;

  static void Function(String serial, FireDataResponse frame)? onAppFrame;

  /// 手机上的聊天应用连上或断开。ADB 连着不等于这条链路通着。
  static void Function(String serial, bool up)? onAppLink;

  static bool serviceReady(String serial) => _doors[serial]?.service != null;

  static bool appReady(String serial) => _doors[serial]?.app != null;

  /// 这台设备上聊天应用在 hello 里报的身份。断开后为空。
  static String? appSelfIdOf(String serial) {
    final id = _doors[serial]?.appSelfId ?? '';
    return id.isEmpty ? null : id;
  }

  static Future<void> open(ConnectedDevice device) {
    return _door(device).open();
  }

  /// 保证设备上的常驻进程在听 `127.0.0.1:28171`。不等反向会话的 `session.ready`。
  static Future<void> ensureDaemon(ConnectedDevice device) {
    return _door(device).ensureDaemon();
  }

  static Future<void> close(String serial) async {
    final door = _doors.remove(serial);
    if (door == null) return;
    await door.close();
  }

  static Future<void> replyApp(
    String serial,
    int id,
    String name,
    Object body,
  ) async {
    final peer = _doors[serial]?.app;
    if (peer == null || id == 0) return;
    await peer.write(FireDataRequest.json(name: name, id: id, body: body).bytes);
  }

  static Future<FireDataResponse> exchangeApp(
    String serial,
    FireDataRequest Function(int id) build,
  ) {
    final door = _doors[serial];
    final peer = door?.app;
    if (door == null || peer == null) {
      throw StateError('聊天通道还没接上');
    }
    return door.exchange(peer, build);
  }

  static Future<void> writeService(String serial, List<int> bytes) async {
    final peer = _doors[serial]?.service;
    if (peer == null) throw StateError('应用信息服务没有就绪');
    await peer.write(bytes);
  }

  static _DeviceDoor _door(ConnectedDevice device) {
    return _doors.putIfAbsent(device.serial, () => _DeviceDoor(device));
  }

  static void _installSplice() {
    if (_peerSpliceInstalled) return;
    _peerSpliceInstalled = true;
    AdbConnection.onPeerOpen = (AdbStream stream, String destination) {
      final port = _splicePort(stream, destination);
      if (port == null) {
        unawaited(stream.close());
        return;
      }
      unawaited(_splice(stream, port));
    };
  }

  /// 设备回连的目标必须是这台设备已经在听的本机端口。
  /// 打开帧里的端口对不上时，仍交到该连接对应的门口。
  static int? _splicePort(AdbStream stream, String destination) {
    for (final door in _doors.values) {
      final adb = door.device.adbConnection;
      final host = door.hostPort;
      if (adb != null && host != null && identical(adb, stream.connection)) {
        return host;
      }
    }
    return _tcpPort(destination);
  }

  static int? _tcpPort(String destination) {
    if (!destination.startsWith('tcp:')) return null;
    final spec = destination.substring('tcp:'.length);
    final port = int.tryParse(spec.split(':').first);
    if (port == null || port <= 0) return null;
    return port;
  }

  static Future<void> _splice(AdbStream stream, int port) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 3),
      );
      var toLocal = Future<void>.value();
      final fromDevice = stream.readStream().listen(
        (chunk) {
          toLocal = toLocal.catchError((Object _) {}).then((_) async {
            try {
              socket.add(chunk);
              await socket.flush();
            } catch (error, stack) {
              log.warning('设备回连写到本机失败', error, stack);
              socket.destroy();
            }
          });
        },
        onDone: () {
          socket.destroy();
        },
        onError: (Object error, StackTrace stack) {
          log.warning('设备回连写到本机失败', error, stack);
          socket.destroy();
        },
      );
      var chain = Future<void>.value();
      socket.listen(
        (chunk) {
          chain = chain.catchError((Object _) {}).then((_) async {
            var offset = 0;
            while (offset < chunk.length) {
              final end = offset + 240 * 1024 < chunk.length
                  ? offset + 240 * 1024
                  : chunk.length;
              await stream.write(chunk.sublist(offset, end));
              offset = end;
            }
          });
        },
        onDone: () {
          unawaited(fromDevice.cancel());
          unawaited(stream.close());
        },
        onError: (Object _) {
          unawaited(fromDevice.cancel());
          unawaited(stream.close());
        },
      );
    } catch (error, stack) {
      log.warning('反向连接没有交到本机端口 $port', error, stack);
      unawaited(stream.close());
    }
  }
}

class _DeviceDoor {
  _DeviceDoor(this.device);

  final ConnectedDevice device;
  ServerSocket? _server;
  ConnectedShell? _exec;
  ConnectedShell? _attached;
  int? hostPort;
  String? token;
  var _adoptToken = false;
  Future<void>? _claiming;
  LinkPeer? service;
  LinkPeer? app;
  String? appSelfId;
  var _reversed = false;
  Future<void>? _opening;

  Future<void> open() {
    final pending = _opening;
    if (pending != null) return pending;
    final done = _start();
    _opening = done.whenComplete(() {
      if (identical(_opening, done)) _opening = null;
    });
    return done;
  }

  /// 进程不在时清掉留下的占位并重新拉起。不等反向会话。
  Future<void> ensureDaemon() async {
    if (await _serviceAlive()) return;
    await _releaseClaim();
    if (!await _claimOwner()) {
      if (await _serviceAlive()) return;
      await _releaseClaim();
      if (!await _claimOwner()) return;
    }
    try {
      token ??= _newToken();
      await _spawnDaemon(token!);
      for (var attempt = 0; attempt < 15; attempt++) {
        if (await _serviceAlive()) return;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      log.warning('应用服务没有留在后台 ${device.serial}');
      if (!await _serviceAlive()) await _releaseClaim();
    } catch (error, stack) {
      log.warning('应用服务没有启动 ${device.serial}', error, stack);
      if (!await _serviceAlive()) await _releaseClaim();
    }
  }

  Future<void> _start() async {
    DeviceLink._installSplice();
    if (_server == null) {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      hostPort = server.port;
      token = _newToken();
      server.listen(_onClient, onError: (Object error, StackTrace stack) {
        log.warning('链接端口 ${device.serial} 断开', error, stack);
      });
    }
    final port = hostPort;
    final secret = token;
    if (port == null || secret == null) return;
    if (_exec != null || _attached != null || service != null) {
      if (await _serviceAlive()) return;
      await _dropStaleService();
    }
    final updated = await ensureFireAppService(device);
    if (updated) await _stopService();
    if (await _serviceAlive()) {
      await _attachRunning();
      return;
    }
    if (!await _claimOwner()) {
      if (await _serviceAlive()) {
        await _attachRunning();
        return;
      }
      await _releaseClaim();
      if (!await _claimOwner()) {
        if (await _waitForService()) {
          await _joinWithRetry();
          return;
        }
        return;
      }
    }
    try {
      await _ensureReverse();
      await _spawnDaemon(secret);
      for (var attempt = 0; attempt < 25; attempt++) {
        if (service != null) return;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      if (await _serviceAlive()) {
        await _joinWithRetry();
        return;
      }
      await _releaseClaim();
    } catch (error) {
      if (!await _serviceAlive()) await _releaseClaim();
      rethrow;
    }
  }

  /// 进程已经没了，但门口还记着上一条连接。
  Future<void> _dropStaleService() async {
    service?.failPending(StateError('应用信息服务已断开'));
    final socket = service?.socket;
    final attached = _attached;
    final exec = _exec;
    service = null;
    _attached = null;
    _exec = null;
    fireAppSession(device).markLinkDown();
    try {
      await socket?.close();
    } catch (_) {}
    try {
      await attached?.close();
    } catch (_) {}
    try {
      await exec?.close();
    } catch (_) {}
  }

  /// 换上新 jar 时停掉还在用旧代码的后台进程。
  Future<void> _stopService() async {
    try {
      final pid = (await device.shell('cat $fireAppServicePidPath')).trim();
      if (int.tryParse(pid) == null) return;
      final cmdline = await device.shell('cat /proc/$pid/cmdline');
      if (!fireAppServiceProcess(cmdline)) return;
      await device.shell('kill $pid');
    } catch (_) {}
    for (var attempt = 0; attempt < 20; attempt++) {
      if (!await _serviceAlive()) {
        await _releaseClaim();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  /// 已经在跑的进程连过来，或从本机端口接上。不再另起一个。
  Future<void> _attachRunning() async {
    if (await _joinExisting()) return;
    await _ensureReverse();
    for (var attempt = 0; attempt < 15; attempt++) {
      if (service != null) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  /// 启动命令马上返回。shell 若一直开着，会占住这条 adb，两边的连接都会卡住。
  Future<void> _spawnDaemon(String secret) async {
    final command =
        '${fireAppServiceDaemonCommand(fireAppServiceRemotePath, argument: 'link=$deviceLinkPort token=$secret')}; '
        'echo fire-app-started';
    final shell = await device.openShell(command);
    try {
      await collectServiceText(shell.readStream);
    } catch (error, stack) {
      log.warning('后台服务启动没有立刻返回 ${device.serial}', error, stack);
    } finally {
      await shell.close();
    }
  }

  Future<void> _ensureReverse() async {
    if (_reversed) return;
    final port = hostPort;
    if (port == null) return;
    try {
      await device.reverse(
        remote: 'tcp:$deviceLinkPort',
        local: 'tcp:$port',
      );
      _reversed = true;
    } catch (error, stack) {
      log.warning('登记反向端口失败 ${device.serial}', error, stack);
    }
  }

  /// pid 文件里的进程还在，并且命令行是常驻的应用服务。
  /// `cat` 读完 `/proc/pid/cmdline` 就退出。
  Future<bool> _serviceAlive() async {
    try {
      final cmdline = await device.shell(
        'cat /proc/\$(cat $fireAppServicePidPath)/cmdline',
      );
      return fireAppServiceProcess(cmdline);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _claimOwner() async {
    try {
      final text = await device.shell(
        'mkdir $fireAppServiceOwnerPath 2>/dev/null && echo owner || echo busy',
      );
      return text.contains('owner');
    } catch (_) {
      return false;
    }
  }

  Future<void> _releaseClaim() async {
    try {
      await device.shell('rmdir $fireAppServiceOwnerPath');
    } catch (_) {}
  }

  Future<bool> _waitForService() async {
    for (var attempt = 0; attempt < 40; attempt++) {
      if (await _serviceAlive()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  Future<void> _joinWithRetry() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (await _joinExisting()) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  /// 连 `28171`。端口没人听时尽快返回，避免把同一条 ADB 上的 getprop 堵住。
  Future<ConnectedShell?> _openLocalService() async {
    final opened = device.openService('tcp:$deviceServicePort');
    try {
      return await opened.timeout(const Duration(milliseconds: 800));
    } catch (error, stack) {
      unawaited(
        opened.then<void>(
          (shell) => shell.close(),
          onError: (Object _) {},
        ),
      );
      log.warning('没有连上已有的应用服务 ${device.serial}', error, stack);
      return null;
    }
  }

  /// 连到已经在听的本机端口，把字节送进自己的门口。不改设备上的反向端口。
  Future<bool> _joinExisting() async {
    final port = hostPort;
    if (port == null) return false;
    final remote = await _openLocalService();
    if (remote == null) return false;
    final Socket socket;
    try {
      socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    } catch (error, stack) {
      log.warning('没有把已有应用服务交到本机 ${device.serial}', error, stack);
      await remote.close();
      return false;
    }
    _adoptToken = true;
    _attached = remote;
    var toLocal = Future<void>.value();
    var toDevice = Future<void>.value();
    remote.readStream.listen(
      (chunk) {
        toLocal = toLocal.catchError((Object _) {}).then((_) async {
          try {
            socket.add(chunk);
            await socket.flush();
          } catch (error, stack) {
            log.warning('已有应用服务写到本机失败 ${device.serial}', error, stack);
            socket.destroy();
          }
        });
      },
      onDone: () {
        socket.destroy();
        if (identical(_attached, remote)) _attached = null;
      },
      onError: (Object error, StackTrace stack) {
        log.warning('已有应用服务断开 ${device.serial}', error, stack);
        socket.destroy();
        if (identical(_attached, remote)) _attached = null;
      },
    );
    socket.listen(
      (chunk) {
        toDevice = toDevice.catchError((Object _) {}).then((_) {
          return remote.write(chunk);
        });
      },
      onDone: () {
        unawaited(remote.close());
      },
      onError: (Object _) {
        unawaited(remote.close());
      },
    );
    return true;
  }

  /// 拉起方已经离开。把反向端口改到自己这边，进程会重新连上来。
  void _claimReverse() {
    final pending = _claiming;
    if (pending != null) return;
    final done = _claimReverseNow();
    _claiming = done.whenComplete(() {
      if (identical(_claiming, done)) _claiming = null;
    });
  }

  Future<void> _claimReverseNow() async {
    for (var attempt = 0; attempt < 10; attempt++) {
      if (_reversed) return;
      final port = hostPort;
      if (port == null) return;
      try {
        await device.reverse(
          remote: 'tcp:$deviceLinkPort',
          local: 'tcp:$port',
        );
        _reversed = true;
        log.info('已接过应用服务端口 ${device.serial}');
        return;
      } catch (error, stack) {
        log.warning('接过应用服务端口失败 ${device.serial}', error, stack);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
  }

  Future<void> close() async {
    service?.failPending(StateError('应用信息服务已结束'));
    app?.failPending(StateError('聊天通道已断开'));
    final serviceSocket = service?.socket;
    final appSocket = app?.socket;
    service = null;
    app = null;
    appSelfId = null;
    _reversed = false;
    final server = _server;
    final exec = _exec;
    final attached = _attached;
    _server = null;
    _exec = null;
    _attached = null;
    hostPort = null;
    try {
      await serviceSocket?.close();
    } catch (_) {}
    try {
      await appSocket?.close();
    } catch (_) {}
    try {
      await server?.close();
    } catch (_) {}
    try {
      await attached?.close();
    } catch (_) {}
    if (exec == null) return;
    try {
      await exec.close();
    } catch (_) {}
  }

  Future<FireDataResponse> exchange(
    LinkPeer peer,
    FireDataRequest Function(int id) build,
  ) async {
    final id = peer.nextId++;
    final waiter = Completer<FireDataResponse>();
    peer.pending[id] = waiter;
    try {
      await peer.write(build(id).bytes);
      final reply = await waiter.future.timeout(const Duration(seconds: 20));
      if (reply.name == 'session.error') {
        throw StateError(reply.errorText('聊天没有送达'));
      }
      return reply;
    } catch (error) {
      final current = peer.pending[id];
      if (identical(current, waiter)) peer.pending.remove(id);
      rethrow;
    }
  }

  void _onClient(Socket socket) {
    final reader = FireDataResponseReader();
    LinkPeer? peer;
    var accepted = false;
    socket.listen(
      (chunk) {
        final List<FireDataResponse> frames;
        try {
          frames = reader.add(chunk);
        } catch (error, stack) {
          log.warning('链接帧无效 ${device.serial}', error, stack);
          socket.destroy();
          return;
        }
        for (final frame in frames) {
          if (!accepted) {
            peer = _accept(socket, frame);
            accepted = peer != null;
            if (!accepted) {
              socket.destroy();
              return;
            }
            continue;
          }
          _dispatch(peer!, frame);
        }
      },
      onError: (Object error, StackTrace stack) {
        log.warning('链接断开 ${device.serial}', error, stack);
        _drop(peer, socket);
      },
      onDone: () {
        _drop(peer, socket);
      },
    );
  }

  LinkPeer? _accept(Socket socket, FireDataResponse frame) {
    if (frame.name != linkHelloName) return null;
    final role = '${frame.json['role'] ?? ''}';
    final secret = '${frame.json['token'] ?? ''}';
    if (secret.isEmpty) return null;
    if (role != 'service' && role != 'app') return null;
    // 已经在后台的进程带着自己的口令连上来。门口原先生成的口令作废，
    // 否则手机会一直用链接文件里的口令，被这边拒绝。
    if (role == 'service' && service == null) {
      token = secret;
      _adoptToken = false;
    } else if (_adoptToken) {
      token = secret;
      _adoptToken = false;
    } else if (secret != token) {
      log.info('拒绝接入 ${device.serial} $role');
      return null;
    }
    final peer = LinkPeer(socket);
    if (role == 'service') {
      service?.socket.destroy();
      service?.failPending(StateError('应用信息服务已重连'));
      service = peer;
    } else {
      app?.socket.destroy();
      app?.failPending(StateError('聊天通道已重连'));
      app = peer;
      appSelfId = '${frame.json['selfId'] ?? ''}';
      DeviceLink.onAppLink?.call(device.serial, true);
    }
    log.info('已接入 ${device.serial} $role');
    return peer;
  }

  void _dispatch(LinkPeer peer, FireDataResponse frame) {
    if (frame.name == 'session.release' && frame.id == 0) {
      if (identical(peer, service)) _claimReverse();
      return;
    }
    if (frame.id != 0) {
      final waiter = peer.pending.remove(frame.id);
      if (waiter != null && !waiter.isCompleted) {
        waiter.complete(frame);
        return;
      }
    }
    if (identical(peer, service)) {
      fireAppSession(device).ingest(frame);
      return;
    }
    final listener = DeviceLink.onAppFrame;
    if (listener != null) listener(device.serial, frame);
  }

  void _drop(LinkPeer? peer, Socket socket) {
    if (peer == null) return;
    peer.failPending(StateError('链接已断开'));
    if (identical(service, peer)) {
      service = null;
      fireAppSession(device).markLinkDown();
    }
    if (identical(app, peer)) {
      app = null;
      appSelfId = null;
      log.info('聊天应用链路断开 ${device.serial}');
      DeviceLink.onAppLink?.call(device.serial, false);
    }
    socket.destroy();
  }
}

String _newToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
