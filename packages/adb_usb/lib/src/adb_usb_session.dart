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
const int _writeTimeoutMs = 10000;
const int _readBufferSize = 16 * 1024;

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

/// 打开 [device] 的 ADB 批量接口，读写在后台 isolate 中进行。
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

  /// USB 字符串描述符里的序列号。`adb devices` 用它，而不是端口路径。
  String? serialNumber;

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  Future<void> write(List<int> data) async {
    if (_closed) throw StateError('传输已关闭，无法写入');
    final reply = ReceivePort();
    _worker.send(<Object?>['write', Uint8List.fromList(data), reply.sendPort]);
    final result = await reply.first;
    reply.close();
    if (result is String) throw AdbUsbException(result);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _worker.send(<Object?>['close']);
    try {
      await _released.future.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // 关掉句柄后读线程仍没退出时，强制结束 isolate。
    }
    await _subscription?.cancel();
    _events.close();
    if (!_incoming.isClosed) await _incoming.close();
    _isolate.kill();
  }
}

/// 后台打开 USB，并把读、写分到两个 isolate。
///
/// 读 isolate 用超时 0 堵在批量输入上。写 isolate 单独调用批量输出。
/// 控制 isolate 不进入 `libusb_bulk_transfer`，这样关闭时可以调用
/// `libusb_close` 打断两边正在进行的传输。
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
  Isolate? reader;
  Isolate? writer;
  SendPort? writePort;
  ReceivePort? children;
  var released = false;
  try {
    libusb = Libusb(DynamicLibrary.open(libraryPath));
    context = _init(libusb);
    final openedDevice = _openDevice(libusb, context, portPath);
    handle = openedDevice.handle;
    interfaceNumber = openedDevice.match.interfaceNumber;
    final endpointIn = openedDevice.match.endpointIn;
    final endpointOut = openedDevice.match.endpointOut;
    final maxPacketSize = openedDevice.match.maxPacketSize;
    _prepareInterface(libusb, handle, interfaceNumber);
    final serial = _usbSerialNumber(libusb, handle);

    final pipes = ReceivePort();
    children = pipes;
    inbox.attach(pipes);
    final writeBoot = ReceivePort();
    writer = await Isolate.spawn(usbWriteLoop, writeBoot.sendPort);
    writePort = await writeBoot.first as SendPort;
    writeBoot.close();
    writePort.send(<Object?>[
      libraryPath,
      handle.address,
      endpointOut,
      maxPacketSize,
      pipes.sendPort,
    ]);
    final readBoot = ReceivePort();
    reader = await Isolate.spawn(usbReadLoop, readBoot.sendPort);
    final readPort = await readBoot.first as SendPort;
    readBoot.close();
    readPort.send(<Object?>[
      libraryPath,
      handle.address,
      endpointIn,
      pipes.sendPort,
    ]);
    events.send(<Object?>['ready', serial]);

    var closing = false;
    var readEnded = false;
    var writeEnded = false;
    DateTime? deadline;
    while (true) {
      final List<Object?> message;
      if (!closing) {
        message = await inbox.take();
      } else {
        try {
          message = await inbox.take().timeout(const Duration(seconds: 2));
        } on TimeoutException {
          reader.kill();
          writer.kill();
          break;
        }
      }
      switch (message.first) {
        case 'write':
          if (closing) {
            (message[2]! as SendPort).send('USB 设备已关闭。');
          } else {
            writePort.send(message);
          }
        case 'close':
          closing = true;
          deadline ??= DateTime.now().add(const Duration(seconds: 2));
          writePort.send(<Object?>['stop']);
          released = _releaseUsb(libusb, handle, interfaceNumber, released);
        case 'data':
          if (!closing) events.send(message);
        case 'read-end':
          readEnded = true;
          final error = message.length > 1 ? message[1] : null;
          if (!closing && error is String) {
            events.send(<Object?>['error', error]);
            closing = true;
            deadline ??= DateTime.now().add(const Duration(seconds: 2));
            writePort.send(<Object?>['stop']);
            released = _releaseUsb(libusb, handle, interfaceNumber, released);
          }
        case 'write-end':
          writeEnded = true;
          if (!closing) {
            events.send(<Object?>['error', 'USB 写入已停止。']);
            closing = true;
            deadline ??= DateTime.now().add(const Duration(seconds: 2));
            released = _releaseUsb(libusb, handle, interfaceNumber, released);
          }
      }
      if (closing && readEnded && writeEnded) break;
      if (deadline != null && DateTime.now().isAfter(deadline)) {
        reader.kill();
        writer.kill();
        break;
      }
    }
  } catch (error) {
    events.send(<Object?>['error', '$error']);
  } finally {
    released = _releaseUsb(libusb, handle, interfaceNumber, released);
    reader?.kill();
    writer?.kill();
    children?.close();
    if (libusb != null && context != null) libusb.libusb_exit(context);
    events.send(<Object?>['closed']);
    inbox.close();
  }
}

