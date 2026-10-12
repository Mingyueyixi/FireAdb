# 与官方 ADB 的差异

对照基准是仓库里的 `third_party/aosp-adb`（AOSP `packages/modules/adb`）。协议版本与官方当前一致：`A_VERSION = 0x01000001`（跳过 checksum），`ADB_SERVER_VERSION = 41`（`host:version` 返回 `0029`）。

FireAdb 实现的是主机侧：传输、认证、本机 5037、以及自己调用的设备服务。手机上的 adbd 仍是系统自带的。下面把差异分成三类：

- **本机 Server 缺失**：官方 `adb` 连上我们占用的 5037 时，这条命令会失败。
- **自有客户端缺失**：官方客户端会自己完成，我们只负责把字节桥给设备；FireAdb 自己的 API 和应用还没有对应能力。
- **行为差异**：两边都有，做法不一样。

## 已经对齐的部分

这些是当前主机实现里已经按官方线格式做过的能力，后面的缺口都相对这一层。

| 层 | 现状 |
|---|---|
| 传输帧 | CNXN、AUTH、OPEN、WRTE、OKAY、CLSE、STLS。24 字节头，`maxdata` 256 KiB。校验和在 `data_check != 0` 时仍会核对 |
| 认证 | TOKEN → SIGNATURE → RSAPUBLICKEY → CNXN。签名是 SHA-1 PKCS#1 v1.5。私钥可读写官方 `adbkey` 的 PKCS#1 PEM，也接受 PKCS#8 |
| 多流 | 一条连接上按 local id 并发 OPEN。每条流同一时刻只放行一个未确认的 WRTE |
| 本机 5037 | 只在端口空闲时监听。一次查询写完结果后关闭连接。`host:version`、`host:kill`、`host:devices`、`host:devices-l`、`host:track-devices`、`host:track-devices-l`、`host:connect`、`host:disconnect` |
| 选设备 | `host:transport:`、`host:transport-any`、`host:transport-usb`、`host:tport:`（回 8 字节小端 transport id，连接保持到后续服务结束） |
| 设备查询 | `get-serialno`、`get-state`、`get-devpath`、`features`。序列号可以用 `host-serial:`，最后一个冒号切开，因此 `usb:1-3` 和 `IP:端口` 都能当序列号 |
| 端口转发 | 本机 TCP 监听，含 `tcp:0`。`norebind`、`list-forward`、`killforward`、`killforward-all`。`tcp:0` 成功时先多回一个 `OKAY`，再跟上端口数字，和 platform-tools 的 `adb_connect` 一致 |
| 桥接 | 传输选中之后，`shell:`、`exec:`、`sync:` 以及其他设备服务原样 OPEN 给已经握完手的连接 |
| 模拟器 | 扫描回环 `5555、5557 … 5585`，序列号 `emulator-<端口-1>` |
| 列表格式 | 短格式 `序列号<TAB>状态`。长格式序列号补齐到 22 列，再写 `product:`、`model:`、`device:`、`transport_id:`。路径里含 `/` 才打印 devpath |
| USB | 接口类 `0xFF/0x42/0x01`，以及 Debug Capability `0xDC/0x02/0x01`。批量 IN/OUT。写出长度是包长整数倍时补零长度包。Windows 用 libusb 1.0.29，异步提交后等内核事件 |
| 无线 | mDNS 查询 `_adb-tls-pairing._tcp`、`_adb-tls-connect._tcp`、`_adb._tcp`。配对是 TLS 1.3 + SPAKE2 + AES-128-GCM。连接端口走 STLS，之后在 TLS 里继续收 ADB 帧 |
| 文件 | sync v1：`STAT`、`LIST`、`SEND`、`RECV`、`DENT`、`QUIT`。单帧不超过 64 KiB |
| 直连 API | `shell:`、`exec:`、`sync:`、`screencap -p`、`pm install` / `pm uninstall`、`reboot:`、`getprop`、`logcat`、`screenrecord` |

应用界面目前用到的是设备概览、应用列表、文件、截图、录屏和按条执行的 shell。这些都落在上表的直连 API 上。

## 协议协商

主机发出的 CNXN 标识是 `host::<banner>`，默认 banner 为 `dart-adb`，里面没有 `features=`。

官方主机会宣告这些特性（`transport.cpp` 的 `supported_features()`）：

