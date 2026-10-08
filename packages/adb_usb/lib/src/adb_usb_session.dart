import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:adb_core/adb_core.dart';
import 'package:dart_libusb/dart_libusb.dart';
import 'package:ffi/ffi.dart';

import 'adb_usb_device.dart';
import 'adb_usb_match.dart';
import 'libusb_loader.dart';

const int _libusbErrorAccess = -3;
const int _libusbErrorBusy = -6;
const int _libusbErrorInterrupted = -10;
const int _writeTimeoutMs = 10000;
const int _readBufferSize = 16 * 1024;
const int _bulkTransfer = 2;
const int _transferRead = 1;
const int _transferWrite = 2;

/// 枚举带 ADB 接口的 USB 设备。没有 libusb 或当前不是桌面平台时抛出 [AdbUsbException]。
///
/// 枚举在后台 isolate 里做。libusb 的枚举是同步调用，放在界面线程上会挡住窗口启动。
Future<List<UsbAdbDevice>> listUsbAdbDevices() async {
  final libraryPath = resolveLibusbLibraryPath();
  if (libraryPath == null) {
    throw AdbUsbException('当前平台没有可用的 libusb。');
  }
  final row = await Isolate.run(() => _listUsbAdbDeviceRows(libraryPath));
  final error = row['error'];
  if (error is String) throw AdbUsbException(error);
  final devices = row['devices'];
  if (devices is! List) return const <UsbAdbDevice>[];
  return devices
      .whereType<Map>()
      .map((item) => UsbAdbDevice.fromRow(Map<String, Object?>.from(item)))
      .toList();
}

Map<String, Object?> _listUsbAdbDeviceRows(String libraryPath) {
  Libusb libusb;
  try {
    libusb = Libusb(DynamicLibrary.open(libraryPath));
  } on ArgumentError catch (error) {
    return <String, Object?>{'error': '无法加载 libusb（$libraryPath）：$error'};
  }
  Pointer<libusb_context>? context;
  try {
    context = _init(libusb);
    final devices = <UsbAdbDevice>[];
    final listOut = calloc<Pointer<Pointer<libusb_device>>>();
    try {
      final count = libusb.libusb_get_device_list(context, listOut);
      if (count < 0) {
        return <String, Object?>{
          'error': '枚举 USB 设备失败：${libusbErrorText(libusb, count)}',
        };
      }
      final list = listOut.value;
      for (var index = 0; index < count; index++) {
        final found = _describeDevice(libusb, list[index]);
        if (found != null) devices.add(found);
      }
      libusb.libusb_free_device_list(list, 1);
    } finally {
      calloc.free(listOut);
    }
    return <String, Object?>{
      'devices': devices.map((device) => device.toRow()).toList(),
    };
  } on AdbUsbException catch (error) {
    return <String, Object?>{'error': error.message};
  } finally {
    if (context != null) libusb.libusb_exit(context);
  }
}

/// 打开 [device] 的 ADB 批量接口。读写在同一个后台 isolate 里，靠 libusb 事件循环完成。
Future<AdbUsbTransport> openUsbAdbDevice(UsbAdbDevice device) async {
  final libraryPath = resolveLibusbLibraryPath();
  if (libraryPath == null) {
    throw AdbUsbException('当前平台没有可用的 libusb。');
  }
  final bootstrap = ReceivePort();
  final isolate = await Isolate.spawn(usbWorker, bootstrap.sendPort);
  final worker = await bootstrap.first as SendPort;
  bootstrap.close();
  final events = ReceivePort();
  final opened = Completer<Object?>();
  final transport = AdbUsbTransport._(isolate, worker, events, opened);
  worker.send(<Object?>['open', libraryPath, device.portPath, events.sendPort]);
  final Object? failure;
  try {
    failure = await opened.future.timeout(const Duration(seconds: 10));
  } on TimeoutException {
    await transport.close();
    throw AdbUsbException('打开 USB 设备超时。');
  }
  if (failure != null) {
    await transport.close();
    throw AdbUsbException('$failure');
  }
  return transport;
}

