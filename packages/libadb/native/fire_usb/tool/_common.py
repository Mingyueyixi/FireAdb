#!/usr/bin/env python3
"""build_linux / build_windows / build_all 共用的路径、工具查找与产物拷贝。

三个脚本都能在任意目录下运行 —— 全部按自身位置（`__file__`）定位源码与 vendor/。
"""

from __future__ import annotations

import glob
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

# Windows 控制台默认是 GBK，中文提示会乱码；统一按 UTF-8 输出。
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

SRC = Path(__file__).resolve().parent.parent          # native/fire_usb
PKG = SRC.parent.parent                               # packages/libadb
REPO = PKG.parent.parent                              # 仓库根
BUILD = SRC / "build"
VENDOR = PKG / "vendor"

# 产物文件名，与 hook/build.dart 里 `vendor/$os/$arch/$fileName` 一一对应。
FILE_NAMES = {
    "windows": "fire_usb.dll",
    "linux": "libfire_usb.so",
    "macos": "libfire_usb.dylib",
}

ARCHS = ("x64", "arm64")


@dataclass
class Result:
    """一个已构建并拷进 vendor/ 的产物。"""

    plat: str
    arch: str
    path: Path
    detail: str                                    # 架构 / 依赖 / 导出符号

    @property
    def label(self) -> str:
        return f"{self.plat}/{self.arch}"


def rel(path: Path) -> str:
    """相对仓库根的 posix 路径，方便打印与复制粘贴。"""
    try:
        return path.relative_to(REPO).as_posix()
    except ValueError:
        return str(path)


def require(tool: str, hint: str) -> None:
    if shutil.which(tool) is None:
        sys.exit(f"缺少 {tool}。{hint}")


def _cmake_candidates() -> list[str]:
    out = []
    if sys.platform == "win32":
        for base in (r"C:\Program Files\Microsoft Visual Studio",
                     r"C:\Program Files (x86)\Microsoft Visual Studio"):
            pattern = os.path.join(
                base, "*", "*",
                "Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe",
            )
            # 逆序 = 新版本（18 > 17 > 16）优先。
            out.extend(sorted(glob.glob(pattern), reverse=True))
        out.append(r"C:\Program Files\CMake\bin\cmake.exe")
    else:
        out.append("/Applications/CMake.app/Contents/bin/cmake")
    return out


def find_cmake(explicit: str | None = None) -> str:
    """解析 cmake：--cmake > 环境变量 CMAKE > PATH > VS 自带 / 官方安装路径。

    VS 装了 C++ 工作负载时自带 cmake 但通常不在 PATH 里 —— 自动找一下，
    README 里「一条命令」才真的只有一条。
    """
    want = explicit or os.environ.get("CMAKE")
    if want:
        if shutil.which(want) or Path(want).is_file():
            return want
        sys.exit(f"找不到 cmake：{want}\n"
                 f"用 --cmake 指定路径，或设置环境变量 CMAKE。")
    found = shutil.which("cmake")
    if found:
        return found
    for cand in _cmake_candidates():
        if Path(cand).is_file():
            return cand
    sys.exit("找不到 cmake。安装：winget install Kitware.CMake，"
             "或用 --cmake <路径> 指定（VS 自带的也行）。")


def run(cmd: list, *, env: dict | None = None, hint: str | None = None) -> None:
    """跑一条命令；失败时把命令、退出码和补救提示一起报出来。"""
    try:
        subprocess.run([str(c) for c in cmd], env=env, check=True)
    except FileNotFoundError:
        sys.exit(f"找不到命令：{cmd[0]}")
    except subprocess.CalledProcessError as e:
        msg = f"命令失败（退出码 {e.returncode}）：{' '.join(str(c) for c in cmd)}"
        if hint:
            msg += f"\n{hint}"
        sys.exit(msg)


def deploy(built: Path, plat: str, arch: str) -> Path:
    """把构建目录里的产物拷进 `vendor/<plat>/<arch>/` 并校验。

    CMakeLists.txt 的 POST_BUILD 也会拷，但它只挂在链接这一步上：增量构建
    报 `ninja: no work to do`（或 MSVC「已是最新的」）时链接根本不会跑，
    于是 vendor/ 一直缺产物。这里不依赖它，构建后无条件拷一遍。
    """
    if not built.is_file():
        sys.exit(f"构建完成但没找到产物：{built}")
    dst = VENDOR / plat / arch / built.name
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(built, dst)
    if dst.stat().st_size != built.stat().st_size:
        sys.exit(f"拷贝校验失败（大小不一致）：{dst}")
    return dst


def report(results: list[Result]) -> None:
    if not results:
        return
    indent = max(len(r.label) for r in results) + 3
    for r in results:
        print(f"[{r.label}] {rel(r.path)}")
        print(f"{' ' * indent}{r.path.stat().st_size / 1024:.1f} KB · {r.detail}")


def scan_vendor() -> None:
    """列一遍 vendor/ 里已有的产物，缺文件名的目录也会指出来。"""
    if not VENDOR.is_dir():
        print("vendor/ 还不存在（一个平台都没编过）。")
        return
    found = False
    for plat_dir in sorted(p for p in VENDOR.iterdir() if p.is_dir()):
        name = FILE_NAMES.get(plat_dir.name, "?")
        for arch_dir in sorted(p for p in plat_dir.iterdir() if p.is_dir()):
            art = arch_dir / name
            found = True
            if art.is_file():
                print(f"  {rel(art)}  {art.stat().st_size / 1024:.1f} KB")
            else:
                print(f"  {rel(arch_dir)}/  （缺 {name}）")
    if not found:
        print("vendor/ 是空的（一个平台都没编过）。")