`shell_v2`、`cmd`、`stat_v2`、`ls_v2`、`fixed_push_mkdir`、`apex`、`abb`、`fixed_push_symlink_timestamp`、`abb_exec`、`remount_shell`、`track_app`、`sendrecv_v2`、`sendrecv_v2_brotli`、`sendrecv_v2_lz4`、`sendrecv_v2_zstd`、`sendrecv_v2_dry_run_send`、`openscreen_mdns`、`devicetracker_proto_format`、`devraw`、`app_info`、`server_status`。

`delayed_ack` 在设备端始终宣告。官方主机要设置 `ADB_BURST_MODE` 才宣告。我们没有这套窗口：每条 WRTE 都要等 OKAY，收到 WRTE 也立刻回 OKAY。OKAY 不携带「已接收字节数」。官方在打开 burst 时，单流可以同时在途多包，推送和拉取会更快。我们这条链路上，官方 `adb push` 经我们的 5037 转发，同样受这个限制，因为 USB/TCP 帧是我们自己收发的。

`host:features` 返回的是设备 CNXN banner 里的 `features=`，也就是设备自己的能力。官方的 `adb features` 是主机能力与设备能力的交集，`adb host-features` 只列主机。我们没有单独的主机特性集，所以官方客户端会按设备特性决定是否发送 `shell,v2:`。服务名会原样桥接，因此官方 `adb shell` 在设备支持时可以用 v2。FireAdb 自己的 `AdbDevice.shell` 固定打开 `shell:`。

## 本机 Server：官方客户端会失败的命令

官方 `adb` 连到我们的 5037 时，下面这些主机服务会收到 `unknown host service`，或因为规格解析失败而 FAIL。

| 官方命令 / 服务 | 缺口 |
|---|---|
| `adb -e`、`host:transport-local`、`host-local:` | 没有 local 传输选择。`host:tport:local` 可以选中唯一的非 USB 设备，新客户端走 tport 时能用；旧的 `host:transport-local` 不行 |
| `adb wait-for-*` | 没有 `host:wait-for-usb-device` 这一类服务。状态包括 device、recovery、rescue、sideload、bootloader、disconnect |
| `adb host-features` | 没有 `host:host-features` |
| `adb server-status` | 没有 `host:server-status`（官方返回 USB 后端、mDNS 后端、日志路径等） |
| `adb track-devices --proto-text` / `--proto-binary` | 只有文本版 `track-devices` 和 `track-devices-l` |
| `adb mdns check` / `adb mdns services` | 没有 `host:mdns:`。发现走应用自己的 mDNS，不经过 5037 |
| `adb pair` | 没有 `host:pair:`。配对由应用直接连配对端口完成 |
| `adb reconnect`、`adb reconnect offline` | 没有 `host:reconnect`、`host:reconnect-offline`。`adb reconnect device` 是发给设备的 `reconnect` 服务，桥接可以带过去 |
| `adb attach` / `adb detach` | 没有 libusb 后端的让出/重新声明 |
| `adb forward` 的非 TCP 本地端 | 本地端只接受 `tcp:<端口>` 和 `tcp:<地址>:<端口>`。`localabstract`、`localreserved`、`localfilesystem`、`acceptfd` 不能在本机监听。远端字符串会原样 OPEN 给设备，所以 `tcp:本地 jdwp:<pid>` 这种「本地是 TCP」的转发可以工作 |
| `host:emulator:<端口>` | 模拟器启动时用这条服务主动登记。我们不接受，改由每 3 秒扫描固定端口。模拟器仍会出现，登记不是即时的 |
| `-a`、`-L`、`--one-device` | 默认只绑 `127.0.0.1`。没有「监听所有网卡」、Unix 套接字和服务激活，也没有只连接一台 USB 设备的服务器模式 |

环境变量也没有接上：`ADB_LOCAL_TRANSPORT_MAX_PORT`（官方默认最大模拟器端口 5585，可用它加大范围）、`ANDROID_SERIAL`、`ADB_MDNS_AUTO_CONNECT`、`ADB_TRACE`、`ADB_VENDOR_KEYS`、`ADB_LIBUSB`。

`adb forward --list`、`adb forward --remove`、`adb forward tcp:0 tcp:<端口>`（Flutter 调试会用）已经按官方应答接上。

## 自有客户端没有、官方客户端经桥接可以使用的能力

传输选中之后，除了 `forward` 由本机 Server 处理，其他服务名都会 OPEN 给设备。官方 `adb.exe` 自己实现命令行逻辑，再把 `shell,v2:`、`sync:`、`abb_exec:` 等发给设备。这些命令在官方客户端里可用，FireAdb 的 Dart API 没有对应实现。