class AdbUsbTransport implements AdbTransport {
  AdbUsbTransport._(
    this._isolate,
    this._worker,
    this._events,
    Completer<Object?> opened,
  ) {
    _subscription = _events.listen((Object? message) {
      if (message is! List || message.isEmpty) return;
      switch (message.first) {
        case 'ready':
          final serial = message.length > 1 ? message[1] : null;
          if (serial is String && serial.trim().isNotEmpty) {
            serialNumber = serial.trim();
          }
          final contextAddress = message.length > 2 ? message[2] : null;
          final libraryPath = message.length > 3 ? message[3] : null;
          if (contextAddress is int && libraryPath is String) {
            _wakeLib = Libusb(DynamicLibrary.open(libraryPath));
            _wakeContext = Pointer<libusb_context>.fromAddress(contextAddress);
          }
          if (!opened.isCompleted) opened.complete(null);
        case 'data':
          final bytes = message[1];
          if (bytes is Uint8List && !_incoming.isClosed) {
            _incoming.add(bytes);
          }
        case 'error':
          if (!opened.isCompleted) {
            opened.complete(message.length > 1 ? message[1] : 'USB 打开失败');
            return;
          }
          if (!_incoming.isClosed) {
            _incoming.addError(AdbUsbException('${message[1]}'));
            unawaited(close());
          }
        case 'closed':
          if (!opened.isCompleted) opened.complete('USB 设备在打开前已关闭。');
          if (!_released.isCompleted) _released.complete();
          if (!_incoming.isClosed) unawaited(_incoming.close());
      }
    });
  }

  final Isolate _isolate;
  final SendPort _worker;
  final ReceivePort _events;
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  final Completer<void> _released = Completer<void>();
  StreamSubscription<dynamic>? _subscription;
  bool _closed = false;
  Libusb? _wakeLib;
  Pointer<libusb_context>? _wakeContext;

  /// USB 字符串描述符里的序列号。`adb devices` 用它，而不是端口路径。
  String? serialNumber;

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  Future<void> write(List<int> data) async {
    if (_closed) throw StateError('传输已关闭，无法写入');
    final reply = ReceivePort();
    _worker.send(<Object?>['write', Uint8List.fromList(data), reply.sendPort]);
    _interruptWorker();
    final result = await reply.first;
    reply.close();
    if (result is String) throw AdbUsbException(result);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _worker.send(<Object?>['close']);
    _interruptWorker();
    try {
      await _released.future.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // 取消传输后事件循环仍没退出时，强制结束 isolate。
    }
    await _subscription?.cancel();
    _events.close();
    if (!_incoming.isClosed) await _incoming.close();
    _wakeContext = null;
    _wakeLib = null;
    _isolate.kill();
  }

  /// 工作 isolate 堵在 `libusb_handle_events` 里时，靠它从别的线程把等待打断。
  void _interruptWorker() {
    final libusb = _wakeLib;
    final context = _wakeContext;
    if (libusb == null || context == null) return;
    libusb.libusb_interrupt_event_handler(context);
  }
}

/// 一台设备一个 isolate：提交批量传输后堵在 `libusb_handle_events`。
///
/// 内核有数据或主 isolate 调用 `libusb_interrupt_event_handler` 时返回。
/// 回调只把结果放进队列，回到 Dart 事件循环后再提交下一次传输。
Future<void> usbWorker(SendPort mainPort) async {
  final inbox = _Inbox();
  mainPort.send(inbox.port.sendPort);
  final open = await inbox.take();
  final libraryPath = open[1]! as String;
  final portPath = open[2]! as String;
  final events = open[3]! as SendPort;

  Libusb? libusb;
  Pointer<libusb_context>? context;
  Pointer<libusb_device_handle>? handle;
  var interfaceNumber = -1;
  var released = false;
  _UsbEventLoop? loop;
  try {
    libusb = Libusb(DynamicLibrary.open(libraryPath));
    context = _init(libusb);
    final openedDevice = _openDevice(libusb, context, portPath);
    handle = openedDevice.handle;
    interfaceNumber = openedDevice.match.interfaceNumber;
    _prepareInterface(libusb, handle, interfaceNumber);
    final serial = _usbSerialNumber(libusb, handle);
    loop = _UsbEventLoop(
      libusb: libusb,
      context: context,
      handle: handle,
      endpointIn: openedDevice.match.endpointIn,
      endpointOut: openedDevice.match.endpointOut,
      maxPacketSize: openedDevice.match.maxPacketSize,
    );
    events.send(<Object?>['ready', serial, context.address, libraryPath]);
    await loop.run(inbox, events);
  } catch (error) {
    events.send(<Object?>['error', '$error']);
  } finally {
    loop?.dispose();
    released = _releaseUsb(libusb, handle, interfaceNumber, released);
    if (libusb != null && context != null) libusb.libusb_exit(context);
    events.send(<Object?>['closed']);
    inbox.close();
  }
}

