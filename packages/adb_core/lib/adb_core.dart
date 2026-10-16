/// adb_core：纯 Dart 的 ADB 引擎（协议层）。
///
/// 不含任何平台相关代码。桌面 USB 在 libadb 里，随本机 server 一起启动。
library;

export 'src/adb_auth_key.dart';
export 'src/adb_commands.dart';
export 'src/adb_connection.dart';
export 'src/adb_device_extension.dart';
export 'src/adb_der.dart';
export 'src/adb_device.dart';
export 'src/adb_exceptions.dart';
export 'src/adb_filesync.dart';
export 'src/adb_host_client.dart';
export 'src/adb_message.dart';
export 'src/adb_server.dart';
export 'src/adb_smart_socket.dart';
export 'src/adb_stream_reader.dart';
export 'src/adb_tcp_transport.dart';
export 'src/adb_transport.dart';
export 'src/ed25519.dart';
export 'src/mdns.dart';
export 'src/pairing_aes_gcm.dart';
export 'src/pairing_connection.dart';
export 'src/spake25519.dart';
export 'src/tls13.dart';
export 'src/tls_prf.dart';
export 'src/x25519.dart';
export 'src/x509.dart';
