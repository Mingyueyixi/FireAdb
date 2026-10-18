#!/usr/bin/env python3
"""在 Windows 上编译 fire_usb.dll（x64 / arm64），并拷到 vendor/windows/<arch>/。

真正干活的是 CMake + MSVC（VS 的「使用 C++ 的桌面开发」工作负载），脚本只做：
固定易踩的参数、驱动构建、拷进 vendor/、校验 PE 架构与导出符号。

用法：
    python tool/build_windows.py                  # x64 + arm64
    python tool/build_windows.py --arch arm64     # 只编 arm64
    python tool/build_windows.py --cmake <cmake.exe>   # cmake 不在 PATH 时
    python tool/build_windows.py --clean          # 清掉构建目录重新配置

产物落在 `packages/libadb/vendor/windows/<arch>/fire_usb.dll`。
CMakeLists.txt 的 POST_BUILD 也拷，但它只挂在链接这一步 —— 增量构建报
「已是最新的」时链接不跑、也就一并不拷，所以这里构建后自己拷一遍。
"""

import argparse
import shutil
import sys
from pathlib import Path

from _common import ARCHS, BUILD, SRC, Result, deploy, find_cmake, rel, report, run

# 架构 -> `cmake -A` 的值。构建目录沿用 README 里手写命令的命名（build/x64、build/arm64）。
GEN_PLATFORM = {"x64": "x64", "arm64": "ARM64"}

# PE 头里的 Machine 字段
MACHINES = {0x8664: "x86_64", 0xAA64: "arm64", 0x14C: "x86", 0x1C0: "arm"}
WANT_MACHINE = {"x64": 0x8664, "arm64": 0xAA64}


# --------------------------------------------------------------------------- #
# PE 校验：不装 dumpbin / 不依赖 VS 环境，直接解析 PE 头与导出表。
# --------------------------------------------------------------------------- #

def _u16(b: bytes, o: int) -> int:
    return int.from_bytes(b[o:o + 2], "little")


def _u32(b: bytes, o: int) -> int:
    return int.from_bytes(b[o:o + 4], "little")


def _cstr(b: bytes, o: int) -> str:
    end = b.index(b"\0", o)
    return b[o:end].decode("utf-8", "replace")


def inspect_pe(path: Path) -> dict:
    """读 PE 头 + 导出表，返回架构与导出的 fire_usb_* 符号。"""
    data = path.read_bytes()
    if data[:2] != b"MZ":
        raise ValueError("不是 PE 文件")
    pe = _u32(data, 0x3C)
    if data[pe:pe + 4] != b"PE\0\0":
        raise ValueError("PE 签名不对")

    machine = _u16(data, pe + 4)
    opt_size = _u16(data, pe + 20)
    opt = pe + 24
    magic = _u16(data, opt)
    if magic not in (0x10B, 0x20B):        # PE32 / PE32+
        raise ValueError(f"未知 Optional Header magic：0x{magic:x}")

    # 数据目录：PE32+ 从 Optional Header +112 开始，PE32 从 +96 开始。
    # 第 0 项就是导出表（RVA + 大小）。
    dd = opt + (112 if magic == 0x20B else 96)
    exp_rva = _u32(data, dd)

    # 段表紧跟 Optional Header，每段 40 字节。
    nsec = _u16(data, pe + 6)
    sec = opt + opt_size
    segs = []
    for i in range(nsec):
        o = sec + i * 40
        segs.append((_u32(data, o + 12), _u32(data, o + 8), _u32(data, o + 20)))

    def rva2off(rva: int) -> int:
        for vaddr, vsize, rawptr in segs:      # vaddr, VirtualSize, PointerToRawData
            if vaddr <= rva < vaddr + max(vsize, 4096):
                return rawptr + (rva - vaddr)
        raise ValueError(f"RVA 0x{rva:x} 不在任何段里")

    exported = []
    if exp_rva:
        eo = rva2off(exp_rva)
        count = _u32(data, eo + 24)            # NumberOfNames
        names = rva2off(_u32(data, eo + 32))   # AddressOfNames
        for i in range(count):
            name = _cstr(data, rva2off(_u32(data, names + i * 4)))
            if name.startswith("fire_usb_"):
                exported.append(name)

    return {
        "machine": machine,
        "machine_name": MACHINES.get(machine, f"unknown(0x{machine:x})"),
        "bitness": "PE32+" if magic == 0x20B else "PE32",
        "exported": sorted(set(exported)),
    }


# --------------------------------------------------------------------------- #
# 构建
# --------------------------------------------------------------------------- #

def check_tools(cmake: str) -> None:
    """build_all.py 会在开编前调这里。MSVC 装没装由 cmake 自己判，报错更准。"""


def _hint(arch: str) -> str:
    lines = ["需要 VS 的「使用 C++ 的桌面开发」工作负载"
             "（VS 安装器 → 修改 → 勾选），cmake 才能生成工程。"]
    if arch == "arm64":
        lines.append("ARM64 还需 MSVC ARM64 工具集"
                     "（VS 安装器 → 单个组件 → MSVC v143 - ARM64 生成工具）。")
    lines.append("构建目录换过生成器 / 架构时加 --clean 重建；"
                 "另请确认没设 CMAKE_GENERATOR（-A 只对 VS 生成器有效）。")
    return "\n".join(lines)


def build_one(arch: str, cmake: str, clean: bool) -> tuple[Path, dict]:
    build_dir = BUILD / arch

    if clean and build_dir.exists():
        shutil.rmtree(build_dir)

    run([cmake, "-S", SRC, "-B", build_dir, "-A", GEN_PLATFORM[arch]],
        hint=_hint(arch))
    run([cmake, "--build", build_dir, "--config", "Release"])

    out = deploy(build_dir / "Release" / "fire_usb.dll", "windows", arch)
    info = inspect_pe(out)
    if info["machine"] != WANT_MACHINE[arch]:
        sys.exit(f"架构不对：期望 {arch}（0x{WANT_MACHINE[arch]:x}），"
                 f"实际 {info['machine_name']} —— 检查构建目录是不是配错了 -A")
    if not info["exported"]:
        sys.exit(f"没在 {rel(out)} 里找到导出的 fire_usb_* 符号")
    return out, info


def build_targets(arches: list[str], cmake: str, clean: bool) -> list[Result]:
    rows = []
    for arch in arches:
        out, info = build_one(arch, cmake, clean)
        detail = (f"{info['machine_name']} · {info['bitness']} · "
                  f"导出 {len(info['exported'])} 个符号："
                  f"{', '.join(info['exported'])}")
        rows.append(Result("windows", arch, out, detail))
    return rows


def main() -> None:
    ap = argparse.ArgumentParser(description="编译 Windows 版 fire_usb.dll")
    ap.add_argument("--arch", action="append", choices=sorted(ARCHS),
                    help="目标架构，可重复；默认 x64 + arm64")
    ap.add_argument("--cmake", default=None,
                    help="cmake 可执行文件路径（默认：环境变量 CMAKE > PATH > VS 自带）")
    ap.add_argument("--clean", action="store_true", help="清掉构建目录后重新配置")
    args = ap.parse_args()

    arches = args.arch or list(ARCHS)
    cmake = find_cmake(args.cmake)

    print(f"架构 {' '.join(arches)}", flush=True)
    report(build_targets(arches, cmake, args.clean))


if __name__ == "__main__":
    main()
