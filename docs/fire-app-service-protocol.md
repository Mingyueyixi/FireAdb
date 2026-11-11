# FireAppService 消息格式

桌面端和设备上的 `FireAppService` 用同一种消息说话。通道仍是 ADB `exec:` 的标准输入和标准输出：原始字节，没有终端，也不做换行转换。聊天使用同一帧格式，通道是设备服务 `tcp:28165`，见 [chat-channel.md](chat-channel.md)。

## 一条消息

```text
name type id length:正文
```

`clipboard.get none 1 0:` 是一条没有正文的请求。`clipboard.data json 1 16:{"text":"hello"}` 是它的回复。冒号左边是头，右边 16 字节才是 JSON。

从这条消息的起点依次读取 `name`、`type`、`id`、`length`，下一字节必须是 `:`。头里面没有冒号。正文里的冒号、空格和换行都按 `length` 读取，不会被当成下一条的头。

只回一条时，收到这个 `id` 的回复，请求就结束。回多少条事先不确定时，条目发完后再发一条文本消息：

```text
session.done text 4 2:ok
```

收到同一个 `id` 的 `session.done`，这批回复结束。`ok` 是 2 字节。正文也可以写成条数或其他说明。

ADB 会把一条消息拆成多次送达。头或正文没读够就继续等。整条消息一次写完。设备上命令线程和剪贴板回调都会写标准输出，用同一把锁包住整条消息。

## 头里的字段

| 顺序 | 字段 | 含义 |
|---|---|---|
| 1 | `name` | 这是什么事，如 `clipboard.get`、`catalog.app`。不含空格和冒号 |
| 2 | `type` | 正文格式：`json`、`bytes`、`text`、`html`。没有正文时写 `none` |
| 3 | `id` | 请求号。请求和它的全部回复用同一个号。主动推送写 `0` |
| 4 | `length` | 正文的字节数。没有正文写 `0` |

`json`、`text`、`html` 的正文是 UTF-8。`bytes` 是原始字节。

版本不放进每一条消息。进程启动后的第一条是 `session.ready`，正文是版本号文本 `1`。桌面端看到的不是 `1` 就关掉连接。

头上限 8 KiB。头只放四个短字段，超了就丢掉这条连接。正文没有大小上限。

`length` 标出这条消息在长连接上的边界。管道里下一条消息紧跟着，不能读到连接关闭才算结束。正文按实际到达的字节分段读入，不按声明的长度先分配一整块。

## 怎么知道读完

1. 从当前字节起，按空格读出 `name`、`type`、`id`、`length`。
2. 下一字节必须是 `:`。
3. 再分段读满 `length` 个已经到达的字节。读满，这条消息结束。`length` 为 0 时，冒号出现后就结束。
4. 只期待一条回复时，这条回复到达，请求结束。
5. 条数不固定时，继续读同一个 `id`，直到 `session.done`。
6. 下一个字节是下一条消息的 `name`。

## 请求和响应

```text
clipboard.get none 1 0:
clipboard.data json 1 16:{"text":"hello"}
```

写入剪贴板。`{"text":"hello"}` 是 16 字节：

```text
clipboard.set json 3 16:{"text":"hello"}
clipboard.ok none 3 0:
```

应用列表条数不固定，最后用文本消息收尾：

```text
catalog.list none 4 0:
catalog.app json 4 78:{"package":"com.android.settings","versionName":"14","versionCode":34,"size":12345678}
session.done text 4 2:ok
```

查看一个应用时，回复是约定好的两条：先是 JSON，再是图标。两条都到了就结束，不再另发 `session.done`。

```text
catalog.show json 5 39:{"package":"com.android.settings"}
catalog.show json 5 68:{"package":"com.android.settings","versionName":"14","label":"设置"}
catalog.icon bytes 5 4821:<4821 字节的 PNG>
```

手机上的复制没有对应请求，`id` 为 0：

```text
clipboard.event json 0 16:{"text":"hello"}
```

失败沿用请求的 `id`。`未知命令` 的 UTF-8 是 12 字节。收到它，这次请求也结束。

```text
session.error text 1 12:未知命令
```

## 一次连接

