# Linux 交叉编译工具链：借 Zig 自带的 clang 与各架构 glibc。
#
# 正常构建请直接用 ../tool/build_linux.py，它会传对下面这些参数
#（尤其是 -G Ninja —— VS 生成器会忽略这里指定的 zig，仍用 cl.exe）。
#
# 手写时的用法（bash）：
#   ZIG_TARGET=x86_64-linux-gnu.2.28 \
#     cmake -S . -B build/linux-x64 -G Ninja \
#     "-DCMAKE_TOOLCHAIN_FILE=cmake/zig-linux.cmake" -DCMAKE_BUILD_TYPE=Release
#   cmake --build build/linux-x64
#
# PowerShell：
#   $env:ZIG_TARGET = 'aarch64-linux-gnu.2.28'
#   cmake -S . -B build/linux-arm64 -G Ninja "-DCMAKE_TOOLCHAIN_FILE=cmake/zig-linux.cmake" -DCMAKE_BUILD_TYPE=Release
#   cmake --build build/linux-arm64
#
# 工具链参数必须加引号：不加时 .cmake 会被拆成独立参数，
# 报 Could not find toolchain file: "cmake/zig-linux"。
#
# glibc 版本后缀（.2.17 / .2.28 / .2.31 …）决定产物能跑在哪些发行版上。
# 这里只负责「用哪个编译器编出哪个架构」，源码列表与 vendor/ 拷贝仍由 CMakeLists.txt 管。

set(ZIG_TARGET "$ENV{ZIG_TARGET}")
if(NOT ZIG_TARGET)
  message(FATAL_ERROR "请先设置环境变量 ZIG_TARGET，例如 aarch64-linux-gnu.2.28")
endif()

# 从 target triple 取架构。CMakeLists.txt 用它判定 vendor/<os>/<arch> 子目录。
string(REGEX MATCH "^[^-]+" ZIG_ARCH "${ZIG_TARGET}")

set(CMAKE_SYSTEM_NAME Linux)

if(ZIG_ARCH MATCHES "^(x86_64|amd64)$")
  set(CMAKE_SYSTEM_PROCESSOR x86_64)
elseif(ZIG_ARCH MATCHES "^(aarch64|arm64)$")
  set(CMAKE_SYSTEM_PROCESSOR aarch64)
else()
  message(FATAL_ERROR
    "不支持的架构 '${ZIG_ARCH}'：CMakeLists.txt 目前只判定 x64 与 arm64。"
    "需要更多架构请先扩展那里的 CMAKE_SYSTEM_PROCESSOR 分支。")
endif()

find_program(CMAKE_C_COMPILER NAMES zig)
if(NOT CMAKE_C_COMPILER)
  message(FATAL_ERROR "未找到 zig。请先安装（winget install Zig.Zig）并确保它在 PATH 中。")
endif()

# `zig cc` 的 cc 必须是第一个参数，但 CMake 的规则是
# `<编译器> <DEFINES> <INCLUDES> <FLAGS>`，FLAGS 排在 -D 之后，
# 所以只能用 CMAKE_C_COMPILER_ARG1 —— 它紧跟在编译器之后，
# 于是编译命令变成 `zig cc -target <triple> -D… `。
# 若改用 CMAKE_C_FLAGS 会拼成 `zig -D… cc -target …`，zig 报 unknown command。
set(CMAKE_C_COMPILER_ARG1 "cc -target ${ZIG_TARGET}")

# 不指定构建类型时默认 Release。否则带调试信息的 .so 约 4 MB，
# Release 后约 25 KB —— 这是要随包分发的产物，别默认带符号。
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "构建类型" FORCE)
endif()
