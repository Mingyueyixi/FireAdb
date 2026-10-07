# USB 方案

桌面端用 libusb 直接打开手机上的 ADB 接口。本进程在 `127.0.0.1:5037` 空闲时自己实现 ADB Server，把已经握完手的 USB 设备登记进去。界面上的设备列表来自 `host:devices-l`，连接走 `host:transport`。

不调用 `adb.exe`，也不链接 Android SDK 的 `AdbWinApi.dll` / `AdbWinUsbApi.dll`。

## 现在能做什么

Windows 上可以枚举 ADB 接口、声明 WinUSB 接口、完成 AUTH/CNXN，并让这台手机出现在本机设备列表里。真机验证过 OnePlus Ace 5（接口已绑定 WinUSB）。

Linux、macOS 只按系统库名加载 libusb，仓库没有带上对应动态库，也没有在真机上验证。Android 的 USB Host（`android.hardware.usb`）还没做，Android 上也不会去连 `127.0.0.1:5037`。

## 组件

| 位置 | 作用 |
|---|---|
| `packages/adb_usb` | 用 `dart_libusb` 枚举、打开接口，实现 `AdbTransport` |
| `packages/adb_core` 的 `AdbServer` | 协议版本 41 的本机 smart socket，默认端口 5037 |
| `UsbAdbTracker` | 每 2 秒枚举一次。新的端口路径会打开并握手，然后 `upsert` 到 server |
| `ConnectionManager.ensureLocalAdbServer` | 应用启动时占用 5037。端口已被占用就沿用外面的 server，不再打开 USB |
| 首页设备列表 | 本进程占着 5037 时，USB 设备只出现在 `host:devices` 里，避免再打开一次同一个接口 |

`devPath` 使用不含冒号的端口路径（例如 `1-3`）。`devices -l` 会把带冒号的字段当成 `key:value`。

## 接口怎么认

和 AOSP `is_adb_interface` 一致：

- 类 `0xFF`，子类 `0x42`，协议 `0x01`
- Debug Capability：类 `0xDC`，子类 `0x02`，协议 `0x01`

接口上要同时有批量 IN 和批量 OUT。`wMaxPacketSize` 只用低 11 位。写出的长度大于 0 且正好是包长整数倍时，再补一个零长度包。

枚举阶段只读描述符，不调用 `libusb_open`。打开时按端口路径匹配第一台带 ADB 接口的设备，然后 `libusb_open` 并 `claim`。复合设备（`bDeviceClass` 不是 0）也会纳入。AOSP 的 `FindAdbInterface` 会跳过这类设备。

## 动态库

Windows 随包文件是官方 libusb **1.0.29** 的 `VS2022/MS64/dll/libusb-1.0.dll`，放在 `packages/adb_usb/vendor/windows/`。许可证是 LGPL-2.1，源码在 [libusb/libusb](https://github.com/libusb/libusb/releases/tag/v1.0.29)。Windows 构建会在该文件存在时把它装到 `fire_adb.exe` 旁边。

加载顺序：

1. 环境变量 `FIRE_ADB_LIBUSB`
2. 可执行文件旁边的 `libusb-1.0.dll`
3. 从可执行文件向上最多 10 层，查找 `packages/adb_usb/vendor/windows/libusb-1.0.dll`
4. 否则按名字 `libusb-1.0.dll` 交给系统搜索

Linux 加载 `libusb-1.0.so.0`。macOS 依次尝试 Homebrew 的 `/opt/homebrew/lib/libusb-1.0.dylib`、`/usr/local/lib/libusb-1.0.dylib`，再退回 `libusb-1.0.dylib`。

这份 DLL 不代替 USB 驱动。libusb 在 Windows 上通过 `winusb.dll` 打开已经绑定 WinUSB 的接口。手机若绑的是别的驱动，需要先换成 WinUSB。系统自带的 MS OS 兼容 ID 也可以完成绑定，这种情况下不必再装 Google USB 驱动。同一接口同时只能有一个程序声明成功。

## 读写为什么是短超时

官方 libusb 后端是两条操作系统线程：读线程和写线程都调用 `libusb_bulk_transfer`，超时为 0，一直阻塞到本次传输结束。读停住时，写线程仍能把包发出去。

当前实现把读写放在同一个 Dart isolate 里，用的是同步的 `libusb_bulk_transfer`。这次调用返回之前，isolate 上的端口回调不会执行。手机没有数据时如果一直堵在读上，待发的 `CNXN`、`OPEN`、`WRTE` 就送不出去。

所以空闲读的超时是 20 毫秒。超时后用 `Future.delayed(Duration.zero)` 把事件循环让出来，收进写入队列，下一轮再写，然后继续读。20 毫秒是单 isolate 同步调用下的写入延迟上限，不是协议间隔。调试器里这个 isolate 会表现为反复暂停和运行：停在原生读里，超时后又回到 Dart。USB 连接本身在这个循环里保持打开。

后续若要改成和官方一样的阻塞读写，需要把读、写拆开（两条线程，或 libusb 异步传输加 `libusb_handle_events`）。同一个 `libusb` 设备句柄不能直接丢给另一个 Dart isolate 当作共享对象使用。

## 还没做

- Android USB Host
- Linux、macOS 动态库打包和真机验证
- 用双线程或异步传输去掉 20 毫秒轮询
- 移植 `AdbWinUsbApi.dll`
