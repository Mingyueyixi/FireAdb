# USB 与本机 ADB Server 问答

整理实现 Windows USB 传输和本机 ADB Server 时确认过的问题。按当前代码归纳后的结论，包括 Google 为何自写 Windows USB API，见 [usb.md](usb.md) 的「先前确认过的问题」和「Google 为什么自己写 Windows USB API」。

本文描述的是提交 `3b10e568767875a08564378cf8facf440b99222d`（`[feat] 实现 Windows USB 传输和本机 ADB Server`）。单 isolate 的 20 毫秒轮询，以及 `host:version` / `host:devices` 回答后保持连接，都是这次提交里的行为，后来已经改掉。下文记录当时为什么会这样。当前实现见 [usb.md](usb.md)。

## usbWorker 为什么一直在暂停又运行

连接没有在反复断开。手机连上之后，`usbWorker` 这个后台 isolate 会一直占着 USB 接口。调试器里的「暂停 / 运行」是空闲读在来回切换。

读和写都走同一次同步的 `libusb_bulk_transfer`。读不返回，写就发不出去。空闲读的超时是 **20 毫秒**：超时回到 Dart，用 `Future.delayed(Duration.zero)` 让出事件循环，把排队的写入发出去，然后再阻塞进下一次读。调试器把卡在原生读里显示成暂停，回到 Dart 就显示成运行，大约每秒来回 50 次。

设备列表里的那一行一直在，就说明连接还在。只有那一行消失再出现，才是连接被拆掉后又重新打开。

## 为什么要这样轮询

因为读和写挤在同一个 Dart isolate 里，而 `libusb_bulk_transfer` 是同步调用。它没返回之前，这个 isolate 上的 Dart 代码都不会跑，包括用来接收写入请求的端口。

手机空闲时往往没有数据可收。如果这次读一直堵到有数据为止，主 isolate 发出去的 `CNXN`、`OPEN`、`WRTE` 就只能堆在队列里，USB 上什么都发不出去，握手和对端就会互相干等。

20 毫秒只决定一条写入最多晚多久发出去。协议本身没有这个间隔。`Duration.zero` 也是必需的：批量传输返回后仍在同一次同步循环里，必须把事件循环让出去，端口回调才有机会把待写数据放进队列。

## 正常的 USB 实现要不要这样做

不用。官方 adb 的 libusb 后端把读和写放在两条操作系统线程里，两边都调用 `libusb_bulk_transfer`，超时参数是 `0`，一直阻塞到这次传输结束。

读线程停在批量输入端点上。写线程平时睡在条件变量上，队列里有包才醒来，写到批量输出端点。手机没有数据时，读线程就停着，写线程仍然能立刻把包发出去。libusb 允许同一个设备句柄上，一个线程读、另一个线程写。对应源码是 `third_party/aosp-adb/client/usb_libusb.cpp` 和 `usb_libusb_device.cpp`。

当前的 20 毫秒轮询是单 isolate 同步调用的凑法。要改成和官方一样的阻塞读写，需要把读、写拆开：两条线程，或者 libusb 异步传输加上 `libusb_handle_events`。同一个 libusb 设备句柄不能直接丢给另一个 Dart isolate 当作共享对象使用。

## 现在能 USB 直连吗，还要不要 ADB Server

能直连。`openUsbAdbDevice` 会直接声明接口并做 AUTH/CNXN，这条路径不经过 5037。本应用自己执行 shell、文件、截图，有这条直连就够了。

ADB Server 做的是另一件事。一块 USB 接口同时只能有一个程序声明成功。Server 声明之后，首页和其他客户端通过 `host:devices`、`host:transport` 共用它。本进程占着 5037 时，界面会藏起直连条目，避免对同一台手机再打开一次。

Server 不是 USB 协议的一部分。只服务 FireAdb 时可以不监听 5037，自己枚举并直连。要让设备出现在 `adb devices` 里，或者几个客户端同时用这台手机，才需要它。

## 官方 adb devices 为什么连不上我们的 5037

官方客户端只认 `127.0.0.1:5037`，也可以用环境变量 `ANDROID_ADB_SERVER_PORT` 改端口。它不检查对面是不是 Google 的进程。

每次命令会先发 `host:version`，读到 4 位十六进制版本号，然后一直读到对方把 TCP 连接关掉。AOSP `ReadOrderlyShutdown` 写明了：对面不关连接，这次读就不会返回。我们的 `host:version` 和 `host:devices` 回了 `OKAY` 和内容之后，连接还留着等下一条命令，官方 `adb devices` 就会停在等关闭。

版本号对不上时，官方客户端还会发 `host:kill`，再拉起自己的 `adb.exe` 占 5037。仓库里的版本常量是 41，和当前 AOSP 的 `ADB_SERVER_VERSION` 一致。机器上的 platform-tools 若更旧或更新，会走这条替换流程。

