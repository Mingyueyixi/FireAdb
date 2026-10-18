# fire_usb

进程内持有 libusb 句柄的一小层 C。热重启后 Dart 静态变量会丢，C 表还在，
新的 `open` / `close` 能把旧句柄 `release_interface` + `close` 掉。

编译时不链接 libusb（运行时再 `LoadLibrary` / `dlopen`）。

## 构建

源码列表、导出符号由 `CMakeLists.txt` 管 —— **新增 `.c` 只改那里一处**，
下面的命令都不用跟着改；`vendor/` 拷贝它也做了（`POST_BUILD`），脚本构建后还会再拷一遍并校验。

### 需要的工具

| 工具 | 用途 | 什么时候需要 | 安装 |
|---|---|---|---|
| CMake ≥ 3.16 | 生成工程 | **总是** | `winget install Kitware.CMake`；或用 VS 自带的（见下） |
| 平台 C 编译器 | 真正编译 | **总是**（本机构建） | Windows：MSVC（VS 勾「使用 C++ 的桌面开发」）；Linux/macOS：系统 clang/gcc |
| Zig | 交叉用的 C 编译器 + 各架构 glibc | 仅 **Linux 交叉编译** | `scoop install zig` / `winget install Zig.Zig` |
| Ninja | CMake 的生成器 | 仅 **Linux 交叉编译** | `winget install Ninja-build.Ninja` |
| Python ≥ 3.8 | 跑 `tool/build_*.py`（全平台 / Linux 交叉 / Windows） | 可选，但**推荐** | `scoop install python` |

只做 Windows 本机构建的话，装了 VS 就什么都不用再装。

### 环境

- **`cmake` 不在 PATH**（本机装了多个版本时常这样）：脚本按 `--cmake` > 环境变量 `CMAKE`
  > `PATH` > VS 自带路径的顺序找，一般什么都不用设。VS 自带的 cmake 在：
  ```text
  C:\Program Files\Microsoft Visual Studio\18\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe
  ```
- `zig` / `ninja` 需要在 PATH 里（**只** Linux 交叉编译要）。脚本启动时会先检查，缺哪个直接给安装提示。
- 本机构建的命令在 `native/fire_usb/` 下执行；`tool/` 下的脚本在任意目录都能跑
  （它按自身位置定位源码与 `vendor/`）。

### 本机构建（出当前机器的架构）

**推荐：一条命令**，x64 + arm64 一起编，编完自动拷进 `vendor/windows/<arch>/` 并校验
PE 架构与导出符号（不用 Zig / Ninja，只要 VS 的 C++ 工作负载）：

```bash
python tool/build_windows.py                  # x64 + arm64
python tool/build_windows.py --arch arm64     # 只编 arm64
python tool/build_windows.py --clean          # 换生成器 / 架构后重建
```

| 参数 | 说明 |
|---|---|
| `--arch x64` / `--arch arm64` | 只编指定架构，可重复传 |
| `--cmake <路径>` | cmake 不在 PATH 时用（或设环境变量 `CMAKE`，不设也常能找到 VS 自带的） |
| `--clean` | 清掉 `build/x64`、`build/arm64` 后重新配置 |

不跑脚本、手写 cmake 也行 —— 两行命令，作用不同，一般**都要跑**（先配置，再编译）：

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
cmake -S . -B build/native
cmake --build build/native --config Release
```

不用为每个操作系统再开目录：在哪台机器上编，就只出哪个 OS 的库。
多平台产物靠各平台编完后进 `vendor/` 汇总（脚本和 `POST_BUILD` 都会拷贝）：

- `vendor/windows/x64/fire_usb.dll`
- `vendor/windows/arm64/fire_usb.dll`
- `vendor/linux/x64/libfire_usb.so`、`vendor/linux/arm64/libfire_usb.so`

### 一键编译所有平台与架构

```bash
python tool/build_all.py
```

Windows 上默认一次出全 4 个产物（windows × x64/arm64 + linux × x64/arm64），
其它系统上编 linux 的两个（windows 版要 MSVC，只能在 Windows 上编）：

| 参数 | 说明 |
|---|---|
| `--os windows` / `--os linux` | 只编指定系统，可重复；默认编当前机器能编的全部 |
| `--arch x64` / `--arch arm64` | 只编指定架构，可重复；默认两个都编 |
| `--glibc 2.17` | 传给 Linux 交叉编译的 glibc 基线，默认 `2.28` |
| `--cmake <路径>` / `--clean` | 同 `build_linux.py` / `build_windows.py` |

它只是把两个子脚本串起来跑：单个平台失败不会打断其它平台，末尾逐条列出失败原因、
再列一遍 `vendor/` 现状（含缺的产物），有失败就以退出码 1 结束。
macOS 版（`vendor/macos/`）要在 macOS 机器上本机构建，见上面的手写命令。

## Linux 交叉编译（Zig）

`cmake -S . -B build/native` 只能出**当前机器**的架构。在 Windows / macOS 上要出 Linux 的
`.so`，换用 Zig 自带的 clang 与各架构 glibc 即可，不需要 WSL、Docker 或自建 sysroot。
借的是它的 **C 编译器**，`fire_usb.c` 不用改，产物是普通 ELF、不含 Zig 运行时。

编译**仍然走 CMake** —— 源码列表、导出符号、`vendor/` 拷贝都由 `CMakeLists.txt` 统一管，
脚本只是驱动它、再把产物拷进 `vendor/` 并校验一遍。

### 一条命令（推荐）

```bash
python tool/build_linux.py
```

默认编 x64 + arm64、glibc 基线 2.28，产物拷到 `vendor/linux/<arch>/`，
并顺带校验架构与依赖：

```text
[linux/x64] packages/libadb/vendor/linux/x64/libfire_usb.so
              26.6 KB · x86_64 · NEEDED libc.so.6, libdl.so.2 · 导出 5 个符号：fire_usb_close, fire_usb_close_all, fire_usb_is_open, fire_usb_open, fire_usb_transfer_cb