| 官方能力 | FireAdb 自己的做法 |
|---|---|
| 交互式 `adb shell`：PTY、`shell,v2`（退出码、stdout/stderr 分开）、`-t`/`-T`、`-x`、`-e` 转义 | `shell:<命令>`，一次一条，stdout 和 stderr 混在一起，没有退出码。界面里的 Shell 也是按条执行，遇到 `sh` / `su` 才把这条流留着交互 |
| `exec-in` | 有 `exec:`（`exec-out`），没有把本机 stdin 送进 `exec:` |
| `abb` / `abb_exec` | 未使用。安装和卸载走 `pm` shell |
| streaming install、`install-multiple`、`install-multi-package`、`--instant`、`--abi`、`-t`、`-d`、`-p` | 安装是把 APK 推到 `/data/local/tmp`，再 `pm install`。只带 `-r` 和 `-g` |
| fastdeploy、incremental install（`inc-server`） | 没有部署代理，也没有按块补传的 incremental server |
| `push --sync`、`-n` 干跑、`-z` 压缩（brotli/lz4/zstd）、目录递归、`pull -a` | sync v1 单文件。`pushFile` 先把整个文件读进内存。size 和 mtime 是 32 位，大于 4 GiB 的文件表达不了。没有 `STA2` / `LST2` / `SND2` / `RCV2` |
| `adb sync`（把 `$ANDROID_PRODUCT_OUT` 的分区同步到设备） | 没有 |
| `adb bugreport`（`bugreportz`，zip） | `shell:bugreport`，旧的文本输出 |
| `adb tcpip` / `adb usb` | `enableTcpip` 用 shell 执行 `setprop service.adb.tcp.port` 再 `stop adbd` / `start adbd`。新系统上这条 shell 经常没有权限。官方是设备服务 `tcpip:<端口>` 和 `usb:` |
| `adb reverse` | `AdbDevice.reverse` 把 `reverse:` 发给设备并读回文本。反向连接真正建立时，设备会向主机发 OPEN，要求主机去连本地端口。读循环遇到不是自己发出的 OPEN 会当成未知命令并拆掉连接。主机侧监听没有做 |
| `root` / `unroot`、`remount`、`disable-verity` / `enable-verity` | 未封装。官方客户端发给设备的同名服务可以被桥接 |
| `jdwp`、`track-jdwp`、`track-app` | 未封装。`forward` 的远端可以是 `jdwp:<pid>` |
| `framebuffer:`、`dev:`、`dev-raw:` | 未封装 |
| `sideload`、`rescue`、`backup` / `restore` | 未封装。`reboot` 的目标字符串会拼进 `reboot:`，调用方传入 `sideload` 时服务名是对的，但没有 sideload 传包 |
| `emu` | 没有模拟器控制台 |

`logcat` 在官方客户端里本质也是把参数交给设备上的 logcat。我们的封装是 `shell:logcat`，过滤器和 `-v`、`-B` 有了，没有官方客户端那层完整参数解析。

## USB 与发现

| 项目 | 官方 | 当前 |
|---|---|---|
| Windows 默认后端 | `AdbWinApi.dll`，按接口 GUID `{F72FE0D4-CBCB-407d-8814-9ED673D0DD6B}` 枚举。`ADB_LIBUSB=1` 才用 libusb | 三个桌面系统都用 libusb，按接口类匹配。不加载 `AdbWinApi` |
| 读写模型 | libusb 后端是读线程、写线程，各一次阻塞的 `libusb_bulk_transfer` | 每台设备一个 isolate：`libusb_submit_transfer` + `libusb_handle_events`。界面线程用 `libusb_interrupt_event_handler` 打断等待 |
| 热插拔 | libusb hotplug | `UsbAdbTracker` 每 2 秒枚举一次 |
| 复合设备 | `FindAdbInterface` 跳过 `bDeviceClass != 0` 的设备 | 复合设备也会打开 |
| 驱动 | Windows 默认路径依赖那个 GUID 已经注册。GUID 没有注册时官方找不到设备 | 只要接口已绑定 WinUSB 就能打开。GUID 未注册的手机，我们能看见、官方默认后端看不见 |
| 让出接口 | `adb detach` / `adb attach` | 进程占用接口期间，别的程序不能 claim。没有 detach |
| Linux / macOS | 系统自带或平台工具自己的 libusb，是默认后端 | 钩子登记系统库名 `libusb-1.0.so.0`、`libusb-1.0.dylib`，仓库不随包。这两端还没有真机验证 |
| Android | 不在官方桌面 adb 的范围里 | 没有 USB 路径。设备列表走本机 5037，可以是我们的 Server，也可以是设置里改用的 SDK `adb` |
| 和已有 Server 共存 | 版本不一致时客户端发 `host:kill` 再拉起自己的 `adb` | 版本保持 41。5037 已被占用时，本进程不再打开 USB，改用外面的 Server 列设备 |

