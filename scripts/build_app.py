#!/usr/bin/env python3
"""统一打包入口：编译 + 注入构建信息 + 产出带版本号的安装包。

产物命名 fireadb-<平台>-<版本>-<日期>-<构建类型>.<后缀>，输出到
build/dist/，例如 fireadb-android-1.0.1-20261108-release.apk。git 提交号
打进应用不进文件名，拿不到时记为 unknown；构建时间以 Unix 秒注入，
显示时由应用格式化为本地时间。

用法（多余参数透传给 flutter build / flutter run）：

    python scripts/build_app.py run -d windows            # 本地调试，热重载
    python scripts/build_app.py run -d <设备id>            # 指定设备调试
    python scripts/build_app.py windows --release         # 出包
    python scripts/build_app.py linux --release
    python scripts/build_app.py apk --release --target-platform android-arm64

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


def run_flutter(subcommand: str, commit: str, build_time: str, rest: list[str]) -> None:
    """带构建信息执行 flutter run / flutter build；stdin 原样继承，
    flutter run 的热重载按键（r/R/q）可直接使用。"""
    command = [
        *flutter_command(),
        subcommand,
        f"--dart-define=FIREADB_GIT_COMMIT={commit}",
        f"--dart-define=FIREADB_BUILD_TIME={build_time}",
        *rest,
    ]
    print("> " + " ".join(command))
    result = subprocess.run(command, cwd=APP_DIR)
    if result.returncode != 0:
        sys.exit(result.returncode)


def package(target: str, version: str, rest: list[str]) -> Path:
    """把 flutter build 的产物压成带版本号的安装包，返回路径。

    命名 fireadb-<平台>-<版本>-<日期>-<构建类型>.<后缀>，例如
    fireadb-android-1.0.1-20261108-release.apk。
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
        source = APP_DIR / "build/app/outputs/flutter-apk/app-release.apk"
        if not source.is_file():
            sys.exit(f"找不到 APK 产物 {source}")
        dest = DIST_DIR / f"fireadb-android-{suffix}.apk"
        shutil.copy2(source, dest)
        return dest
    sys.exit(f"目标 {target} 没有打包规则，请自行从 app/build/ 取产物")


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
    run_flutter("build", commit, build_time, [args.target, *rest])
    artifact = package(args.target, version, rest)
    print(f"产物：{artifact}")
    emit_github_output(artifact)


if __name__ == "__main__":
    main()
