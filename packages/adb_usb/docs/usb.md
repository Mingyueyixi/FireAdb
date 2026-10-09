# USB 方案

桌面端用 libusb 直接打开手机上的 ADB 接口，并在 `127.0.0.1:5037` 空闲时由本进程实现 ADB Server。界面和官方 `adb` 都通过这台 Server 看到设备、执行命令。不调用 `adb.exe`，也不链接 Android SDK 的 `AdbWinApi.dll` / `AdbWinUsbApi.dll`。

先前的疑问和结论见下文。逐条当时的记录在 [usb-qa.md](usb-qa.md)，对应提交 `3b10e568767875a08564378cf8facf440b99222d`。那份记录里的 20 毫秒轮询、以及一次查询后保持连接，都已经改掉。

## 现在能做什么

Windows 上可以枚举 ADB 接口、声明 WinUSB 接口、完成 AUTH/CNXN，并把手机登记进本机设备列表。真机验证过 OnePlus Ace 5（接口已绑定 WinUSB，序列号 `3B6F42E7NT8RZL34`）。

本进程占着 5037 时，官方 `adb devices`、`adb -s` 和 `adb shell` 可以连到这台 Server。列表第一列是 USB 序列号字符串。长列表按官方 `%-22s` 补齐，Windows 上不打印端口路径。`adb shell` 能拿到设备 banner 里的 `features=`，并在同一条连接上完成 `host:tport:` 和后续的 `shell:`。

本机模拟器也会出现在同一份列表里。adb 端口 `5557` 显示为 `emulator-5556`。

Linux、macOS 按系统库名加载 libusb。上游没有发布这两套动态库，仓库也没有放进去；构建钩子登记的是 `libusb-1.0.so.0` 和 `libusb-1.0.dylib`。这两端还没有真机验证。Android 没有这条 USB 路径。Android 上的设备列表仍然走本机 5037：进程会启动 ADB Server，只是不枚举 USB。应用通过 `libadb` 做这次组装。

## 设备从哪来

三条路径都登记到同一个 `AdbServer`，首页只向 `127.0.0.1:5037` 要 `host:devices-l`。

| 来源 | 谁在扫 | 跑在哪 | 列表里的序列号 |
|---|---|---|---|
| USB 手机 | `UsbAdbTracker`，每 2 秒 | 定时器在主 isolate；枚举用一次短命 isolate，避免 libusb 挡住界面 | USB 字符串描述符 `iSerialNumber`。没有时才用 banner 里的序列号，再退回 `usb:1-3` 这种地址 |
| 本机模拟器 | `AdbServer`，启动时一次，之后每 3 秒 | 主 isolate 的定时器。16 个回环端口：`5555`、`5557`……`5585`，连接超时 300 毫秒 | `emulator-<端口-1>`。已连上的端口不再拨 |
| 手动 TCP | `host:connect:host:port` | 客户端这次命令 | 对端 banner 里的序列号 |

首页自己的 3 秒刷新也是主 isolate 上的 `Timer`。到点只发一次 `host:devices-l`，不枚举 USB，也不扫模拟器端口。两次触发之间定时器挂在事件循环上。

本进程只在 5037 空闲时监听。端口已被占用就沿用外面的 Server，不再自己打开 USB，首页也就不再显示直连 USB 条目。一块接口同时只能有一个程序声明成功。

产品名、型号来自连接成功后的 `getprop`（模拟器则来自 CNXN banner 的 `ro.product.*`）。`adb devices` 的短格式是 `序列号<TAB>状态`。长格式在序列号后补齐到 22 列，再写状态、`product:`、`model:`、`device:` 和 `transport_id:`。`devPath` 仍保存在设备对象上，供 `adb -s 1-3` 和 `adb -s usb:1-3` 查找；只有路径里含有 `/`（Linux 的 `/dev/bus/usb/...`）才写进长列表。因此 Windows 上从 `devices -l` 解析回来的设备没有 `devPath`，首页图标按普通手机显示。

## 一台 USB 设备占哪个 isolate

界面线程不调用 libusb 的批量传输。打开一台手机时只起一个 isolate：

