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
import argparse
import html
import json
import mimetypes
import os
import sys
from pathlib import Path

import requests

# Bot API 单文件上传上限 50MB，留 1MB 余量
MAX_UPLOAD = 49 * 1024 * 1024
# sendMediaGroup 单组最多 10 个文件
GROUP_LIMIT = 10
# caption 上限（Telegram 对消息文本的限制，中文按 1 字符计）
CAPTION_LIMIT = 1024

INTRO = "FireAdb 是一个跨平台 ADB 工具箱，支持设备连接、文件管理、应用管理、截图录屏、shell 命令等功能。"


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
        res = requests.post(f"{self.base}/{method}", timeout=120, **kwargs)
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
            media_arr[0]["caption"] = caption
            media_arr[0]["parse_mode"] = "HTML"
        return self._post("sendMediaGroup", data={
            "chat_id": str(chat_id),
            "media": json.dumps(media_arr),
        }, files=files)


def main():
    parser = argparse.ArgumentParser(description="Release -> Telegram 通知")
    parser.add_argument("--release", required=True, help="gh release view 导出的 json 文件")
    parser.add_argument("--files-dir", required=True, help="release 产物目录")
    args = parser.parse_args()

    token = os.environ.get("TG_BOT_TOKEN", "")
    chat_id = os.environ.get("TG_CHAT_ID", "")
    if not token or not chat_id:
        print("missing TG_BOT_TOKEN / TG_CHAT_ID")
        return 1

    release = json.loads(read_file(args.release).decode("utf-8"))
    name = release.get("name") or ""
    body = html.escape(dedupe_lines(release.get("body") or "").strip())
    url = release.get("url") or ""

    repo = os.environ.get("GITHUB_REPOSITORY", "")
    tag = os.environ.get("GITHUB_REF_NAME", "")

    files_dir = Path(args.files_dir)
    files = sorted(p for p in (files_dir.glob("*") if files_dir.is_dir() else []) if p.is_file())

    # 只为超过 50MB 传不了的文件附直链；放得下的文件本身随消息发送，不再重复列链接
    link_base = f"https://github.com/{repo}/releases/download/{tag}/" if repo and tag else ""
    links = ""
    for p in files:
        if p.stat().st_size <= MAX_UPLOAD:
            continue
        links += f'<a href="{link_base}{p.name}">{html.escape(p.name)}</a>（过大未上传）\n'
    links_str = ("\n<b>产物下载：</b>\n" + links) if links else ""

    bot = TgBot(token)

    # 没有可上传文件时用普通消息发完整说明
    if not [p for p in files if p.stat().st_size <= MAX_UPLOAD]:
        text = f"<b>{html.escape(name)}</b> 已发布\n{INTRO}\n"
        if body:
            text += f"<pre>{truncate(body, 2000)}</pre>\n"
        if url:
            text += f'<a href="{url}">Release 页面</a>\n'
        text += links_str
        return 0 if bot.send_message(chat_id, truncate(text, 4000)).get("ok") else 1

    # 有产物：介绍与产物合并为一条消息，说明文字放 caption（上限 1024）。
    # 正文按剩余预算裁剪，放不下就舍弃正文保链接。
    caption = f"<b>{html.escape(name)}</b> 已发布\n{INTRO}\n"
    if url:
        caption += f'<a href="{url}">Release 页面</a>\n'
    if body:
        budget = CAPTION_LIMIT - len(caption) - len(links_str) - 8  # 8 为 <pre></pre>
        if budget > 30:
            caption += f"<pre>{truncate(body, budget)}</pre>\n"
    caption = truncate(caption + links_str, CAPTION_LIMIT)

    # 上传放得下的文件；超过 50MB 的 Bot API 传不了，链接里已标注
    upload = [p for p in files if p.stat().st_size <= MAX_UPLOAD]
    if len(upload) == 1:
        return 0 if bot.send_document(chat_id, upload[0], caption=caption).get("ok") else 1

    ok = True
    for i in range(0, len(upload), GROUP_LIMIT):
        res = bot.send_media_group(
            chat_id, upload[i: i + GROUP_LIMIT], caption=caption if i == 0 else None)
        ok = ok and res.get("ok")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
