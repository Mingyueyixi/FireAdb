## 0.1.0

- Windows：用 libusb 枚举并打开 ADB 接口，经本机 ADB Server 出现在设备列表。
- 读写仍在单个 isolate 中同步进行，空闲读超时 20 毫秒。说明见 `docs/usb.md`。
