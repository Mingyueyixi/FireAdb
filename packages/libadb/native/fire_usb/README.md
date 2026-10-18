# fire_usb

进程内持有 libusb 句柄的一小层 C。热重启后 Dart 静态变量会丢，C 表还在，
新的 `open` / `close` 能把旧句柄 `release_interface` + `close` 掉。

编译时不链接 libusb（运行时再 `LoadLibrary` / `dlopen`）。

## 构建

两行命令，作用不同，一般**都要跑**（先配置，再编译）：

```bash
cmake -S . -B build/arm64 -A ARM64
cmake --build build/arm64 --config Release
```

| 命令 | 做什么 | 什么时候跑 |
|---|---|---|
| `cmake -S . -B build/arm64 -A ARM64` | **配置**：生成 `build/arm64/` 里的工程（找编译器、写缓存）。还不编 dll。 | 第一次，或改了 `CMakeLists.txt` / 换架构之后 |
| `cmake --build build/arm64 --config Release` | **编译**：真正调用 MSBuild/编译器，产出 dll，并拷到 `vendor/` | 每次改了 `fire_usb.c` / `.h` 之后 |

只改源码、没动 CMake 时，第二行就够。目录还不存在或换了 `-A` 时，必须先跑第一行。

架构子目录都在 `build/` 下，一个 `-A` 对应一个目录：

```bash
# Windows x64
cmake -S . -B build/x64 -A x64
cmake --build build/x64 --config Release

# Windows ARM64（需已装 MSVC ARM64 工具）
cmake -S . -B build/arm64 -A ARM64
cmake --build build/arm64 --config Release

# Linux / macOS（本机架构）
cmake -S . -B build/native -DCMAKE_BUILD_TYPE=Release
cmake --build build/native
```

不用为每个操作系统再开目录：在哪台机器上编，就只出哪个 OS 的库。
多平台产物靠各平台编完后进 `vendor/` 汇总（`POST_BUILD` 自动拷贝）：

- `vendor/windows/x64/fire_usb.dll`
- `vendor/windows/arm64/fire_usb.dll`
- `vendor/linux/...`、`vendor/macos/...`

`cmake` 不在 PATH 时，可用 VS 自带的，例如：

```text
"C:\Program Files\Microsoft Visual Studio\18\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
```