/// 和 libusb 1.0 的 `struct libusb_transfer` 对齐。末尾的弹性数组不计入大小。
final class _LibusbTransfer extends Struct {
  external Pointer<libusb_device_handle> devHandle;

  @Uint8()
  external int flags;

  @Uint8()
  external int endpoint;

  @Uint8()
  external int type;

  @Uint32()
  external int timeout;

  @Int32()
  external int status;

  @Int32()
  external int length;

  @Int32()
  external int actualLength;

  external Pointer<NativeFunction<Void Function(Pointer<_LibusbTransfer>)>>
  callback;

  external Pointer<Void> userData;

  external Pointer<UnsignedChar> buffer;

  @Int32()
  external int numIsoPackets;
}

/// 供测试核对 64 位 ABI 上的字段偏移。
Map<String, int> usbTransferLayout() {
  final transfer = calloc<_LibusbTransfer>();
  try {
    transfer.ref.timeout = 0x11223344;
    transfer.ref.length = 0x55667788;
    transfer.ref.buffer = Pointer<UnsignedChar>.fromAddress(0x0102030405060708);
    final bytes = transfer.cast<Uint8>().asTypedList(sizeOf<_LibusbTransfer>());
    return <String, int>{
      'size': bytes.length,
      'timeout': _findUint32(bytes, 0x11223344),
      'length': _findUint32(bytes, 0x55667788),
      'buffer': _findUint64(bytes, 0x0102030405060708),
    };
  } finally {
    calloc.free(transfer);
  }
}

int _findUint32(List<int> bytes, int value) {
  for (var offset = 0; offset + 4 <= bytes.length; offset++) {
    final found =
        bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
    if (found == value) return offset;
  }
  return -1;
}

int _findUint64(List<int> bytes, int value) {
  for (var offset = 0; offset + 8 <= bytes.length; offset++) {
    var found = 0;
    for (var index = 0; index < 8; index++) {
      found |= bytes[offset + index] << (8 * index);
    }
    if (found == value) return offset;
  }
  return -1;
}

class _QueuedWrite {
  _QueuedWrite(this.data, this.reply);

  final Uint8List data;
  final SendPort reply;
  var sendingZeroPacket = false;
  var replied = false;

  void finish(Object? result) {
    if (replied) return;
    replied = true;
    reply.send(result);
  }
}

class _TransferDone {
  _TransferDone(this.tag, this.status, this.actual, this.bytes);

  final int tag;
  final int status;
  final int actual;
  final Uint8List? bytes;
}

class _UsbEventLoop {
  _UsbEventLoop({
    required this.libusb,
    required this.context,
    required this.handle,
    required this.endpointIn,
    required this.endpointOut,
    required this.maxPacketSize,
  }) {
    _ping.listen((_) {
      final waiter = _pingWaiter;
      _pingWaiter = null;
      if (waiter != null && !waiter.isCompleted) waiter.complete();
    });
    _calls = NativeCallable<Void Function(Pointer<_LibusbTransfer>)>.listener(
      _onTransfer,
    );
    _readTransfer = _allocate();
    _writeTransfer = _allocate();
    _readBuffer = calloc<UnsignedChar>(_readBufferSize);
  }

  final Libusb libusb;
  final Pointer<libusb_context> context;
  final Pointer<libusb_device_handle> handle;
  final int endpointIn;
  final int endpointOut;
  final int maxPacketSize;

  final ReceivePort _ping = ReceivePort();
  final List<_TransferDone> _done = <_TransferDone>[];
  final List<_QueuedWrite> _writes = <_QueuedWrite>[];
  Completer<void>? _pingWaiter;
  late final NativeCallable<Void Function(Pointer<_LibusbTransfer>)> _calls;
  late final Pointer<_LibusbTransfer> _readTransfer;
  late final Pointer<_LibusbTransfer> _writeTransfer;
  late final Pointer<UnsignedChar> _readBuffer;
  Pointer<UnsignedChar>? _writeBuffer;
  _QueuedWrite? _currentWrite;
  var _writeExpect = 0;
  var _readBusy = false;
  var _writeBusy = false;
  var _closing = false;
  var _cancelRequested = false;
  var _reported = false;
  var _disposed = false;

