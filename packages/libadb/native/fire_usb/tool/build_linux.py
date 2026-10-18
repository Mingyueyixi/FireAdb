#!/usr/bin/env python3
"""在 Windows / macOS 上交叉编译 Linux 版 libfire_usb.so。

真正干活的仍然是 CMake + Zig，这个脚本只做三件事：
固定易踩的参数、驱动构建、拷进 vendor/ 并校验产物。

固定下来的参数（都是踩过的坑）：
  - `-G Ninja`：默认的 VS 生成器会忽略工具链里指定的 zig，仍用 cl.exe，
    然后报 `cl : warning D9002: 忽略未知选项 "-target"`。
  - 工具链文件用绝对路径：相对路径在部分 shell 下 `.cmake` 会被拆成独立参数，
    报 `Could not find toolchain file: "cmake/zig-linux"`。
  - `CMAKE_BUILD_TYPE=Release`：不指定时 `.so` 带调试信息约 4 MB，Release 后约 25 KB。

用法：
    python tool/build_linux.py                      # x64 + arm64（glibc 2.28）
    python tool/build_linux.py --arch arm64         # 只编 arm64
    python tool/build_linux.py --glibc 2.17         # 降低 glibc 基线，兼容 CentOS 7
    python tool/build_linux.py --cmake <cmake.exe>  # cmake 不在 PATH 时
    python tool/build_linux.py --clean              # 清掉 build/ 重新配置

产物落在 `packages/libadb/vendor/linux/<arch>/libfire_usb.so`。
CMakeLists.txt 的 POST_BUILD 也拷，但它只挂在链接这一步 —— 增量构建
（`ninja: no work to do`）时链接不跑、也就一并拷，所以这里构建后自己拷一遍。
"""

import argparse
import os
import shutil
import sys
from pathlib import Path

from _common import SRC, Result, deploy, find_cmake, report, require, run

TOOLCHAIN = SRC / "cmake" / "zig-linux.cmake"

# 架构目录名 -> (zig target 的架构部分, ELF e_machine)
ARCHS = {
    "x64": ("x86_64", 62),
    "arm64": ("aarch64", 183),
}

MACHINE_NAMES = {62: "x86_64", 183: "aarch64", 40: "arm", 243: "riscv"}


# --------------------------------------------------------------------------- #
# ELF 校验：Windows 上没有 readelf，这里直接解析 ELF 头与动态段。
# --------------------------------------------------------------------------- #

def _u16(b: bytes, o: int) -> int:
    return int.from_bytes(b[o:o + 2], "little")


def _u32(b: bytes, o: int) -> int:
    return int.from_bytes(b[o:o + 4], "little")


def _u64(b: bytes, o: int) -> int:
    return int.from_bytes(b[o:o + 8], "little")


def _cstr(b: bytes, o: int) -> str:
    end = b.index(b"\0", o)
    return b[o:end].decode("utf-8", "replace")


def inspect_elf(path: Path) -> dict:
    """读 ELF 头 + .dynamic + .dynsym，返回架构/依赖/导出符号。"""
    data = path.read_bytes()
    if data[:4] != b"\x7fELF":
        raise ValueError("不是 ELF 文件")
    if data[4] != 2:
        raise ValueError(f"只支持 64 位 ELF（EI_CLASS={data[4]}）")

    machine = _u16(data, 18)

    # 64 位 ELF 头布局：e_shoff @0x28, e_shentsize @0x3a, e_shnum @0x3c, e_shstrndx @0x3e
    shoff, shentsize = _u64(data, 0x28), _u16(data, 0x3a)
    shnum, shstrndx = _u16(data, 0x3c), _u16(data, 0x3e)

    sections = []
    for i in range(shnum):
        o = shoff + i * shentsize
        sections.append({
            "name": _u32(data, o),
            "offset": _u64(data, o + 0x18),
            "size": _u64(data, o + 0x20),
            "link": _u32(data, o + 0x28),
            "entsize": _u64(data, o + 0x38),
        })

    shstr = sections[shstrndx]["offset"]
    by_name = {}
    for s in sections:
        by_name[_cstr(data, shstr + s["name"])] = s

    def blob(name: str) -> bytes:
        s = by_name.get(name)
        if s is None:
            return b""
        return data[s["offset"]:s["offset"] + s["size"]]

    # .dynamic：每项 16 字节（d_tag, d_val）。DT_NEEDED=1, DT_STRTAB=5, DT_SYMTAB=6
    dynstr = blob(".dynstr")
    needed = []
    dyn = blob(".dynamic")
    for i in range(0, len(dyn) - 15, 16):
        tag, val = _u64(dyn, i), _u64(dyn, i + 8)
        if tag == 1:  # DT_NEEDED
            needed.append(_cstr(dynstr, val))

    # .dynsym：每项 24 字节。st_name@0, st_info@4, st_other@5, st_shndx@6
    exported = []
    symtab, symstr = blob(".dynsym"), dynstr
    for i in range(0, len(symtab) - 23, 24):
        st_other, st_shndx = symtab[i + 5], _u16(symtab, i + 6)
        if st_shndx == 0 or (st_other & 0x3) != 0:  # 未定义 / 非 default 可见性
            continue
        name = _cstr(symstr, _u32(symtab, i))
        if name.startswith("fire_usb_"):
            exported.append(name)

    return {
        "machine": machine,
        "machine_name": MACHINE_NAMES.get(machine, f"unknown({machine})"),
        "needed": needed,
        "exported": sorted(set(exported)),
    }


