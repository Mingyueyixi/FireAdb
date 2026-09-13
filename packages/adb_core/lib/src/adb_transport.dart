/// ADB 传输层抽象。
///
/// 一条传输 = 一个可读的字节流 + 可写的方法。TCP、USB（dart_libusb）、
/// Android `android.hardware.usb` 均实现该接口，供 [AdbConnection] 消费。
library;

import 'dart:typed_data';

abstract interface class AdbTransport {
  /// 来自对端的字节流（允许粘包/半包）。
  Stream<Uint8List> get stream;

  /// 将 [data] 整体写入对端。
  Future<void> write(List<int> data);

  /// 关闭传输（幂等）。
  Future<void> close();
}