线上两条消息首尾相接。下面为了阅读才分成多行：

```text
session.ready text 0 1:1
clipboard.get none 1 0:
clipboard.data json 1 16:{"text":"hello"}
catalog.list none 4 0:
catalog.app json 4 78:{"package":"com.android.settings","versionName":"14","versionCode":34,"size":12345678}
session.done text 4 2:ok
clipboard.event json 0 16:{"text":"hello"}
session.quit none 9 0:
```

空闲约 20 秒且没有推送监听时，桌面端发送 `session.quit`。

## 现有功能对应的 name

| 方向 | name | 正文 | 请求何时结束 |
|---|---|---|---|
| 设备 → 桌面 | `session.ready` | `text`，内容是 `1` | 这一条 |
| 桌面 → 设备 | `session.quit` | 无 | 设备退出，无回复 |
| 任意回复失败 | `session.error` | `text`，错误说明 | 这一条 |
| 一批回复结束 | `session.done` | `text`，如 `ok` | 这一条 |
| 桌面 → 设备 | `catalog.list` | 无 | 等到 `session.done` |
| 设备 → 桌面 | `catalog.app` | `json`，一个应用 | 继续等 |
| 桌面 → 设备 | `catalog.show` | `json`，如 `{"package":"com.android.settings"}` | 等到 JSON 和图标都到齐 |
| 设备 → 桌面 | `catalog.show` | `json`，名称、版本、标记、目录 | 还要等图标 |
| 设备 → 桌面 | `catalog.icon` | `bytes`，PNG | 这一条 |
| 桌面 → 设备 | `clipboard.get` | 无 | 等到 `clipboard.data` |
| 设备 → 桌面 | `clipboard.data` | `json`，`{"text":"..."}` | 这一条 |
| 桌面 → 设备 | `clipboard.set` | `json`，`{"text":"..."}` | 等到 `clipboard.ok` |
| 设备 → 桌面 | `clipboard.ok` | 无 | 这一条 |
| 桌面 → 设备 | `clipboard.history` | 无 | 等到同名回复 |
| 设备 → 桌面 | `clipboard.history` | `json`，`{"items":["新的在前"]}` | 这一条 |
| 桌面 → 设备 | `clipboard.watch` | `json`，`{"on":true}` 或 `{"on":false}` | 等到 `clipboard.ok` |
| 设备 → 桌面 | `clipboard.event` | `json`，`{"text":"..."}`。`id` 为 `0` | 不是回复 |

`catalog.show` 的 JSON 里放名称、版本、标记和目录。PNG 单独一条 `catalog.icon`。

## 加一个功能

1. 定一个 `name`，形如 `功能.事件`。不要复用已经发出去的名字，名字里不要有空格和冒号。
2. 请求和回复使用同一个 `id`。主动推送的 `id` 写 `0`。
3. 只回一条，或条数和名字是固定的，收齐约定的回复即可。
4. 条数不固定时，最后发 `session.done`，类型 `text`。
5. 有正文就写真实的 `type` 和 `length`。没有正文时 `type` 写 `none`，`length` 写 `0`。结构化内容用 `json`，文件或图片用 `bytes`。
6. 桌面端把 `id` 为 `0` 的消息按 `name` 分发，不要放进正在等待的请求队列。
7. 两端一起改，并把 `service.version` 加一。

## 扩展

以后加功能，优先动 `name` 和 JSON 正文，不动头的四个位置。

| 要加的东西 | 怎么加 | 旧程序 |
|---|---|---|
| 新功能，如文件、通知 | 新的 `name` | 按 `length` 跳过不认识的消息 |
| 已有 JSON 多一个字段 | 正文里加键 | 忽略不认识的键 |
| 一批数量不固定的回复 | 最后发 `session.done` | 已有规则 |
| 头的顺序或分隔方式要改 | `session.ready` 的版本改为 `2`，两端换解析 | 看到不是自己能处理的版本就断开 |

头的顺序是 `name`、`type`、`id`、`length`。在中间插入字段会让旧程序把位置看错，所以这种改动才升版本。文件这类很长的内容分成多条、同一 `id`，最后发 `session.done`。
