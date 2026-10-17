import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:logging/logging.dart';

import 'libusb_loader.dart';

final Logger _usbLog = Logger('fire_adb.usb');

/// C 层会话信息，对应 `fire_usb_info`。
final class FireUsbInfo extends Struct {
  external Pointer<Void> context;
  external Pointer<Void> handle;
  @Int32()
  external int interfaceNumber;
  @Int32()
  external int endpointIn;
  @Int32()
  external int endpointOut;
  @Int32()
  external int maxPacketSize;
  @Array(256)
  external Array<Uint8> serial;
  @Array(128)
  external Array<Uint8> portPath;
}

typedef _OpenNative =
    Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<FireUsbInfo>);
typedef _OpenDart =
    int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<FireUsbInfo>);
typedef _CloseNative = Int32 Function(Pointer<Utf8>);
typedef _CloseDart = int Function(Pointer<Utf8>);
typedef _CloseAllNative = Int32 Function();
typedef _CloseAllDart = int Function();
typedef _IsOpenNative = Int32 Function(Pointer<Utf8>);
typedef _IsOpenDart = int Function(Pointer<Utf8>);

/// 进程内 USB 句柄表。热重启后仍有效，由这份 native 库释放。
class FireUsb {
  FireUsb._(
    this._open,
    this._close,
    this._closeAll,
    this._isOpen,
    this.transferCallback,
  );

  final _OpenDart _open;
  final _CloseDart _close;
  final _CloseAllDart _closeAll;
  final _IsOpenDart _isOpen;

  /// C `fire_usb_transfer_cb` — set as libusb_transfer.callback.
  final Pointer<NativeFunction<Void Function(Pointer<Void>)>>?
  transferCallback;

  static FireUsb? _instance;

  /// 加载 `fire_usb` 动态库。找不到返回 null。
  static FireUsb? tryLoad() {
    final existing = _instance;
    if (existing != null) return existing;
    final path = resolveFireUsbLibraryPath();
    if (path == null) return null;
    final library = DynamicLibrary.open(path);
    Pointer<NativeFunction<Void Function(Pointer<Void>)>>? callback;
    try {
      callback = library
          .lookup<NativeFunction<Void Function(Pointer<Void>)>>(
            'fire_usb_transfer_cb',
          );
    } on ArgumentError {
      _usbLog.warning('fire_usb 没有 transfer_cb，传输回调回退到 Dart');
    }
    final loaded = FireUsb._(
      library.lookupFunction<_OpenNative, _OpenDart>('fire_usb_open'),
      library.lookupFunction<_CloseNative, _CloseDart>('fire_usb_close'),
      library.lookupFunction<_CloseAllNative, _CloseAllDart>(
        'fire_usb_close_all',
      ),
      library.lookupFunction<_IsOpenNative, _IsOpenDart>('fire_usb_is_open'),
      callback,
    );
    _instance = loaded;
    return loaded;
  }

  /// 打开前先关掉同路径旧会话，再声明接口。
  FireUsbSession open(String portPath, {String? libusbPath}) {
    final libusb = libusbPath ?? resolveLibusbLibraryPath();
    if (libusb == null) {
      throw StateError('没有可用的 libusb');
    }
    final hadLeftover = isOpen(portPath);
    if (hadLeftover) {
      _usbLog.info('fire_usb 打开前表里还有旧句柄 $portPath，先释放');
    } else {
      _usbLog.info('fire_usb 打开前没有旧句柄 $portPath');
    }
    final info = calloc<FireUsbInfo>();
    final port = portPath.toNativeUtf8();
    final lib = libusb.toNativeUtf8();
    try {
      final code = _open(lib, port, info);
      if (code != 0) {
        _usbLog.warning('fire_usb_open($portPath) 失败：$code');
        throw StateError('fire_usb_open($portPath) 失败：$code');
      }
      final session = FireUsbSession(
        portPath: portPath,
        contextAddress: info.ref.context.address,
        handleAddress: info.ref.handle.address,
        interfaceNumber: info.ref.interfaceNumber,
        endpointIn: info.ref.endpointIn,
        endpointOut: info.ref.endpointOut,
        maxPacketSize: info.ref.maxPacketSize,
        serial: _arrayString(info.ref.serial, 256),
      );
      _usbLog.info(
        'fire_usb 已打开 $portPath '
        'handle=0x${session.handleAddress.toRadixString(16)} '
        'iface=${session.interfaceNumber}'
        '${hadLeftover ? '（已替换旧句柄）' : ''}',
      );
      return session;
    } finally {
      calloc.free(info);
      calloc.free(port);
      calloc.free(lib);
    }
  }

