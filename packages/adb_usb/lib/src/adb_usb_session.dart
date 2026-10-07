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

const int _libusbErrorTimeout = -7;
const int _libusbErrorInterrupted = -10;
const int _libusbErrorAccess = -3;
const int _libusbErrorBusy = -6;
const int _readTimeoutMs = 20;
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
  worker.send(<Object?>[
    'open',
    libraryPath,
    device.portPath,
    events.sendPort,
  ]);
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
      // 后台读循环最多再阻塞一个读超时，超时后强制结束。
    }
    await _subscription?.cancel();
    _events.close();
    if (!_incoming.isClosed) await _incoming.close();
    _isolate.kill();
  }
}

/// 后台执行 USB 读写。由 [openUsbAdbDevice] 通过 [Isolate.spawn] 启动。
Future<void> usbWorker(SendPort mainPort) async {
  final inbox = ReceivePort();
  final opened = Completer<List<Object?>>();
  final writes = <List<Object?>>[];
  var closed = false;
  inbox.listen((Object? message) {
    if (message is! List || message.isEmpty) return;
    switch (message.first) {
      case 'open':
        if (!opened.isCompleted) opened.complete(message.cast<Object?>());
      case 'write':
        writes.add(message.cast<Object?>());
      case 'close':
        closed = true;
    }
  });
  mainPort.send(inbox.sendPort);
  final open = await opened.future;
  final libraryPath = open[1]! as String;
  final portPath = open[2]! as String;
  final events = open[3]! as SendPort;

  Libusb? libusb;
  Pointer<libusb_context>? context;
  Pointer<libusb_device_handle>? handle;
  var interfaceNumber = -1;
  var endpointIn = 0;
  var endpointOut = 0;
  var maxPacketSize = 512;
  try {
    libusb = Libusb(DynamicLibrary.open(libraryPath));
    context = _init(libusb);
    final openedDevice = _openDevice(libusb, context, portPath);
    handle = openedDevice.handle;
    interfaceNumber = openedDevice.match.interfaceNumber;
    endpointIn = openedDevice.match.endpointIn;
    endpointOut = openedDevice.match.endpointOut;
    maxPacketSize = openedDevice.match.maxPacketSize;
    _prepareInterface(libusb, handle, interfaceNumber);
    events.send(<Object?>['ready']);
    final buffer = calloc<UnsignedChar>(_readBufferSize);
    final transferred = calloc<Int>();
    try {
      while (!closed) {
        while (writes.isNotEmpty && !closed) {
          final request = writes.removeAt(0);
          final reply = request[2]! as SendPort;
          try {
            _writeAll(
              libusb,
              handle,
              endpointOut,
              request[1]! as Uint8List,
              maxPacketSize,
              transferred,
            );
            reply.send(null);
          } catch (error) {
            reply.send('$error');
          }
        }
        if (closed) break;
        final code = libusb.libusb_bulk_transfer(
          handle,
          endpointIn,
          buffer,
          _readBufferSize,
          transferred,
          _readTimeoutMs,
        );
        if (code == _libusbErrorTimeout || code == _libusbErrorInterrupted) {
          await Future<void>.delayed(Duration.zero);
          continue;
        }
        if (code != 0) {
          events.send(<Object?>['error', _claimMessage(libusb, code)]);
          break;
        }
        final length = transferred.value;
        if (length > 0) {
          events.send(<Object?>[
            'data',
            Uint8List.fromList(buffer.cast<Uint8>().asTypedList(length)),
          ]);
        }
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      calloc.free(buffer);
      calloc.free(transferred);
    }
  } catch (error) {
    events.send(<Object?>['error', '$error']);
  } finally {
    if (libusb != null && handle != null && interfaceNumber >= 0) {
      libusb.libusb_release_interface(handle, interfaceNumber);
      libusb.libusb_close(handle);
    }
    if (libusb != null && context != null) libusb.libusb_exit(context);
    events.send(<Object?>['closed']);
    inbox.close();
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
