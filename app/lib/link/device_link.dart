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

  static Future<void> close(String serial) async {
    final door = _doors.remove(serial);
    if (door == null) return;
    await door.close();
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
      final fromDevice = stream.readStream().listen(
        (chunk) {
          socket.add(chunk);
        },
        onDone: () {
          socket.destroy();
        },
        onError: (Object _) {
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
  int? hostPort;
  String? token;
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
    if (!_reversed) {
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
    if (_exec != null) return;
    await ensureFireAppService(device);
    _exec = await device.openExec(
      fireAppServiceCommand(
        fireAppServiceRemotePath,
        argument: 'link=$deviceLinkPort token=$secret',
      ),
    );
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
    _server = null;
    _exec = null;
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
    if (secret.isEmpty || secret != token) return null;
    if (role != 'service' && role != 'app') return null;
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