  Future<void> run(_Inbox inbox, SendPort events) async {
    await _flush();
    _drain(inbox);
    _ensureRead(events);
    _pumpWrite(events);
    while (true) {
      if (_closing) _cancelInFlight();
      if (_closing && !_readBusy && !_writeBusy) return;
      final code = libusb.libusb_handle_events(context);
      if (code != 0 && code != _libusbErrorInterrupted && !_closing) {
        _report(events, libusbErrorText(libusb, code));
      }
      await _flush();
      _harvest(events);
      _drain(inbox);
      if (_closing) continue;
      _ensureRead(events);
      _pumpWrite(events);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (!_readBusy) {
      libusb.libusb_free_transfer(_readTransfer.cast());
    }
    if (!_writeBusy) {
      libusb.libusb_free_transfer(_writeTransfer.cast());
    }
    calloc.free(_readBuffer);
    final writeBuffer = _writeBuffer;
    if (writeBuffer != null) calloc.free(writeBuffer);
    _calls.close();
    _ping.close();
  }

  Pointer<_LibusbTransfer> _allocate() {
    final transfer = libusb.libusb_alloc_transfer(0).cast<_LibusbTransfer>();
    if (transfer.address == 0) {
      throw AdbUsbException('无法分配 USB 传输。');
    }
    return transfer;
  }

  void _onTransfer(Pointer<_LibusbTransfer> transfer) {
    final actual = transfer.ref.actualLength;
    Uint8List? bytes;
    if (transfer.ref.userData.address == _transferRead &&
        transfer.ref.status == 0 &&
        actual > 0) {
      final length = actual > _readBufferSize ? _readBufferSize : actual;
      bytes = Uint8List.fromList(
        transfer.ref.buffer.cast<Uint8>().asTypedList(length),
      );
    }
    _done.add(
      _TransferDone(
        transfer.ref.userData.address,
        transfer.ref.status,
        actual,
        bytes,
      ),
    );
  }

  Future<void> _flush() {
    final done = Completer<void>();
    _pingWaiter = done;
    _ping.sendPort.send(null);
    return done.future;
  }

  void _drain(_Inbox inbox) {
    for (final message in inbox.drain()) {
      switch (message.first) {
        case 'write':
          final reply = message[2]! as SendPort;
          if (_closing) {
            reply.send('USB 设备已关闭。');
            break;
          }
          final data = message[1]! as Uint8List;
          if (data.isEmpty) {
            reply.send(null);
            break;
          }
          _writes.add(_QueuedWrite(data, reply));
        case 'close':
          _closing = true;
          for (final queued in _writes) {
            queued.finish('USB 设备已关闭。');
          }
          _writes.clear();
          _currentWrite?.finish('USB 设备已关闭。');
      }
    }
  }

  void _harvest(SendPort events) {
    final ready = List<_TransferDone>.of(_done);
    _done.clear();
    for (final done in ready) {
      if (done.tag == _transferRead) {
        _finishRead(events, done);
      } else if (done.tag == _transferWrite) {
        _finishWrite(events, done);
      }
    }
  }

  void _finishRead(SendPort events, _TransferDone done) {
    _readBusy = false;
    if (_closing || done.status == 3) return;
    if (done.status != 0) {
      _report(events, _transferStatusText(done.status));
      return;
    }
    final bytes = done.bytes;
    if (bytes != null && bytes.isNotEmpty) {
      events.send(<Object?>['data', bytes]);
    }
  }

  void _finishWrite(SendPort events, _TransferDone done) {
    _writeBusy = false;
    final current = _currentWrite;
    if (current == null) return;
    if (_closing || done.status == 3) {
      current.finish('USB 设备已关闭。');
      _currentWrite = null;
      return;
    }
    if (done.status != 0 || done.actual != _writeExpect) {
      current.finish(
        done.status == 0
            ? 'USB 写入不完整：${done.actual}/$_writeExpect'
            : 'USB 传输失败（${_transferStatusText(done.status)}）',
      );
      _currentWrite = null;
      if (done.status == 5) _report(events, _transferStatusText(done.status));
      return;
    }
    if (!current.sendingZeroPacket &&
        needsZeroLengthPacket(current.data.length, maxPacketSize)) {
      current.sendingZeroPacket = true;
      _submitWrite(events, 0);
      return;
    }
    current.finish(null);
    _currentWrite = null;
  }

  void _ensureRead(SendPort events) {
    if (_closing || _readBusy) return;
    final code = _submit(
      transfer: _readTransfer,
      endpoint: endpointIn,
      buffer: _readBuffer,
      length: _readBufferSize,
      timeout: 0,
      tag: _transferRead,
    );
    if (code != 0) {
      _report(events, libusbErrorText(libusb, code));
      return;
    }
    _readBusy = true;
  }

  void _pumpWrite(SendPort events) {
    if (_closing || _writeBusy || _currentWrite != null || _writes.isEmpty) {
      return;
    }
    final next = _writes.removeAt(0);
    _currentWrite = next;
    final previous = _writeBuffer;
    if (previous != null) calloc.free(previous);
    final buffer = calloc<UnsignedChar>(next.data.length);
    buffer.cast<Uint8>().asTypedList(next.data.length).setAll(0, next.data);
    _writeBuffer = buffer;
    _submitWrite(events, next.data.length);
  }

  void _submitWrite(SendPort events, int length) {
    final buffer = _writeBuffer;
    if (buffer == null) return;
    final code = _submit(
      transfer: _writeTransfer,
      endpoint: endpointOut,
      buffer: buffer,
      length: length,
      timeout: _writeTimeoutMs,
      tag: _transferWrite,
    );
    if (code != 0) {
      _currentWrite?.finish('USB 传输失败（${libusbErrorText(libusb, code)}）');
      _currentWrite = null;
      if (code == -4) _report(events, libusbErrorText(libusb, code));
      return;
    }
    _writeExpect = length;
    _writeBusy = true;
  }

  int _submit({
    required Pointer<_LibusbTransfer> transfer,
    required int endpoint,
    required Pointer<UnsignedChar> buffer,
    required int length,
    required int timeout,
    required int tag,
  }) {
    final fields = transfer.ref;
    fields.devHandle = handle;
    fields.flags = 0;
    fields.endpoint = endpoint;
    fields.type = _bulkTransfer;
    fields.timeout = timeout;
    fields.status = 0;
    fields.length = length;
    fields.actualLength = 0;
    fields.callback = _calls.nativeFunction;
    fields.userData = Pointer<Void>.fromAddress(tag);
    fields.buffer = buffer;
    fields.numIsoPackets = 0;
    return libusb.libusb_submit_transfer(transfer.cast());
  }

  void _cancelInFlight() {
    if (_cancelRequested) return;
    _cancelRequested = true;
    if (_readBusy) libusb.libusb_cancel_transfer(_readTransfer.cast());
    if (_writeBusy) libusb.libusb_cancel_transfer(_writeTransfer.cast());
  }

  void _report(SendPort events, String message) {
    _closing = true;
    if (_reported) return;
    _reported = true;
    events.send(<Object?>['error', 'USB 传输失败（$message）']);
  }
}

bool _releaseUsb(
  Libusb? libusb,
  Pointer<libusb_device_handle>? handle,
  int interfaceNumber,
  bool released,
) {
  if (released || libusb == null || handle == null) return released;
  if (interfaceNumber >= 0) {
    libusb.libusb_release_interface(handle, interfaceNumber);
  }
  libusb.libusb_close(handle);
  return true;
}

/// 读 USB 序列号字符串。官方 `adb devices` 的第一列就是它。
String? _usbSerialNumber(Libusb libusb, Pointer<libusb_device_handle> handle) {
  final descriptor = calloc<libusb_device_descriptor>();
  final buffer = calloc<UnsignedChar>(256);
  try {
    final device = libusb.libusb_get_device(handle);
    if (libusb.libusb_get_device_descriptor(device, descriptor) != 0) {
      return null;
    }
    final index = descriptor.ref.iSerialNumber;
    if (index == 0) return null;
    final length = libusb.libusb_get_string_descriptor_ascii(
      handle,
      index,
      buffer,
      255,
    );
    if (length <= 0) return null;
    final text = String.fromCharCodes(
      buffer.cast<Uint8>().asTypedList(length).where((byte) => byte != 0),
    ).trim();
    if (text.isEmpty) return null;
    return text;
  } catch (_) {
    return null;
  } finally {
    calloc.free(descriptor);
    calloc.free(buffer);
  }
}

/// 单订阅端口上的消息队列。一次 [take] 不会把端口听第二次。
class _Inbox {
  _Inbox() {
    attach(port);
  }

