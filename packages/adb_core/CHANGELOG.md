## Unreleased

- 修复：FireAdb 占用 5037 时，官方 adb 无法把端口转到模拟器。Flutter 调试会执行 `adb -s emulator-5554 forward tcp:0 tcp:<端口>`。platform-tools 37 先发 `host:tport`，再发 `host:forward`。把 `host:forward` 原样 OPEN 给 adbd 会被拒绝：`设备拒绝服务 OPEN(local=26)（remoteId=0）`。改为本机监听后若少回一个 `OKAY`，端口长度 `0005` 会被读成 `protocol fault (status 30 30 30 35?!)`。成功时应答两个 `OKAY`，再跟上长度和端口数字。

## 1.0.0

- Initial version.