换一个端口可以躲开冲突：官方 `adb devices` 不再撞上我们，也不会把我们杀掉。那台手机仍然不会出现在它的列表里，因为接口在我们手里，官方 Server 打开不了。要让官方客户端使用我们的 Server，两边必须听同一个端口，版本号要一致，而且 `host:version`、`host:devices` 这类一次查询在写完结果后必须关闭连接。

## 要不要改成 AdbWinUsbApi.dll

继续用 libusb 更合适，改过去的工作量也更大。

官方 Windows 客户端并不直接调用 WinUSB，而是通过 `AdbWinApi.dll` 使用大约十五个接口：按 GUID `{F72FE0D4-CBCB-407d-8814-9ED673D0DD6B}` 枚举、按接口名打开、分别打开批量读管道和写管道、同步读写、零长度包，再读取序列号和设备描述符。接到现在的代码里，`adb_usb_session.dart`、`libusb_loader.dart` 和接口匹配都要换成这套 FFI，CMake 也要改成带上新的 DLL。SDK 里现成的那份是 32 位的，64 位 Dart 进程加载不了，还得另外准备 64 位的 `AdbWinApi.dll` 和 `AdbWinUsbApi.dll`。这套只覆盖 Windows。

`AdbServer`、`UsbAdbTracker` 和 `AdbTransport` 可以留下。设备从「端口路径 + 接口类」变成「接口名 + GUID」，打开和枚举的调用点都要跟着改。

当前方案还没做完的部分集中在 `usbWorker` 那一个循环：读和写拆开，去掉 20 毫秒轮询。若还要让官方 `adb devices` 可用，再改 `AdbServer` 在一次查询后关闭连接。这些都不换掉已经接通的 USB 打开路径。

## 两个方案的差别

libusb 适合这个跨平台应用。官方那套适合只做 Windows，并且要和 platform-tools 用同一套接口 GUID。

| | libusb（当前） | AdbWinApi / AdbWinUsbApi |
|---|---|---|
| 平台 | Windows、Linux、macOS 同一套打开和读写 | 只有 Windows |
| 找设备 | 按接口类 `0xFF/0x42/0x01` 在所有 USB 设备里过滤 | 只枚举注册了 Android GUID 的接口 |
| 驱动 | 接口已经绑 WinUSB 即可，不一定要 Google 的 INF | 依赖那个 GUID。Google INF 或手机的 MS OS 描述符都能注册它 |
| 读写 | 一个设备句柄上的同步批量传输。官方用法是读、写各一条线程 | 读管道和写管道分开，关掉句柄就能把堵在读里的线程唤醒 |
| 分发 | 要带 LGPL 的 `libusb-1.0.dll` | platform-tools 自带，Apache 2.0，不依赖系统里的 libusb |
| 和现有代码 | Windows 上已经接通 | 要换掉枚举、打开和读写，还得自备 64 位 DLL |

对 FireAdb，libusb 的优势是三个桌面系统共用，这台手机不装 Google 驱动也能打开。代价是 Windows 上要自己处理句柄互斥、零长度包，以及单 isolate 不能一边堵在读上一边写。官方 DLL 的优势是读写管道和「关掉即唤醒」已经做好，并且只看见 Android 接口。代价是平台只有 Windows，设备必须带那个 GUID，还要解决 32 位 DLL 不能装进 64 位进程的问题。

## Google 为什么自己做一套

`usb_windows.cpp` 的版权是 2007 年，注释里还写着接口 GUID 由 `androidusb.sys` 分配。那时 Windows 没有像 Linux usbfs 那样让普通程序直接声明一个厂商类接口，libusb 1.0 的 WinUSB 后端也还没成熟。Google 的做法是：内核用自己的 `androidusb.sys`，用户态用 `AdbWinApi.dll` 只暴露 adb 需要的操作。后来内核改走系统的 `winusb.sys`，`adb.exe` 仍然调用同一套 DLL，所以 Windows 默认后端到现在还是它。

libusb 在官方客户端里是后加的。Linux、macOS 默认用。Windows 上 `is_libusb_enabled()` 默认是关的，要设 `ADB_LIBUSB=1` 才走 libusb。

## 用官方方案要不要先装 Google USB 驱动

不必把 Google USB 驱动当成官方方案的前提。两条路线最后都是打开已经绑定 WinUSB 的 ADB 接口。Google 的 `android_winusb.inf` 只是旧的绑定方式，它同时注册官方要找的接口 GUID。

现在的手机通常用 MS OS 兼容 ID 让 Windows 自带的 WinUSB 自动绑上。验证过的 OnePlus Ace 5 就是这样，没有另装 Google 驱动。官方 `AdbWinApi` 按那个 GUID 枚举；GUID 没有注册时，它会找不到设备。libusb 按接口类枚举，只要 WinUSB 绑上了就能打开。

## 结论

USB 保持 libusb。FireAdb 自己的连接用直连。5037 只有在要兼容官方 `adb` 时才监听，并且一次查询后关闭连接、版本保持 41。若只想避免和已安装的 platform-tools 抢端口，就不要监听 5037，让官方 Server 占着它；检测到 5037 已有 Server 时继续用它列设备，不再自己打开 USB。