模拟器扫描的端口集合与官方默认范围相同，但不读取 `ADB_LOCAL_TRANSPORT_MAX_PORT`。超过 5585 的模拟器端口不会出现。已经连上的端口不会重复拨号，没人听的端口依赖连接立即失败。

## 无线调试

配对协议和 STLS 已经按 AOSP 做了。和官方 Server 的差别在发现与信任：

- 官方 Server 在进程里做 mDNS（Bonjour，或 `ADB_MDNS_OPENSCREEN=1` 时用内置 openscreen），并按 `ADB_MDNS_AUTO_CONNECT` 自动连接 `_adb-tls-connect._tcp`。我们发现是用户点「扫描」之后的查询，连接也要再点一次。
- 官方把配对得到的对端身份写入 `adb_known_hosts.pb`，之后的 TLS 连接按这份名单校验。我们校验对端证书的 CertificateVerify 签名，不把设备证书落盘，也不做后续连接的 pinning。
- 配对用的 RSA 密钥是 FireAdb 自己的那一把，路径是桌面 `~/.config/fire_adb/adbkey.pem`，Android 上是应用私有目录里的同名文件。官方默认是 `~/.android/adbkey`。两把密钥不同，手机上会各弹一次授权。我们不扫描 `ADB_VENDOR_KEYS`。
- `adb tcpip` 打开的固定端口走普通 CNXN/AUTH。Android 11+ 无线调试的 TLS 端口走 STLS。这两条在直连 API 里都有。Server 的 `host:connect` 也走同一套 TCP 握手，因此可以连 TLS 端口；它不会自己去发现 mDNS。

## 密钥与列表里的状态

- 未授权时连接会标成 `unauthorized`，并出现在设备列表里。用户在手机上允许之后，要等下一轮 USB 枚举或 TCP 重连才会变成 `device`。官方还有独立的重连队列（失败后按间隔重试，大约最多一分钟）。我们的 USB 路径靠 2 秒枚举，模拟器靠 3 秒扫描。
- 断开 `host:disconnect` 且不带地址时，关掉的是全部非 USB 设备，USB 设备留在列表里。这和官方「断开全部 TCP」一致。
- 长列表在 Windows 上不打印 `1-3` 这种端口路径，查找时仍接受序列号、`1-3` 和 `usb:1-3`。

## 汇总

按「官方 `adb` 正在使用我们的 5037」和「FireAdb 自己调用」分开看，缺口数量不一样。

**官方客户端已经能用的：** `devices`、`devices -l`、`-s`、`-d`（唯一 USB）、`connect`、`disconnect`、`get-serialno`、`get-state`、`get-devpath`、`features`、`track-devices`、`shell`（含设备支持时的 `shell,v2`）、`exec-out`、`push` / `pull` / `sync:`、`install`（官方客户端自己的 streaming 或 abb 路径）、`reboot`、`root`、`remount`、`tcpip`、`usb`、`bugreport`、`logcat`、`jdwp`、TCP 的 `forward`（含 `tcp:0`）、`kill-server`。前提是服务在选中传输之后发给设备，或属于上表已经实现的主机服务。

**官方客户端会失败或行为不完整的：** `wait-for-*`、`host-features`、`server-status`、`mdns`、`pair`、`reconnect` / `reconnect offline`、`attach` / `detach`、`-e`（旧 transport-local）、非 TCP 的本地 `forward`、`reverse` 的数据面、`track-devices` 的 protobuf、模拟器的 `host:emulator` 即时登记、监听所有网卡、只跟踪一台设备。所有经我们转发的大流量传输都还是单 WRTE 在途。

**FireAdb 自己还缺的主机能力：** 上一段全部，再加上 shell v2、sync v2 与压缩、目录推送、streaming / 多 APK / incremental 安装、真正的 `tcpip:` / `usb:` 服务、reverse 主机监听、bugreport zip、root/remount/verity、jdwp 跟踪、mDNS 自动连接、`adb_known_hosts`、官方 `~/.android/adbkey` 与 `ADB_VENDOR_KEYS`、Linux 和 macOS 的真机 USB 验证。

Fastboot 不在这份对照里。官方 platform-tools 里的 `fastboot` 是另一条协议，本仓库没有实现。
