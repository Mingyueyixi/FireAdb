#!/usr/bin/python3
# -*- coding: utf-8 -*-
"""Release 发布完成后，把发布信息和产物文件上传到 Telegram 群。

release 信息由 CI 里 `gh release view --json name,body,url` 落盘后经
--release 传入。不解析 github context，也不往环境变量里塞复杂 JSON，
绕开转义/格式丢失的坑。

用法（CI）：
  python scripts/tg_release_notify.py --release release.json --files-dir tg_assets

环境变量：
  TG_BOT_TOKEN  机器人 token
  TG_CHAT_ID    目标聊天/频道 id（群组为负数，直接字符串传入）
"""
import configparser
import html
import json
import mimetypes
import os
import sys
import tempfile
from pathlib import Path

import requests

# Bot API 单文件上传上限 50MB，留 1MB 余量
MAX_UPLOAD = 49 * 1024 * 1024
# sendMediaGroup 单组最多 10 个文件
GROUP_LIMIT = 10
# caption 上限（Telegram 对消息文本的限制，中文按 1 字符计）
CAPTION_LIMIT = 1024

INTRO = "FireAdb 是一个跨平台 ADB 工具箱，支持设备连接、文件管理、应用管理、截图录屏、shell 命令等功能。"

# 固定输入路径（与 .github/workflows/build-multi-platform.yml 的 notify-release 步骤对应，
# gh release view/download 均在仓库根目录执行）
RELEASE_JSON = Path("release.json")
ASSETS_DIR = Path("tg_assets")

# app 图标，与正文一起作为第一条消息发送
ICON_PATH = Path(__file__).parent.parent / "app/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png"


def read_file(path):
    with open(path, "rb") as f:
        return f.read()


def guess_mime(path: Path):
    if path.suffix == ".apk":
        return "application/vnd.android.package-archive"
    return mimetypes.guess_type(str(path))[0] or "application/octet-stream"


def truncate(text: str, limit: int):
    if len(text) <= limit:
        return text
    return text[: limit - 1] + "……"


def dedupe_lines(text: str) -> str:
    """去掉重复的非空行。generate_release_notes 在 tag 重打重跑后会把
    changelog 追加进旧正文，同一行（如 Full Changelog 链接）会重复多份。"""
    seen = set()
    lines = []
    for line in text.splitlines():
        key = line.strip()
        if key and key in seen:
            continue
        if key:
            seen.add(key)
        lines.append(line)
    return "\n".join(lines)


class TgBot:
    def __init__(self, token):
        self.base = f"https://api.telegram.org/bot{token}"

    def _post(self, method, **kwargs):
        try:
            res = requests.post(f"{self.base}/{method}", timeout=120, **kwargs)
        except requests.RequestException as e:
            # 只打印异常类型，避免 traceback 把带 token 的完整 URL 泄漏进日志
            print(f"{method} request failed: {e.__class__.__name__}")
            return {"ok": False}
        result = res.json()
        if not result.get("ok"):
            print(f"{method} failed: {res.status_code} {res.text}")
        return result

    def send_message(self, chat_id, text):
        return self._post("sendMessage", json={
            "chat_id": chat_id,
            "text": text,
            "parse_mode": "HTML",
            "disable_web_page_preview": True,
        })

    def send_document(self, chat_id, path: Path, caption=None):
        data = {"chat_id": str(chat_id)}
        if caption:
            data["caption"] = caption
            data["parse_mode"] = "HTML"
        files = {"document": (path.name, read_file(path), guess_mime(path))}
        return self._post("sendDocument", data=data, files=files)

    def send_photo(self, chat_id, path: Path, caption=None):
        data = {"chat_id": str(chat_id)}
        if caption:
            data["caption"] = caption
            data["parse_mode"] = "HTML"
        files = {"photo": (path.name, read_file(path), "image/png")}
        return self._post("sendPhoto", data=data, files=files)

    def send_media_group(self, chat_id, paths, caption=None):
        # multipart 形式：media 里用 attach:// 引用同一请求的文件字段。
        # attach 名只用字母数字下划线，用序号避免重名。
        files = {}
        media_arr = []
        for i, p in enumerate(paths):
            attach = f"attach_{i}"
            files[attach] = (p.name, read_file(p), guess_mime(p))
            media_arr.append({"type": "document", "media": f"attach://{attach}"})
        if caption:
            # 挂在最后一个文件上：客户端把 caption 渲染在其所属文件下方，
            # 挂最后一个即「产物在前、正文垫底」的阅读顺序
            media_arr[-1]["caption"] = caption
            media_arr[-1]["parse_mode"] = "HTML"
        return self._post("sendMediaGroup", data={
            "chat_id": str(chat_id),
            "media": json.dumps(media_arr),
        }, files=files)


def load_test_env():
    """标准库 configparser 读取本地测试环境文件 scripts/.tg_test.env（不入库）。
    进程已存在的环境变量优先，文件里的只做兜底。"""
    env_file = Path(__file__).parent / ".tg_test.env"
    if not env_file.is_file():
        return
    cp = configparser.ConfigParser()
    cp.optionxform = str  # 保留键名大小写
    cp.read_string("[env]\n" + env_file.read_text(encoding="utf-8"))
    for key, value in cp["env"].items():
        os.environ.setdefault(key, value.strip())

