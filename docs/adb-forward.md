# 官方 adb 经 FireAdb 做端口转发

FireAdb 占着 `127.0.0.1:5037` 时，Flutter 调试官方模拟器会执行：

```text
adb -s emulator-5554 forward tcp:0 tcp:<虚拟机服务端口>
```

platform-tools 37 的客户端在一条连接上分两步发：

1. `host:tport:serial:emulator-5554`，读 `OKAY` 和 8 字节 transport id。
2. `host:forward:tcp:0;tcp:<端口>`。

`forward` 由本机 server 完成：在 `127.0.0.1` 上分配端口，把这个端口回给 `adb`，等调试器连上来，再向模拟器 `OPEN tcp:<端口>`。`host:forward:...` 本身不能 `OPEN` 给 adbd。

## 设备拒绝 OPEN

把 `host:forward:tcp:0;tcp:38077` 原样发给模拟器时，adbd 没有这条服务，直接 `CLSE`。`adb` 打印：

```text
AdbInvalidResponseError: 设备拒绝服务 OPEN(local=26)（remoteId=0）
```

`local` 是这条连接上的流序号，`remoteId=0` 表示设备没有回 `OKAY`。Windows 控制台按系统代码页显示这段 UTF-8 时，会看成 `璁惧鎷掔粷鏈嶅姟 OPEN...`。

## 状态码读到端口长度

选中设备之后，客户端要先读两个 `OKAY`：`adb_connect` 读一个，命令行再读一个，然后才读 4 位十六进制长度和端口数字。少回一个 `OKAY` 时，第二次读到的是长度 `0005`（ASCII `30 30 30 35`）：

```text
protocol fault (status 30 30 30 35?!)
```

`tcp:0` 成功时的应答顺序是 `OKAY`、`OKAY`、长度、端口数字。例如端口 `38077`：

```text
OKAYOKAY000538077
```