  final ReceivePort port = ReceivePort();
  final List<List<Object?>> _pending = <List<Object?>>[];
  Completer<void>? _waiter;

  void attach(ReceivePort source) {
    source.listen((Object? message) {
      if (message is! List || message.isEmpty) return;
      _pending.add(message.cast<Object?>());
      final waiter = _waiter;
      if (waiter != null && !waiter.isCompleted) waiter.complete();
    });
  }

  List<List<Object?>> drain() {
    if (_pending.isEmpty) return const <List<Object?>>[];
    final messages = List<List<Object?>>.of(_pending);
    _pending.clear();
    return messages;
  }

  Future<List<Object?>> take() async {
    while (_pending.isEmpty) {
      final gate = Completer<void>();
      _waiter = gate;
      if (_pending.isNotEmpty) break;
      await gate.future;
    }
    return _pending.removeAt(0);
  }

  void close() {
    port.close();
  }
}

Pointer<libusb_context> _init(Libusb libusb) {
  final out = calloc<Pointer<libusb_context>>();
  try {
    final code = libusb.libusb_init(out);
    if (code != 0) {
      throw AdbUsbException('初始化 libusb 失败：${libusbErrorText(libusb, code)}');
    }
    return out.value;
  } finally {
    calloc.free(out);
  }
}

UsbAdbDevice? _describeDevice(Libusb libusb, Pointer<libusb_device> device) {
  final descriptor = calloc<libusb_device_descriptor>();
  final configOut = calloc<Pointer<libusb_config_descriptor>>();
  try {
    if (libusb.libusb_get_device_descriptor(device, descriptor) != 0) {
      return null;
    }
    final configCode = _loadConfig(libusb, device, configOut);
    if (configCode != 0) return null;
    final config = configOut.value;
    final interfaces = _readInterfaces(config);
    libusb.libusb_free_config_descriptor(config);
    final match = findAdbInterface(interfaces);
    if (match == null) return null;
    final portPath = _portPath(libusb, device);
    return UsbAdbDevice(
      address: 'usb:$portPath',
      portPath: portPath,
      vendorId: descriptor.ref.idVendor,
      productId: descriptor.ref.idProduct,
      interfaceNumber: match.interfaceNumber,
      endpointIn: match.endpointIn,
      endpointOut: match.endpointOut,
      maxPacketSize: match.maxPacketSize,
    );
  } finally {
    calloc.free(descriptor);
    calloc.free(configOut);
  }
}

int _loadConfig(
  Libusb libusb,
  Pointer<libusb_device> device,
  Pointer<Pointer<libusb_config_descriptor>> out,
) {
  final active = libusb.libusb_get_active_config_descriptor(device, out);
  if (active == 0) return 0;
  return libusb.libusb_get_config_descriptor(device, 0, out);
}

List<UsbInterfaceInfo> _readInterfaces(
  Pointer<libusb_config_descriptor> config,
) {
  final interfaces = <UsbInterfaceInfo>[];
  final count = config.ref.bNumInterfaces;
  for (var index = 0; index < count; index++) {
    final interface = config.ref.interface[index];
    if (interface.num_altsetting <= 0) continue;
    final alt = interface.altsetting[0];
    final endpoints = <UsbEndpointInfo>[];
    for (
      var endpointIndex = 0;
      endpointIndex < alt.bNumEndpoints;
      endpointIndex++
    ) {
      final endpoint = alt.endpoint[endpointIndex];
      endpoints.add(
        UsbEndpointInfo(
          address: endpoint.bEndpointAddress,
          attributes: endpoint.bmAttributes,
          maxPacketSize: endpoint.wMaxPacketSize,
        ),
      );
    }
    interfaces.add(
      UsbInterfaceInfo(
        interfaceNumber: alt.bInterfaceNumber,
        usbClass: alt.bInterfaceClass,
        usbSubclass: alt.bInterfaceSubClass,
        usbProtocol: alt.bInterfaceProtocol,
        endpoints: endpoints,
      ),
    );
  }
  return interfaces;
}

String _portPath(Libusb libusb, Pointer<libusb_device> device) {
  final ports = calloc<Uint8>(8);
  try {
    final bus = libusb.libusb_get_bus_number(device);
    final count = libusb.libusb_get_port_numbers(device, ports, 8);
    if (count <= 0) {
      return '$bus-${libusb.libusb_get_device_address(device)}';
    }
    final parts = <String>[
      for (var index = 0; index < count; index++) '${ports[index]}',
    ];
    return '$bus-${parts.join('.')}';
  } finally {
    calloc.free(ports);
  }
}

class _OpenedUsbDevice {
  _OpenedUsbDevice(this.handle, this.match);

