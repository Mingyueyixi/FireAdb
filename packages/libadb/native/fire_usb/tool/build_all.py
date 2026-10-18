#!/usr/bin/env python3
"""一键编译 fire_usb 的所有平台与架构，产物统一落进 vendor/。

默认把当前机器能编的都编了：
  - Windows 上：windows x64 + arm64（MSVC）、linux x64 + arm64（Zig 交叉）
  - Linux / macOS 上：linux x64 + arm64（Zig 交叉）

产物路径与 hook/build.dart 取的对齐：
  packages/libadb/vendor/<os>/<arch>/{fire_usb.dll, libfire_usb.so}

用法：
    python tool/build_all.py                    # 能编的全编
    python tool/build_all.py --os linux         # 只编 Linux，可重复
    python tool/build_all.py --arch arm64       # 只编 arm64，可重复
    python tool/build_all.py --glibc 2.17       # Linux 的 glibc 基线
    python tool/build_all.py --cmake <cmake.exe>
    python tool/build_all.py --clean            # 全部清掉重建

一个平台失败不会打断其它平台：末尾统一列出失败原因并以退出码 1 结束。
macOS 产物（vendor/macos/*）要在 macOS 机器上编，见 README「本机构建」。
"""

import argparse
import sys

from _common import ARCHS, FILE_NAMES, VENDOR, find_cmake, rel, report, scan_vendor

import build_linux
import build_windows

MODULES = {"windows": build_windows, "linux": build_linux}

# 各平台当前机器能不能编：windows 要 MSVC，linux 靠 Zig 交叉，处处可用。
HOST_CAN = {"windows": sys.platform == "win32", "linux": True}


def pick_platforms(requested: list[str] | None) -> list[str]:
    if requested:
        for plat in requested:
            if not HOST_CAN[plat]:
                sys.exit(f"当前系统（{sys.platform}）编不了 {plat} 版 —— "
                         f"{plat} 版要在对应系统上编，见 README。")
        return requested
    picked = [p for p, ok in HOST_CAN.items() if ok]
    if not picked:
        sys.exit("当前系统没有可编的平台。")
    return picked


def error_text(code) -> str:
    if isinstance(code, str) and code:
        return code
    if code is None:
        return "未知错误"
    return f"退出码 {code}"


def main() -> None:
    ap = argparse.ArgumentParser(
        description="一键编译 fire_usb 的所有平台与架构")
    ap.add_argument("--os", action="append", dest="platforms",
                    choices=sorted(MODULES),
                    help="目标系统，可重复；默认编当前机器能编的全部")
    ap.add_argument("--arch", action="append", choices=sorted(ARCHS),
                    help="目标架构，可重复；默认 x64 + arm64")
    ap.add_argument("--glibc", default="2.28",
                    help="Linux 的 glibc 基线，默认 2.28")
    ap.add_argument("--cmake", default=None,
                    help="cmake 可执行文件路径（默认：环境变量 CMAKE > PATH > VS 自带）")
    ap.add_argument("--clean", action="store_true",
                    help="清掉各平台构建目录后重新配置")
    args = ap.parse_args()

    plats = pick_platforms(args.platforms)
    arches = args.arch or list(ARCHS)
    glibc = args.glibc.lstrip(".")
    cmake = find_cmake(args.cmake)

    print(f"平台 {' '.join(plats)} / 架构 {' '.join(arches)}"
          + (f" / glibc {glibc}" if "linux" in plats else ""), flush=True)

    results, errors = [], []
    for plat in plats:
        mod = MODULES[plat]
        try:
            mod.check_tools(cmake)
            if plat == "linux":
                results += mod.build_targets(arches, cmake, args.clean, glibc=glibc)
            else:
                results += mod.build_targets(arches, cmake, args.clean)
        except SystemExit as e:            # 单个平台失败，继续编剩下的
            errors.append((plat, error_text(e.code)))
        print(flush=True)

    report(results)

    print("\nvendor/ 现状：")
    scan_vendor()

    missing = []
    for plat in plats:
        for arch in arches:
            if not (VENDOR / plat / arch / FILE_NAMES[plat]).is_file():
                missing.append(f"{plat}/{arch}")
    if missing:
        print("\n还缺的产物：" + "、".join(missing))

    if errors:
        print("\n编译失败：")
        for plat, msg in errors:
            print(f"  [{plat}] " + msg.replace("\n", f"\n  {' ' * (len(plat) + 3)}"))
        sys.exit(1)
    if missing:
        sys.exit(1)
    print(f"\n全部完成：{len(results)} 个产物 -> {rel(VENDOR)}/")


if __name__ == "__main__":
    main()
