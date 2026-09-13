# adb_core

纯 Dart 实现的 **ADB 协议引擎**。不调用系统 `adb` 二进制，零平台依赖（仅依赖 `pointycastle`），
可同时被 Flutter 应用与 `package:adb_usb` 复用。

## 模块

| 领域 | 入口 | 说明 |
|---|---|---|
| 协议基元 | `adb_message.dart` | 4 字节 HEX 长度帧、24 字节消息头、CNXN/AUTH/OPEN/WRTE/CLSE/OKAY/FAIL、校验和 |
| 认证 | `adb_auth_key.dart` / `adb_der.dart` | RSA 密钥、AOSP 公钥格式、TOKEN→SIGNATURE→RSAPUBLICKEY→CNXN 握手 |
| 传输 | `adb_transport.dart` / `adb_tcp_transport.dart` | 传输抽象与 TCP 实现（直连 5555 / 模拟器端口） |
| 连接与会话 | `adb_connection.dart` / `adb_smart_socket.dart` / `adb_host_client.dart` | 多流连接、5037 host 客户端（`host:connect`、`tport:*`、`track-devices`） |
| 设备服务 | `adb_device.dart` / `adb_filesync.dart` | shell / sync(push-pull) / install / screencap / getprop |
| 无线调试 | `mdns.dart` / `pairing_connection.dart` / `tls13.dart` / `spake25519.dart` / `pairing_aes_gcm.dart` | 纯 Dart mDNS 发现 + Android 11+ TLS 1.3 配对（SPAKE2、AES-128-GCM） |
| 密码学原语 | `ed25519.dart` / `x25519.dart` / `tls_prf.dart` / `x509.dart` | Ed25519/X25519、HKDF、证书解析 |

## 用法

```dart
import 'package:adb_core/adb_core.dart';

// 通过本机 adb server（5037）列出设备
final client = AdbHostClient(host: '127.0.0.1', port: 5037);
final devices = await client.devices();
for (final d in devices) {
  print('${d.serial}\t${d.state}');
}
```

更多示例见 `example/adb_core_example.dart`；针对真实模拟器的端到端脚本见 `tool/test_emulator.dart`。

## 测试

```bash
# 在仓库根执行（workspace）
dart test packages/adb_core
```

测试包含真实 loopback 的端到端用例，以及 `fake_adbd.dart` / `fake_adb_server.dart` /
`fake_mdns_responder.dart` 等本地模拟对端。

## 参考

实现与 AOSP `packages/modules/adb` 及 RFC 8448（TLS 1.3）逐字节对照，
参考源码以 git submodule 形式放在仓库 `third_party/`（仅作对照，不参与构建）。