# --------------------------------------------------------------------------- #
# 构建
# --------------------------------------------------------------------------- #

def check_tools(cmake: str) -> None:
    """build_all.py 会在开编前调这里，缺工具直接给安装提示。"""
    require("zig", "安装：scoop install zig（或 winget install Zig.Zig）")
    require("ninja", "安装：winget install Ninja-build.Ninja")


def build_one(arch: str, glibc: str, cmake: str, clean: bool) -> tuple[Path, dict]:
    zig_arch, machine = ARCHS[arch]
    triple = f"{zig_arch}-linux-gnu.{glibc}"
    build_dir = SRC / "build" / f"linux-{arch}"

    if clean and build_dir.exists():
        shutil.rmtree(build_dir)

    env = os.environ.copy()
    env["ZIG_TARGET"] = triple        # cmake/zig-linux.cmake 从这里读 target

    # 注意：参数用列表传递，不经过 shell —— 工具链路径不会被引号问题拆坏。
    run([cmake, "-S", SRC, "-B", build_dir, "-G", "Ninja",
         f"-DCMAKE_TOOLCHAIN_FILE={TOOLCHAIN}", "-DCMAKE_BUILD_TYPE=Release"],
        env=env)
    run([cmake, "--build", build_dir])

    out = deploy(build_dir / "libfire_usb.so", "linux", arch)
    info = inspect_elf(out)
    if info["machine"] != machine:
        sys.exit(f"架构不对：期望 e_machine={machine}，实际 {info['machine']}")
    return out, info


def build_targets(arches: list[str], cmake: str, clean: bool,
                  glibc: str = "2.28") -> list[Result]:
    rows = []
    for arch in arches:
        out, info = build_one(arch, glibc, cmake, clean)
        detail = (f"{info['machine_name']} · "
                  f"NEEDED {', '.join(info['needed']) or '(无)'} · "
                  f"导出 {len(info['exported'])} 个符号："
                  f"{', '.join(info['exported'])}")
        rows.append(Result("linux", arch, out, detail))
    return rows


def main() -> None:
    ap = argparse.ArgumentParser(description="交叉编译 Linux 版 libfire_usb.so")
    ap.add_argument("--arch", action="append", choices=sorted(ARCHS),
                    help="目标架构，可重复；默认 x64 + arm64")
    ap.add_argument("--glibc", default="2.28",
                    help="glibc 基线版本，默认 2.28（Debian 10 / Ubuntu 18.04）")
    ap.add_argument("--cmake", default=None,
                    help="cmake 可执行文件路径（默认：环境变量 CMAKE > PATH > VS 自带）")
    ap.add_argument("--clean", action="store_true", help="清掉 build/ 后重新配置")
    args = ap.parse_args()

    arches = args.arch or ["x64", "arm64"]
    glibc = args.glibc.lstrip(".")
    cmake = find_cmake(args.cmake)

    check_tools(cmake)
    print(f"glibc 基线 {glibc} / 架构 {' '.join(arches)}", flush=True)
    report(build_targets(arches, cmake, args.clean, glibc))

    print("\n目标机需装 libusb-1.0.so.0（Debian/Ubuntu：apt install libusb-1.0-0）。")


if __name__ == "__main__":
    main()
