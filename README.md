# FireAdb

纯自研跨平台 ADB 工具箱（不调用系统 adb 二进制，协议自实现）。

## 目标平台

- Windows / Linux / macOS（桌面，Flutter + dart_libusb）
- Android（Flutter；USB Host 走 `android.hardware.usb`）

## 工程结构

```
fire-adb/
├── pubspec.yaml              # pub workspace 根：统一依赖解析与单一 pubspec.lock
├── analysis_options.yaml     # 工作区共享静态分析配置（各成员包 include 继承）
├── app/                      # Flutter 应用（android/windows/linux/macos）
├── packages/
│   ├── adb_core/             # 纯 Dart ADB 引擎（协议 / 传输 / 认证 / 无线配对，零平台依赖）
│   └── adb_usb/              # USB 传输层（规划中：dart_libusb / android.hardware.usb）
└── third_party/              # 参考源码（git submodule，不参与构建）
    ├── aosp-adb/             # AOSP packages/modules/adb（GitHub 镜像）
    └── python-adb/           # https://github.com/google/python-adb
```

## 获取源码（含子模块）

```bash
git clone --recursive https://gitee.com/mingyueyixi/fire-adb.git
# 若已 clone：
git submodule update --init --recursive
```

`third_party/` 下的两个仓库仅用于对照学习，不参与构建，也不会被 app/packages 引用。

## 开发

`app` 与 `packages/*` 通过 Dart 官方 [pub workspace](https://dart.dev/tools/pub/workspaces)
组织为单仓库（monorepo）：依赖与版本在根统一解析，只产生一个 `pubspec.lock`，
共享 root 的 `.dart_tool` 缓存与静态分析配置。**常用命令都在仓库根执行**：

| 目的 | 命令 |
|---|---|
| 拉取 / 更新全部依赖 | `flutter pub get` |
| 静态分析（整个工作区） | `dart analyze` |
| 代码格式化 | `dart format .` |
| 运行 adb_core 测试 | `dart test packages/adb_core` |
| 运行应用测试 | `flutter test app` |
| 运行应用 | `cd app && flutter run` |

提交前请确保 `dart analyze` 无告警。

## 参考文档（在 third_party/aosp-adb/docs/dev/ 下）

| 主题 | 文件 |
|---|---|
| ADB 传输层协议（24 字节消息头 / CNXN/AUTH/OPEN/WRTE/CLSE） | `protocol.md` |
| 智能 socket / 服务协议（5037 端口） | `services.md` |
| file_sync（push/pull） | `sync.md` |
| 整体架构 | `overview.md` |
| 无线调试（mDNS + TLS 配对） | `adb_wifi.md` |
| python 参考实现 | `vendor/../python-adb/adb/`（adb_protocol.py、adb_commands.py、sign_*.py） |

## 分步实现路线

- [x] 0. 项目初始化：Flutter 应用 + `adb_core`（纯协议引擎）+ `adb_usb`（USB 传输）
- [x] 1. `adb_core`：协议基元（4 字节 HEX 长度帧、24 字节消息头、编解码与校验）`protocol.md` + `adb.cpp:calculate_apacket_checksum`
- [x] 2. `adb_core`：RSA 密钥 + AUTH 握手状态机（TOKEN→SIGNATURE→RSAPUBLICKEY→CNXN）`protocol.md` + `adb_auth.h`
- [x] 3. `adb_core`：TCP 传输（直连 5555 / 模拟器端口）+ 真实 loopback 端到端测试
- [x] 4. `adb_core`：连接抽象（`AdbConnection` 多流、5037 host 客户端 `host:connect`、`tport:*`/`transport-any`、track-devices）
- [x] 5. `adb_core`：服务实现（shell / sync push-pull / install / screencap / getprop 等）——已在真实模拟器（emulator-5556, Android 12）全流程验证：AUTH 握手（持久化密钥免授权）、shell/getprop/echo、`exec:screencap -p` 截图 2.2MB、push↔pull、stat、track-devices 全部通过
- [x] 6. `adb_core`：WiFi 无线调试（mDNS 发现 + Android 11+ TLS 配对，参考 `pairing_connection/`）——mDNS 用纯 Dart `RawDatagramSocket` 自研（PTR/SRV/TXT/A/AAAA 解析含名称压缩指针，回归测试含真实压缩指针报文）；TLS 1.3 + SPAKE2 + Aes128Gcm 配对握手与 AOSP 源码逐字节核对（`pairing_connection.h`、`aes_128_gcm.cpp`），loopback 端到端 4 项测试通过。真机验证：MuMu（Android 12）镜像无无线调试入口，配对路径以字节级测试覆盖；经典 transport（RSA AUTH + CNXN + shell_v2 + filesync + track-devices）已在同一模拟器直连 adbd（5557）全流程复验通过
- [ ] 7. `adb_usb`：dart_libusb 枚举 + bulk 传输（Windows WinUSB 驱动 / Linux udev / macOS 权限）
- [ ] 8. Android 端：`android.hardware.usb` 插件化 USB 传输
- [ ] 9. App UI：设备列表 / shell 终端 / 文件管理 / 安装构建 / 截图录屏
- [ ] 10. 交叉编译与各平台打包

## 依赖

- `adb_core`: `pointycastle`（RSA/签名）
- `adb_usb`: `dart_libusb`（libusb FFI 绑定）、`adb_core`
- `app`: `adb_core`（workspace 内路径依赖）