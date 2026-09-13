/// ADB 协议异常。
///
/// 类名与语义对齐 `google/python-adb` 的 `adb/adb_protocol.py`。
library;

/// 收到未知命令或设备返回 FAIL。
class AdbInvalidCommandError implements Exception {
  AdbInvalidCommandError(this.message, {this.header, this.data});

  final String message;
  final Object? header;
  final Object? data;

  @override
  String toString() =>
      'AdbInvalidCommandError: $message($header, $data)';
}

/// 收到响应与预期不符。
class AdbInvalidResponseError implements Exception {
  AdbInvalidResponseError(this.message);

  final String message;

  @override
  String toString() => 'AdbInvalidResponseError: $message';
}

/// payload 校验和与头不符。
class AdbInvalidChecksumError implements Exception {
  AdbInvalidChecksumError(this.message);

  final String message;

  @override
  String toString() => 'AdbInvalidChecksumError: $message';
}

/// 不支持多流并发。
class AdbInterleavedDataError implements Exception {
  AdbInterleavedDataError(this.message);

  final String message;

  @override
  String toString() => 'AdbInterleavedDataError: $message';
}

/// 设备需要认证但未提供可用密钥。
class AdbDeviceAuthError implements Exception {
  AdbDeviceAuthError(this.message);

  final String message;

  @override
  String toString() => 'AdbDeviceAuthError: $message';
}

/// `adb server` 拒绝了请求（FAIL + 描述）。
class AdbHostError implements Exception {
  AdbHostError(this.message);

  final String message;

  @override
  String toString() => 'AdbHostError: $message';
}