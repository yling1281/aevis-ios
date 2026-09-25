#!/usr/bin/env python3
"""决定性实验：找出搜索到底怎么才通。

已知：所有一次性请求（weapi / eapi / linuxapi / 明文）都返回 code=50000005。
观察：网易每次响应都下发 Set-Cookie: NMTID=... —— 说明它要「先给牌子、下次认牌子」。

本脚本测三件事：
  1. 两阶段：先取 NMTID，再带着它重试（没 Cookie 时根本不该期待通过）
  2. 明文 GET /api/search/get/web（老接口，不需要加密）—— 通了就能绕开整个加密层
  3. 明文播放地址 /api/song/enhance/player/url

用法:
    python tools/netease_probe_session.py
"""

import http.cookiejar
import json
import secrets
import urllib.error
import urllib.parse
import urllib.request

UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0 Safari/537.36"
)
BASE = "https://music.163.com"
KEYWORD = "周杰伦"


def make_opener():
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    opener.addheaders = [
        ("User-Agent", UA),
        ("Referer", BASE),
        ("Origin", BASE),
    ]
    return opener, jar


def show(name, status, text, jar):
    try:
        obj = json.loads(text)
    except Exception:
        obj = None
    if isinstance(obj, dict):
        songs = None
        result = obj.get("result")
        if isinstance(result, dict):
            songs = result.get("songs")
        if songs is None and isinstance(obj.get("songs"), list):
            songs = obj["songs"]
        if songs:
            tag = "✅ 搜到 %d 首 —— 例如：%s / %s" % (
                len(songs),
                (songs[0].get("name") or (songs[0].get("album") or {}).get("name") or "?"),
                ", ".join(a.get("name", "?") for a in (songs[0].get("ar") or songs[0].get("artists") or [])[:2]),
            )
        else:
            tag = "❌ code=%s msg=%s" % (obj.get("code"), obj.get("message"))
    else:
        tag = "非 JSON"
    print("  %-46s HTTP %-3s %s" % (name, status, tag))
    if not (isinstance(obj, dict) and (obj.get("result") or {}).get("songs")):
        print("      %s" % text[:200].replace("\n", " "))
    print("      cookies: %s" % ", ".join("%s=%s" % (c.name, c.value[:14]) for c in jar))
    return text


def fetch(opener, url, form=None, method=None):
    data = urllib.parse.urlencode(form).encode("ascii") if form is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return 0, "网络异常: %r" % e


def main():
    opener, jar = make_opener()

    print("=== 第 1 步：先拿牌子（访问首页，让网易下发 NMTID）===")
    status, text = fetch(opener, BASE + "/")
    print("  HTTP %s | cookies: %s" % (status, ", ".join("%s=%s" % (c.name, c.value) for c in jar)))
    print()

    if not jar:
        print("  ⚠️ 首页没给 cookie，改从搜索接口的下发里取")
        fetch(opener, BASE + "/api/search/get?s=%s&type=1&limit=1" % urllib.parse.quote(KEYWORD))
        print()

    print("=== 第 2 步：带着牌子打明文接口 ===")
    status, text = fetch(
        opener,
        BASE + "/api/search/get/web?csrf_token=",
        {"s": KEYWORD, "type": 1, "offset": 0, "limit": 3, "total": "true"},
        method="POST",
    )
    show("POST /api/search/get/web（明文）", status, text, jar)
    print()

    status, text = fetch(
        opener,
        BASE + "/api/search/get?s=%s&type=1&limit=3&offset=0" % urllib.parse.quote(KEYWORD),
    )
    show("GET  /api/search/get（明文）", status, text, jar)
    print()

    print("=== 第 3 步：明文播放地址 ===")
    status, text = fetch(
        opener,
        BASE + "/api/song/enhance/player/url?ids=[347230]&br=320000",
    )
    print("  HTTP %s" % status)
    print("      %s" % text[:260])
    print()

    print("=== 第 4 步：明文云搜索（/api/cloudsearch/pc）===")
    status, text = fetch(
        opener,
        BASE + "/api/cloudsearch/pc?csrf_token=",
        {"s": KEYWORD, "type": 1, "offset": 0, "limit": 3, "total": "true"},
        method="POST",
    )
    show("POST /api/cloudsearch/pc（明文）", status, text, jar)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