def build_release_texts(release, files):
    """构建发布文案。返回 (full_text, caption)：
    full_text 用于无可上传文件时的普通消息（≤4096）；
    caption 用于随图片/相册发送（≤1024），正文按剩余预算裁剪，
    放不下就舍弃正文保链接。"""
    name = release.get("name") or ""
    body = html.escape(dedupe_lines(release.get("body") or "").strip())
    url = release.get("url") or ""

    # 只为超过 50MB 传不了的文件附直链；放得下的文件本身随消息发送，不重复列链接
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    tag = os.environ.get("GITHUB_REF_NAME", "")
    link_base = f"https://github.com/{repo}/releases/download/{tag}/" if repo and tag else ""
    links = ""
    for p in files:
        if p.stat().st_size <= MAX_UPLOAD:
            continue
        links += f'<a href="{link_base}{p.name}">{html.escape(p.name)}</a>（过大未上传）\n'
    links_str = ("\n<b>产物下载：</b>\n" + links) if links else ""

    text = f"<b>{html.escape(name)}</b> 已发布\n{INTRO}\n"
    if body:
        text += f"<pre>{truncate(body, 2000)}</pre>\n"
    if url:
        text += f'<a href="{url}">Release 页面</a>\n'
    text += links_str

    caption = f"<b>{html.escape(name)}</b> 已发布\n{INTRO}\n"
    if url:
        caption += f'<a href="{url}">Release 页面</a>\n'
    if body:
        budget = CAPTION_LIMIT - len(caption) - len(links_str) - 8  # 8 为 <pre></pre>
        if budget > 30:
            caption += f"<pre>{truncate(body, budget)}</pre>\n"
    caption = truncate(caption + links_str, CAPTION_LIMIT)
    return truncate(text, 4000), caption

def send_release(bot: TgBot, chat_id, release, files, icon=None) -> bool:
    """发送发布通知。返回是否全部成功。

    - 无可上传文件：发一条普通消息（完整正文 + 直链）
    - 有产物：先发「图标图片 + 正文 caption」（正文在图标下方、产物之前），
      再发产物相册/文件。Bot API 相册不能混图片和文件，只能拆两条；
      发图失败退回：正文 caption 挂相册最后一个文件（产物在前、正文垫底）
    """
    full_text, caption = build_release_texts(release, files)
    upload = sorted((p for p in files if p.stat().st_size <= MAX_UPLOAD),
                    key=lambda p: p.name)
    if not upload:
        return bot.send_message(chat_id, full_text).get("ok")

    album_caption = caption
    if icon and Path(icon).is_file():
        if bot.send_photo(chat_id, Path(icon), caption=caption).get("ok"):
            album_caption = None

    ok = True
    if len(upload) == 1:
        ok = bot.send_document(chat_id, upload[0], caption=album_caption).get("ok")
    else:
        for i in range(0, len(upload), GROUP_LIMIT):
            res = bot.send_media_group(
                chat_id, upload[i: i + GROUP_LIMIT],
                caption=album_caption if i == 0 else None)
            ok = ok and res.get("ok")
    return ok

def test_send_notification():
    """临时联调，与 main 流程一致，仅输入不同。运行：pytest scripts/tg_release_notify.py

    前提：scripts/.tg_test.env 配好 TG_BOT_TOKEN / TG_TEST_CHAT_ID（不入库）。
    需要调整测试场景时直接改本函数内的假数据即可。
    """
    import pytest  # 仅测试路径使用，避免运行时强依赖

    load_test_env()
    token = os.environ.get("TG_BOT_TOKEN", "")
    chat_id = os.environ.get("TG_TEST_CHAT_ID", "")
    if not token or not chat_id:
        pytest.skip("scripts/.tg_test.env 缺少 TG_BOT_TOKEN / TG_TEST_CHAT_ID")

    release = {
        "name": "vTEST",
        "body": "**Full Changelog**: https://github.com/Mingyueyixi/FireAdb/commits/vTEST\n"
                "**Full Changelog**: https://github.com/Mingyueyixi/FireAdb/commits/vTEST\n"
                "### Features\n- 测试正文去重：上一行只应出现一次\n- 测试 HTML 转义：<b>加粗</b>",
        "url": "https://example.com/release",
    }
    tmp = Path(tempfile.mkdtemp(prefix="tg_notify_test_"))
    files = []
    for name in ("fireadb-android-vTEST.apk", "fireadb-windows-vTEST.zip"):
        p = tmp / name
        p.write_bytes(b"FireAdb TG notify test file\n")
        files.append(p)

    assert send_release(TgBot(token), chat_id, release, files, ICON_PATH)

def main():
    token = os.environ.get("TG_BOT_TOKEN", "")
    chat_id = os.environ.get("TG_CHAT_ID", "")
    if not token or not chat_id:
        print("missing TG_BOT_TOKEN / TG_CHAT_ID")
        return 1

    release = json.loads(read_file(RELEASE_JSON).decode("utf-8"))
    files = [p for p in (ASSETS_DIR.glob("*") if ASSETS_DIR.is_dir() else []) if p.is_file()]

    bot = TgBot(token)
    return 0 if send_release(bot, chat_id, release, files, ICON_PATH) else 1


if __name__ == "__main__":
    sys.exit(main())
