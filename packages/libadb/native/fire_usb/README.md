# fire_usb

进程内持有 libusb 设备句柄的一小层 C。

## 为什么要有它

Flutter 热重启只换掉 Dart isolate，进程和已加载的动态库都还在。

句柄如果只记在 Dart 里：

1. 热重启后静态变量清空
2. 旧 isolate 的 `NativeFinalizer` 往往不跑
3. WinUSB 接口仍被旧句柄占着，新的 `claim` 得到 ACCESS

`fire_usb` 把 `context` / `handle` / 接口号放进这份 C 的静态表。新的 Dart 调
`fire_usb_close(port_path)` 或再次 `fire_usb_open`，就会对旧句柄做
`release_interface` + `close`。

## API

| 函数 | 作用 |
|---|---|
| `fire_usb_open(libusb_path, port_path, &info)` | 加载 libusb，按端口路径打开并声明 ADB 接口；同路径已有会话则先关 |
| `fire_usb_close(port_path)` | 释放该端口会话 |
| `fire_usb_close_all()` | 释放本进程全部会话 |
| `fire_usb_is_open(port_path)` | 表里是否还握着该端口 |

读写传输仍可由 Dart 用返回的 `handle` / `context` 做（现有 `handle_events`
路径）。所有权在 C：Dart 不要再对这个 handle 调 `libusb_close`。

## 构建（Windows x64）

在仓库里，`libusb-1.0.dll` 已在 `vendor/windows/x64/`。本库运行时
`LoadLibrary` 加载它，编译时不链接 libusb。

```bat
cd packages\libadb\native\fire_usb
cl /nologo /O2 /LD /DFIRE_USB_BUILD fire_usb.c /Fe:..\..\vendor\windows\x64\fire_usb.dll
```

或：

```powershell
..\..\tool\build_fire_usb.ps1
```

生成 `packages/libadb/vendor/windows/x64/fire_usb.dll`。应用运行时把它和
`libusb-1.0.dll` 放在可执行文件旁边，或设环境变量 `FIRE_ADB_FIRE_USB`。

## 热重启时序

```
冷启动:  fire_usb_open("1-1")     → 表里登记句柄
热重启:  Dart 静态变量清空，C 表还在
再打开:  fire_usb_open("1-1")     → 先 close 旧行，再 open
正常关:  fire_usb_close("1-1")    → release + close + exit context
```