  /// 释放指定端口。返回是否关掉了一个会话。
  bool close(String portPath) {
    final port = portPath.toNativeUtf8();
    try {
      final closed = _close(port);
      if (closed > 0) {
        _usbLog.info('fire_usb 已释放句柄 $portPath');
        return true;
      }
      _usbLog.info('fire_usb 释放时没有句柄 $portPath');
      return false;
    } finally {
      calloc.free(port);
    }
  }

  int closeAll() {
    final closed = _closeAll();
    _usbLog.info('fire_usb close_all 释放了 $closed 个句柄');
    return closed;
  }

  bool isOpen(String portPath) {
    final port = portPath.toNativeUtf8();
    try {
      return _isOpen(port) != 0;
    } finally {
      calloc.free(port);
    }
  }
}

class FireUsbSession {
  const FireUsbSession({
    required this.portPath,
    required this.contextAddress,
    required this.handleAddress,
    required this.interfaceNumber,
    required this.endpointIn,
    required this.endpointOut,
    required this.maxPacketSize,
    required this.serial,
  });

  final String portPath;
  final int contextAddress;
  final int handleAddress;
  final int interfaceNumber;
  final int endpointIn;
  final int endpointOut;
  final int maxPacketSize;
  final String serial;
}

String _arrayString(Array<Uint8> bytes, int max) {
  final values = <int>[];
  for (var index = 0; index < max; index++) {
    final byte = bytes[index];
    if (byte == 0) break;
    values.add(byte);
  }
  return String.fromCharCodes(values);
}

/// `fire_usb` 动态库路径。优先环境变量，再找可执行文件旁边和 vendor。
String? resolveFireUsbLibraryPath() {
  final fromEnv = Platform.environment['FIRE_ADB_FIRE_USB'];
  if (fromEnv != null && fromEnv.isNotEmpty && File(fromEnv).existsSync()) {
    return fromEnv;
  }
  final name = Platform.isWindows
      ? 'fire_usb.dll'
      : Platform.isMacOS
      ? 'libfire_usb.dylib'
      : 'libfire_usb.so';
  final nextToExe = File(
    '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}$name',
  );
  if (nextToExe.existsSync()) return nextToExe.path;

  for (final root in _searchRoots()) {
    final os = Platform.isWindows
        ? 'windows'
        : Platform.isMacOS
        ? 'macos'
        : 'linux';
    final arch = _archFolder();
    final vendored = File(
      '$root${Platform.pathSeparator}vendor'
      '${Platform.pathSeparator}$os'
      '${Platform.pathSeparator}$arch'
      '${Platform.pathSeparator}$name',
    );
    if (vendored.existsSync()) return vendored.path;
  }
  return null;
}

Iterable<String> _searchRoots() sync* {
  final package = _packageRoot();
  if (package != null) yield package;
  var dir = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    final pubspec = File(
      '${dir.path}${Platform.pathSeparator}pubspec.yaml',
    );
    if (pubspec.existsSync()) {
      final name = File(
        '${dir.path}${Platform.pathSeparator}lib'
        '${Platform.pathSeparator}src'
        '${Platform.pathSeparator}fire_usb.dart',
      );
      if (name.existsSync()) {
        yield dir.path;
        break;
      }
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
}

String? _packageRoot() {
  final exe = File(Platform.resolvedExecutable).absolute.path;
  var dir = Directory(File(exe).parent.path);
  for (var i = 0; i < 12; i++) {
    final candidate = File(
      '${dir.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}libadb'
      '${Platform.pathSeparator}pubspec.yaml',
    );
    if (candidate.existsSync()) {
      return '${dir.path}${Platform.pathSeparator}packages'
          '${Platform.pathSeparator}libadb';
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

String _archFolder() {
  final arch = Platform.version.contains('arm64') ||
          Platform.version.contains('aarch64')
      ? 'arm64'
      : 'x64';
  if (Platform.isWindows) {
    final processArch = Platform.environment['PROCESSOR_ARCHITECTURE'] ?? '';
    if (processArch.toUpperCase().contains('ARM64')) return 'arm64';
  }
  return arch;
}