/// 阻塞读批量输入，直到有数据或句柄被关掉。
Future<void> usbReadLoop(SendPort parent) async {
  final inbox = _Inbox();
  parent.send(inbox.port.sendPort);
  final open = await inbox.take();
  inbox.close();
  final libraryPath = open[0]! as String;
  final handle = Pointer<libusb_device_handle>.fromAddress(open[1]! as int);
  final endpoint = open[2]! as int;
  final events = open[3]! as SendPort;
  final libusb = Libusb(DynamicLibrary.open(libraryPath));
  final buffer = calloc<UnsignedChar>(_readBufferSize);
  final transferred = calloc<Int>();
  String? error;
  try {
    while (true) {
      final code = libusb.libusb_bulk_transfer(
        handle,
        endpoint,
        buffer,
        _readBufferSize,
        transferred,
        0,
      );
      if (code != 0) {
        error = _claimMessage(libusb, code);
        break;
      }
      final length = transferred.value;
      if (length <= 0) continue;
      events.send(<Object?>[
        'data',
        Uint8List.fromList(buffer.cast<Uint8>().asTypedList(length)),
      ]);
    }
  } catch (caught) {
    error = '$caught';
  } finally {
    calloc.free(buffer);
    calloc.free(transferred);
    events.send(<Object?>['read-end', error]);
  }
}

/// 阻塞写批量输出。控制 isolate 发来 `stop` 后退出。
Future<void> usbWriteLoop(SendPort parent) async {
  final inbox = _Inbox();
  parent.send(inbox.port.sendPort);
  final open = await inbox.take();
  final libraryPath = open[0]! as String;
  final handle = Pointer<libusb_device_handle>.fromAddress(open[1]! as int);
  final endpoint = open[2]! as int;
  final maxPacketSize = open[3]! as int;
  final events = open[4]! as SendPort;
  final libusb = Libusb(DynamicLibrary.open(libraryPath));
  final transferred = calloc<Int>();
  try {
    while (true) {
      final message = await inbox.take();
      if (message.first == 'stop') break;
      if (message.first != 'write') continue;
      final reply = message[2]! as SendPort;
      try {
        _writeAll(
          libusb,
          handle,
          endpoint,
          message[1]! as Uint8List,
          maxPacketSize,
          transferred,
        );
        reply.send(null);
      } catch (error) {
        reply.send('$error');
      }
    }
  } finally {
    calloc.free(transferred);
    events.send(<Object?>['write-end']);
    inbox.close();
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

void _writeAll(
  Libusb libusb,
  Pointer<libusb_device_handle> handle,
  int endpoint,
  Uint8List data,
  int maxPacketSize,
  Pointer<Int> transferred,
) {
  if (data.isEmpty) return;
  final buffer = calloc<UnsignedChar>(data.length);
  try {
    buffer.cast<Uint8>().asTypedList(data.length).setAll(0, data);
    final code = libusb.libusb_bulk_transfer(
      handle,
      endpoint,
      buffer,
      data.length,
      transferred,
      _writeTimeoutMs,
    );
    if (code != 0 || transferred.value != data.length) {
      throw AdbUsbException(
        code == 0
            ? 'USB 写入不完整：${transferred.value}/${data.length}'
            : _claimMessage(libusb, code),
      );
    }
    if (needsZeroLengthPacket(data.length, maxPacketSize)) {
      final zero = libusb.libusb_bulk_transfer(
        handle,
        endpoint,
        buffer,
        0,
        transferred,
        _writeTimeoutMs,
      );
      if (zero != 0) throw AdbUsbException(_claimMessage(libusb, zero));
    }
  } finally {
    calloc.free(buffer);
  }
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