[linux/arm64] packages/libadb/vendor/linux/arm64/libfire_usb.so
              24.1 KB · aarch64 · NEEDED libc.so.6, libdl.so.2 · 导出 5 个符号：（同上）
```

| 参数 | 说明 |
|---|---|
| `--arch x64` / `--arch arm64` | 只编指定架构，可重复传 |
| `--glibc 2.17` | glibc 基线，默认 `2.28`（Debian 10 / Ubuntu 18.04）；要覆盖 CentOS 7 用 `2.17` |
| `--cmake <路径>` | cmake 不在 PATH 时用（或设环境变量 `CMAKE`） |
| `--clean` | 清掉 `build/` 后重新配置 |

`.2.28` 钉的是产物要求的 glibc 最低版本，桌面发行版普遍 2.31+；
`fire_usb.c` 只用 `stdio/stdlib/string/dlfcn`，降到 `.2.17` 也够。

### 脚本背后做的事

不跑脚本、手写命令也行，但有四个坑，脚本已全部处理：

```bash
ZIG_TARGET=x86_64-linux-gnu.2.28 \
  cmake -S . -B build/linux-x64 -G Ninja "-DCMAKE_TOOLCHAIN_FILE=cmake/zig-linux.cmake" \
  -DCMAKE_BUILD_TYPE=Release
cmake --build build/linux-x64
```

PowerShell 里先 `$env:ZIG_TARGET = 'x86_64-linux-gnu.2.28'`，再跑那两行 cmake。

- **必须 `-G Ninja`**。默认的 VS 生成器会忽略工具链里指定的 zig、仍用 `cl.exe`，
  接着报 `cl : warning D9002: 忽略未知选项 "-target"`。
- **工具链参数要加引号**。不加引号时 `.cmake` 会被拆成独立参数，
  报 `Could not find toolchain file: "cmake/zig-linux"`。
- **要设 `CMAKE_BUILD_TYPE=Release`**。不设的话 `.so` 带调试信息约 4 MB，Release 后约 25 KB。
- **构建完要拷进 `vendor/`，别只信 `POST_BUILD`**。`CMakeLists.txt` 里的拷贝挂在链接这一步上，
  增量构建时 `ninja: no work to do`（Windows 是「已是最新的」）—— 链接一步根本不跑，
  `vendor/` 就一直缺产物。所以脚本构建后无条件再拷一遍并校验大小；
  手写命令编完也确认下 `vendor/linux/<arch>/` 里有没有文件。

工具链文件 `cmake/zig-linux.cmake` 从环境变量 `ZIG_TARGET` 读 target（格式
`<架构>-linux-gnu.<glibc>`），负责设置 `CMAKE_SYSTEM_PROCESSOR` 供 `CMakeLists.txt` 判定
`x64` / `arm64`，并把编译器换成 `zig cc -target <triple>`。

架构只支持 `x86_64` / `aarch64`，其它值在那里直接报错；要扩架构需先改 `CMakeLists.txt`
里 `CMAKE_SYSTEM_PROCESSOR` 的 `FATAL_ERROR` 分支（那里同样只判定 `x64` / `arm64`）。

### 产物校验

Windows 上没有 `readelf`。`tool/build_linux.py` 内置了 ELF 解析，会自动报出
架构（`e_machine`）、`DT_NEEDED`、导出的 `fire_usb_*` 符号，不用手工查；
`tool/build_windows.py` 同样内置 PE 解析（Machine 字段 + 导出表）。
**架构对不上、或一个 `fire_usb_*` 符号都没导出，脚本直接失败**——
`vendor/<os>/<arch>/` 里放错架构的库（比如 x64 目录里躺着 ARM64 的 dll）
就是这样被拦下来重编的。

拷到真机后可再确认一次：

```bash
file libfire_usb.so                        # ELF ... ARM aarch64 / x86-64
readelf -d libfire_usb.so | grep NEEDED    # 应为 libc.so.6（+libdl.so.2）
```

### 运行时依赖

`fire_usb.c` 在运行时 `dlopen("libusb-1.0.so.0")`，目标机需装 `libusb-1.0-0`（Debian/Ubuntu）
或 `libusbx`（RHEL）。

`vendor/` 里没有对应 `.so` 时 `FireUsb.tryLoad()` 返回 null，Dart 侧退化到不带
`fire_usb` 的路径，功能仍可用。

### 其他交叉方案

| 方案 | 做法 | 代价 |
|---|---|---|
| 发行版交叉编译器 | WSL2 里 `apt install gcc-aarch64-linux-gnu` | glibc 版本 = 发行版版本；要兼容老系统得用老镜像 |
| Docker + QEMU | `docker run --platform linux/arm64` / `buildx` | 环境最忠实，但要 Docker |
| musl | `-target aarch64-linux-musl` | **不适合本库**：`.so` 被 glibc 进程 dlopen，会混进两套 malloc / errno |
| Android NDK | — | **不可行**：sysroot 是 Bionic，产出的 `.so` 记 `libc.so` + `LIBC` 版本标签，glibc 进程加载不了 |