  final Pointer<libusb_device_handle> handle;
  final AdbUsbInterfaceMatch match;
}

_OpenedUsbDevice _openDevice(
  Libusb libusb,
  Pointer<libusb_context> context,
  String portPath,
) {
  final listOut = calloc<Pointer<Pointer<libusb_device>>>();
  try {
    final count = libusb.libusb_get_device_list(context, listOut);
    if (count < 0) {
      throw AdbUsbException('枚举 USB 设备失败：${libusbErrorText(libusb, count)}');
    }
    final list = listOut.value;
    Pointer<libusb_device>? matched;
    AdbUsbInterfaceMatch? match;
    for (var index = 0; index < count; index++) {
      final device = list[index];
      if (_portPath(libusb, device) != portPath) continue;
      final described = _describeDevice(libusb, device);
      if (described == null) continue;
      matched = device;
      match = AdbUsbInterfaceMatch(
        interfaceNumber: described.interfaceNumber,
        endpointIn: described.endpointIn,
        endpointOut: described.endpointOut,
        maxPacketSize: described.maxPacketSize,
      );
      break;
    }
    if (matched == null || match == null) {
      libusb.libusb_free_device_list(list, 1);
      throw AdbUsbException('USB 设备 $portPath 已不在总线上。');
    }
    final handleOut = calloc<Pointer<libusb_device_handle>>();
    try {
      final code = libusb.libusb_open(matched, handleOut);
      final osError = code == 0 ? 0 : _nativeErrorCode();
      libusb.libusb_free_device_list(list, 1);
      if (code != 0) {
        throw AdbUsbException(_claimMessage(libusb, code, osError));
      }
      return _OpenedUsbDevice(handleOut.value, match);
    } finally {
      calloc.free(handleOut);
    }
  } finally {
    calloc.free(listOut);
  }
}

void _prepareInterface(
  Libusb libusb,
  Pointer<libusb_device_handle> handle,
  int interfaceNumber,
) {
  // Windows 上没有内核驱动可分离，返回 NOT_SUPPORTED 时继续声明接口。
  libusb.libusb_set_auto_detach_kernel_driver(handle, 1);
  final configuration = calloc<Int>();
  try {
    if (libusb.libusb_get_configuration(handle, configuration) == 0 &&
        configuration.value == 0) {
      libusb.libusb_set_configuration(handle, 1);
    }
  } finally {
    calloc.free(configuration);
  }
  final code = libusb.libusb_claim_interface(handle, interfaceNumber);
  if (code != 0) {
    throw AdbUsbException(_claimMessage(libusb, code, _nativeErrorCode()));
  }
}

String _transferStatusText(int status) {
  return switch (status) {
    0 => '完成',
    1 => '传输失败',
    2 => '传输超时',
    3 => '传输已取消',
    4 => '端点停滞',
    5 => '设备已断开',
    6 => '数据溢出',
    _ => '状态 $status',
  };
}

String _claimMessage(Libusb libusb, int code, [int osError = 0]) {
  final name = libusbErrorText(libusb, code);
  if (code == _libusbErrorAccess) {
    final detail = osError == 0 ? name : '$name，Windows 错误 $osError';
    return '无法打开 USB 接口（$detail）。'
        '接口驱动已经是 WinUSB，Windows 仍然拒绝打开这个设备。'
        '请确认没有其他程序占用这台手机。';
  }
  if (code == _libusbErrorBusy) {
    return '无法打开 USB 接口（$name）。请先结束正在占用这台手机的程序。';
  }
  return 'USB 传输失败（$name）';
}

int _nativeErrorCode() {
  if (!Platform.isWindows) return 0;
  final kernel = DynamicLibrary.open('kernel32.dll');
  final lastError = kernel
      .lookup<NativeFunction<Uint32 Function()>>('GetLastError')
      .asFunction<int Function()>();
  return lastError();
}
