#!/usr/bin/env python3
"""统一打包入口：编译 + 注入构建信息 + 产出带版本号的安装包。

APK 命名 fireadb-android-<版本>-<架构>-<commit>.apk，就地留在
app/build/app/outputs/flutter-apk/，与上传到 GitHub 的文件名相同。
提交号拿不到时记为 unknown。构建时间以 Unix 秒注入，显示时由应用格式化为本地时间。

用法（多余参数透传给 flutter build / flutter run）：

    python scripts/build_app.py run -d windows            # 本地调试，热重载
    python scripts/build_app.py run -d <设备id>            # 指定设备调试
    python scripts/build_app.py windows --release         # 出包
    python scripts/build_app.py linux --release
    python scripts/build_app.py apk --release

GitHub Actions 下自动把产物路径写入 $GITHUB_OUTPUT（artifact / artifact_name）。
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import re
import shutil
import subprocess
import sys
import tarfile
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
APP_DIR = REPO_ROOT / "app"
DIST_DIR = REPO_ROOT / "build" / "dist"


def git_commit() -> str:
    """取短提交号；拿不到（无 git/深构建）时给 unknown，不阻断打包。"""
    result = subprocess.run(
        ["git", "rev-parse", "--short", "HEAD"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(
            f"读取 git 提交失败，构建信息记为 unknown：{result.stderr.strip()}",
            file=sys.stderr,
        )
        return "unknown"
    return result.stdout.strip() or "unknown"


def app_version() -> str:
    """pubspec.yaml 的版本号，去掉 +构建号 后缀。"""
    text = (APP_DIR / "pubspec.yaml").read_text(encoding="utf-8")
    match = re.search(r"^version:\s*(\S+)", text, re.MULTILINE)
    if match is None:
        sys.exit("app/pubspec.yaml 里找不到 version")
    return match.group(1).split("+")[0]


def flutter_command() -> list[str]:
    found = shutil.which("flutter")
    if found is None:
        sys.exit("PATH 里找不到 flutter，请先安装 Flutter SDK")
    # Windows 的 flutter.bat 必须经 cmd 启动。
    if found.lower().endswith((".bat", ".cmd")):
        return ["cmd", "/c", found]
    return [found]


def apk_build_args(rest: list[str]) -> list[str]:
    """一次编译拆成 arm64-v8a 和 x86_64 两个 APK。已指定平台时不再追加。"""
    args = list(rest)
    specified = any(
        arg == "--target-platform" or arg.startswith("--target-platform=")
        for arg in args
    )
    if not specified:
        args += [
            "--target-platform",
            "android-arm64",
            "--target-platform",
            "android-x64",
        ]
    if "--split-per-abi" not in args:
        args.append("--split-per-abi")
    return args


def run_flutter(subcommand: str, commit: str, build_time: str, rest: list[str]) -> None:
    """带构建信息执行 flutter run / flutter build；stdin 原样继承，
    flutter run 的热重载按键（r/R/q）可直接使用。"""
    # 子命令后必须紧跟目标（linux/apk），define 只能放目标之后，否则 flutter 解析报
    # "Could not find an option named --dart-define"。
    command = [
        *flutter_command(),
        subcommand,
        *rest,
        f"--dart-define=FIREADB_GIT_COMMIT={commit}",
        f"--dart-define=FIREADB_BUILD_TIME={build_time}",
    ]
    print("> " + " ".join(command))
    result = subprocess.run(command, cwd=APP_DIR)
    if result.returncode != 0:
        sys.exit(result.returncode)


def package(target: str, version: str, commit: str, rest: list[str]) -> Path:
    """把 flutter build 的产物压成带版本号的安装包，返回路径。

    APK 在 Flutter 的 flutter-apk 目录里就地改名，不再另拷一份。
    """
    mode = "release"
    for flag in ("--release", "--debug", "--profile"):
        if flag in rest:
            mode = flag[2:]
            break
    suffix = (
        f"{version}-{dt.datetime.now(dt.timezone.utc).strftime('%Y%m%d')}-{mode}"
    )
    DIST_DIR.mkdir(parents=True, exist_ok=True)
    if target == "windows":
        return _zip_dir(
            APP_DIR / "build/windows/x64/runner/Release",
            DIST_DIR / f"fireadb-windows-{suffix}.zip",
        )
    if target == "linux":
        return _tar_bundle(
            APP_DIR / "build/linux/x64/release/bundle",
            DIST_DIR / f"fireadb-linux-{suffix}.tar.gz",
        )
    if target == "apk":
        return _package_apks(version, commit, mode)
    sys.exit(f"目标 {target} 没有打包规则，请自行从 app/build/ 取产物")


def _package_apks(version: str, commit: str, mode: str) -> Path:
    """在 Flutter 的 flutter-apk 目录里就地改名，供同一次上传。"""
    out = APP_DIR / "build/app/outputs/flutter-apk"
    if not out.is_dir():
        sys.exit(f"找不到 APK 目录 {out}")
    # 清掉以前另拷到 dist 的 APK，避免和这次产物并存。
    stale_dir = DIST_DIR / "android"
    if stale_dir.exists():
        shutil.rmtree(stale_dir)
    for leftover in DIST_DIR.glob("fireadb-android-*.apk"):
        leftover.unlink()
    for old in out.glob("fireadb-android-*.apk"):
        old.unlink()
    mode_suffix = "" if mode == "release" else f"-{mode}"
    splits = sorted(out.glob(f"app-*-{mode}.apk"))
    if not splits:
        source = out / f"app-{mode}.apk"
        if not source.is_file():
            sys.exit(f"找不到 APK 产物 {source}")
        _rename_apk(source, out / f"fireadb-android-{version}-{commit}{mode_suffix}.apk")
        _drop_gradle_apk_copies(mode)
        return out
    for source in splits:
        abi = source.name.removeprefix("app-").removesuffix(f"-{mode}.apk")
        _rename_apk(
            source,
            out / f"fireadb-android-{version}-{abi}-{commit}{mode_suffix}.apk",
        )
    # 拆包后同目录里的整包是上一次没拆包留下的，和这次产物不是同一个文件。
    universal = out / f"app-{mode}.apk"
    if universal.is_file():
        universal.unlink()
        checksum = universal.with_name(universal.name + ".sha1")
        if checksum.is_file():
            checksum.unlink()
    _drop_gradle_apk_copies(mode)
    return out


def _drop_gradle_apk_copies(mode: str) -> None:
    """Flutter 已经把 APK 复制到 flutter-apk，Gradle 目录里的同内容文件删掉。"""
    gradle_out = APP_DIR / "build/app/outputs/apk" / mode
    if not gradle_out.is_dir():
        return
    for apk in gradle_out.glob("*.apk"):
        apk.unlink()


def _rename_apk(source: Path, dest: Path) -> None:
    source.replace(dest)
    checksum = source.with_name(source.name + ".sha1")
    if checksum.is_file():
        checksum.unlink()


def _zip_dir(source: Path, dest: Path) -> Path:
    if not source.is_dir():
        sys.exit(f"找不到构建产物目录 {source}")
    with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as archive:
        for file in sorted(source.rglob("*")):
            if file.is_file():
                archive.write(file, file.relative_to(source))
    return dest


def _tar_bundle(source: Path, dest: Path) -> Path:
    if not source.is_dir():
        sys.exit(f"找不到构建产物目录 {source}")
    # 解包后是 bundle/ 目录，与之前 CI 里 tar -C ... bundle 的结构一致。
    with tarfile.open(dest, "w:gz") as archive:
        archive.add(source, arcname="bundle")
    return dest


def emit_github_output(artifact: Path) -> None:
    """在 GitHub Actions 里把产物路径暴露给后续步骤。"""
    output = os.environ.get("GITHUB_OUTPUT")
    if not output:
        return
    with open(output, "a", encoding="utf-8") as file:
        file.write(f"artifact={artifact}\n")
        file.write(f"artifact_name={artifact.name}\n")


def main() -> None:
    # Windows CI 的 stdout 是 cp1252，打印中文会炸；强制 UTF-8。
    sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="带构建信息编译并打包 FireAdb")
    parser.add_argument(
        "target",
        nargs="?",
        default="windows",
        help="windows / linux / apk 走 flutter build；run 走 flutter run "
        "（本地调试，热重载可用，默认 windows）",
    )
    parser.add_argument(
        "--print-info",
        action="store_true",
        help="只打印构建信息，不编译",
    )
    args, rest = parser.parse_known_args()

    commit = git_commit()
    # 传 Unix 时间戳（秒），显示时由应用格式化为本地时间。
    build_time = str(int(dt.datetime.now(dt.timezone.utc).timestamp()))
    version = app_version()
    print(f"构建信息：version={version} commit={commit} time={build_time}（epoch 秒）")
    if args.print_info:
        return

    if args.target == "run":
        run_flutter("run", commit, build_time, rest)
        return
    build_args = rest
    if args.target == "apk":
        build_args = apk_build_args(rest)
    run_flutter("build", commit, build_time, [args.target, *build_args])
    artifact = package(args.target, version, commit, rest)
    named = sorted(artifact.glob("fireadb-android-*.apk")) if artifact.is_dir() else []
    if named:
        for item in named:
            print(f"产物：{item}")
    elif artifact.is_dir():
        for item in sorted(artifact.iterdir()):
            print(f"产物：{item}")
    else:
        print(f"产物：{artifact}")
    emit_github_output(artifact)


if __name__ == "__main__":
    main()