它 `libusb_open`、声明接口、读取序列号，然后提交一个没有超时的批量读。接着调用 `libusb_handle_events`，一直停到内核报告这批传输结束，或者主 isolate 要写入、关闭时调用 `libusb_interrupt_event_handler` 把等待打断。完成回调先回到这个 isolate 的事件循环，把数据交给界面，再提交下一次读或写。写出的长度正好是包长整数倍时，再提交一个零长度包。

手机空闲时这个 isolate 停在内核的 WinUSB 重叠 I/O 上，不轮询。每个设备仍有自己的 `libusb_init` 上下文。关闭时先 `libusb_cancel_transfer`，等回调回来再 `libusb_close`。界面最多再等 2 秒，然后 `Isolate.kill`。

## 接口怎么认

和 AOSP `is_adb_interface` 一致：

- 类 `0xFF`，子类 `0x42`，协议 `0x01`
- Debug Capability：类 `0xDC`，子类 `0x02`，协议 `0x01`

接口上要同时有批量 IN 和批量 OUT。`wMaxPacketSize` 只用低 11 位。写出的长度大于 0 且正好是包长整数倍时，再补一个零长度包。

枚举阶段只读描述符，不调用 `libusb_open`。打开时按端口路径匹配第一台带 ADB 接口的设备，然后 `libusb_open` 并 `claim`。复合设备（`bDeviceClass` 不是 0）也会纳入。AOSP 的 `FindAdbInterface` 会跳过这类设备。

## 动态库

