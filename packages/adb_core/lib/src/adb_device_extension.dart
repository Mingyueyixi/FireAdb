import 'adb_connection.dart';

/// 一次扫描交回来的、已经可以放进设备列表的设备。
class AdbScannedDevice {
  const AdbScannedDevice({
    required this.id,
    required this.connection,
    required this.serial,
    this.state = 'device',
    this.devPath,
    this.product,
    this.model,
    this.deviceName,
    this.usb = false,
  });

  /// 同一条连接保持不变，用来认出设备离开了。
  final String id;
  final AdbConnection connection;
  final String serial;
  final String state;
  final String? devPath;
  final String? product;
  final String? model;
  final String? deviceName;
  final bool usb;
}

/// Server 用来接收某一种连接方式的扫描结果。
abstract class AdbScanListener {
  void onScan(List<AdbScannedDevice> devices);
}

/// 额外的连接方式。USB 只是其中一种。
///
/// 本机模拟器扫描和 `host:connect` 不经过这里。扩展自己决定何时扫描，
/// [listen] 之后把结果交给 listener，server 只写入 `host:devices`。
abstract class AdbDeviceExtension {
  void listen(AdbScanListener listener);

  /// 停止扫描并释放这个扩展占着的连接。server 关闭时会等待它完成。
  Future<void> cancel();
}