Windows 随包文件来自官方 libusb **1.0.29** 的 `libusb-1.0.29.7z`，许可证是 LGPL-2.1。对照源码在 `third_party/libusb`，固定为标签 `v1.0.29`（上游 [libusb/libusb](https://github.com/libusb/libusb/releases/tag/v1.0.29)）。

- x64：`VS2022/MS64/dll/libusb-1.0.dll`，放在 `packages/adb_usb/vendor/windows/x64/`
- ARM64：`MinGW-llvm-aarch64/dll/libusb-1.0.dll`，放在 `packages/adb_usb/vendor/windows/arm64/`。同一份压缩包的 VS2022 目录没有 ARM64 构建

`hook/build.dart` 按目标系统登记代码资源，资源 id 是 `package:adb_usb/src/libusb.dart`：

| 目标 | 钩子做什么 |
|---|---|
| Windows x64 | 拷贝 `vendor/windows/x64/libusb-1.0.dll`，随包。缺这个文件构建失败 |
| Windows ARM64 | 拷贝 `vendor/windows/arm64/libusb-1.0.dll`，随包。缺这个文件构建失败 |
| Linux x64 / arm64、macOS x64 / arm64 | `vendor/<系统>/<架构>/` 里有文件就随包。仓库里现在没有，改为登记系统库名 `libusb-1.0.so.0` 或 `libusb-1.0.dylib` |
| Android | 不登记 |

引用这个包不必再改应用的 CMake。运行时按文件名 `DynamicLibrary.open`。当前 Flutter 使用的 Dart 3.13 还没有 `DynamicLibrary.codeAsset`，随包文件必须保持 `libusb-1.0.dll` 这个名字，构建才会把它放在可执行文件旁边。

加载顺序：

1. 环境变量 `FIRE_ADB_LIBUSB`
2. Windows：可执行文件旁边的 `libusb-1.0.dll`，再从可执行文件向上最多 10 层找与当前进程架构对应的那份（`vendor/windows/x64/libusb-1.0.dll` 或 `vendor/windows/arm64/libusb-1.0.dll`），最后按名字 `libusb-1.0.dll` 交给系统搜索。一次构建只打一个架构。在 ARM 电脑上用 x64 模拟跑起来的进程仍加载 x64 DLL
3. Linux：可执行文件旁边的 `libusb-1.0.so.0`，否则系统库名
4. macOS：Homebrew 的 `/opt/homebrew/lib/libusb-1.0.dylib`、`/usr/local/lib/libusb-1.0.dylib`，再退回 `libusb-1.0.dylib`

这份 DLL 不代替 USB 驱动。libusb 在 Windows 上通过 `winusb.dll` 打开已经绑定 WinUSB 的接口。手机若绑的是别的驱动，需要先换成 WinUSB。系统自带的 MS OS 兼容 ID 也可以完成绑定，这种情况下不必再装 Google USB 驱动。同一接口同时只能有一个程序声明成功。

官方 Windows 客户端默认不走 libusb，除非设置 `ADB_LIBUSB=1`。它通过 `AdbWinApi.dll` 按 GUID `{F72FE0D4-CBCB-407d-8814-9ED673D0DD6B}` 枚举。SDK 里现成的那份 DLL 是 32 位的，64 位 Dart 进程加载不了。本方案不移植这套 DLL。

## 本机 5037

协议版本是 41（`host:version` 返回 `0029`）。版本不一致时，官方客户端会发 `host:kill` 再拉起自己的 `adb.exe`。

一次查询写完结果后关闭 TCP 连接，官方 `adb` 要读到对端关闭才会结束命令。属于这一类的有 `host:version`、`host:devices`、`host:devices-l`、`host:connect`、`host:disconnect`，以及 `get-serialno`、`get-state`、`get-devpath`、`features`。

`host:features` 返回这台设备 CNXN banner 里的 `features=`，不是主机自己的功能列表。`adb shell` 靠它决定用 `shell,v2` 还是旧的 `shell:`。接着在同一条连接上发送 `host:tport:`，读完 8 字节小端 transport id（`uint64_t`）后再发 shell 服务。这条连接保持到 shell 结束。`host:track-devices` 也保持连接。`host-serial:<序列号>:<方法>` 用最后一个冒号切分，这样 `usb:1-3` 和 `192.168.1.5:5555` 都能当序列号。

## 先前确认过的问题

**调试器里 usbWorker 一直暂停又运行。** 当时读和写挤在同一个 isolate 里，空闲读用 20 毫秒超时让出事件循环，调试器就把原生阻塞显示成暂停。连接本身没有在断开。后来曾拆成读、写各一个 isolate，超时改为 0。现在收成一个 isolate：`libusb_submit_transfer` 把传输交给内核，`libusb_handle_events` 停在那里，有数据或主 isolate 打断时才返回。

**为什么当时要轮询。** `libusb_bulk_transfer` 返回之前，这个 isolate 上的 Dart 代码都不会跑。读一直堵着，`CNXN`、`OPEN`、`WRTE` 就发不出去。20 毫秒只是写入最多晚多久，协议里没有这个间隔。异步提交没有这个问题：读和写可以同时挂在内核上，事件循环被打断后两边都能继续。

**官方 USB 是不是也这样轮询。** 不是。官方 libusb 后端是一条读线程、一条写线程，两边都调用同步的 `libusb_bulk_transfer`，超时是 0。源码在 `third_party/aosp-adb/client/usb_libusb.cpp`。我们没有照搬那两条线程。一台手机只有一个 isolate，用 `libusb_submit_transfer` 和 `libusb_handle_events` 等内核事件。几台手机就几个 isolate，不会把线程耗尽。界面线程只发消息，并调用 `libusb_interrupt_event_handler` 把堵在事件循环里的 isolate 叫醒。

**libusb 为什么用线程，不能等内核事件吗。** 真正的等待就是内核事件：Windows 上是 WinUSB 的重叠 I/O，Linux 上是 usbfs 的 poll。`libusb_bulk_transfer` 只是同步包装，调用方要停到这一次传输结束，所以官方才用两条线程。异步接口是 `libusb_submit_transfer` 加 `libusb_handle_events`。当前代码走的就是这条。

**没有官方 adb server，USB 还能连吗。** 能。`openUsbAdbDevice` 直接声明接口并做 AUTH/CNXN，不经过 5037。本应用自己的 shell、文件、截图走这条直连就够。Server 是为了让首页和官方 `adb` 共用已经打开的接口。一块接口只能有一个程序声明成功，所以本进程占着 5037 时，界面不再对同一台手机做第二次打开。

**官方 `adb devices` 连上我们的 5037 却停住。** 客户端不检查对面是不是 Google 的进程。它每次先发 `host:version`，读完 4 位十六进制版本号，然后一直读到对端关掉 TCP。当时我们回了 `OKAY` 却留着连接，命令就不会结束。版本不是 41 时，官方客户端还会 `host:kill` 再拉起自己的 `adb.exe`。现在一次查询写完就关连接，版本保持 41。`adb shell` 还要 `host:features`（设备 banner 里的功能）和同一条连接上的 `host:tport:`，这两处也已经接上。

**`adb devices -l` 和官方差在哪。** 官方 Windows 把 devpath 留空，序列号按 `%-22s` 补齐。我们曾经把端口路径 `1-3` 打进长列表，并且只隔了一个空格。现在补齐方式与官方相同，含 `/` 的路径才打印。`adb -s` 仍接受序列号、`1-3` 和 `usb:1-3`。

**官方能看到两台，我们只有手机。** 第二台是本机模拟器 `emulator-5556`，adb 端口是 5557。官方启动时会扫 `5555` 起的偶数间隔端口。我们之前只登记 USB 和手动 `host:connect`。现在按同一范围扫描。

**每 3 秒扫这些端口会不会有问题。** 只有 16 个回环端口。没人听的端口会立刻被拒绝，已经连上的不再拨。首页那次 3 秒刷新是另一个主 isolate 定时器，只发 `host:devices-l`，不参加这次扫描。

**要不要改成 AdbWinApi.dll。** 不改。它只覆盖 Windows，SDK 里那份是 32 位的，64 位 Dart 加载不了，枚举、打开和读写都要重写。libusb 三个桌面系统可以共用，这台已经绑上 WinUSB 的手机不用再装 Google 驱动。

**随包的 libusb DLL 是不是就不用 Google USB 驱动了。** DLL 不代替驱动。它通过 `winusb.dll` 打开已经绑定 WinUSB 的接口。OnePlus Ace 5 是系统按 MS OS 兼容 ID 自动绑上的，没有另装 Google 的 INF。官方 `AdbWinApi` 还要求接口注册了 Android GUID；GUID 没有注册时它会找不到设备。libusb 按接口类 `0xFF/0x42/0x01` 过滤，WinUSB 绑上了就能打开。

## Google 为什么自己写 Windows USB API

`client/usb_windows.cpp` 的版权是 2007 年。注释写明接口 GUID 由当时的内核驱动 `androidusb.sys` 分配，用户态结构体走的是 `AdbWinApi.dll`：一个接口句柄，外加分开的读管道和写管道。关掉读管道就能把堵在读里的线程拉出来。

那时候 Windows 没有 Linux usbfs 这种让普通程序直接声明一个厂商类接口的接口。ADB 接口是厂商类 `0xFF`，系统没有现成的类驱动会去认它。libusb 1.0 的 WinUSB 后端也还不是能依赖的默认方案；当时 Windows 上的 libusb 还要配自己的内核驱动，打不开绑在 `androidusb.sys` 上的设备。Google 的做法是自己带内核驱动，再写一套只暴露 adb 需要的用户态 API：按 GUID 枚举、打开接口、分开读写管道、同步传输、零长度包、读序列号。platform-tools 因此不必依赖 LGPL 的 libusb。

后来内核改成系统自带的 `winusb.sys`，用户态仍调用同一套 `AdbWinApi.dll` / `AdbWinUsbApi.dll`，GUID 也没换，所以 Windows 上的默认后端一直是它。手机 gadget 的 MS OS 描述符里仍然公布这个 GUID，源码在 `daemon/usb_ffs.cpp`。官方客户端里的 libusb 是后加的：Linux、macOS 默认使用；Windows 上 `is_libusb_enabled()` 默认关闭，要设 `ADB_LIBUSB=1` 才走 libusb。

这套 API 留到现在，不完全是历史包袱。它只看见注册了 Android GUID 的接口，读管道和写管道天然分开，platform-tools 里已经带了 Apache 2.0 的 DLL。换成 libusb 会改变「找设备」的规则，还要在 Windows 上多带一份库。FireAdb 要覆盖三个桌面系统，所以选 libusb，而不是把这套只服务 Windows 的 API 搬过来。

## 还没做

- Linux、macOS 的真机验证。上游没有这两套预编译库；若以后放进 `vendor/linux/` 或 `vendor/macos/`，现有钩子会改成随包
