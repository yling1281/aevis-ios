#!/usr/bin/env python3
"""把整条链路用「明文接口」走一遍，确认每步都能拿到数据，并打印原始字段名。

上一步已确认：加密的 weapi 通道被掐（永远 50000005），明文接口正常。
这一步要回答：
  1. 明文搜索返回的 song 里，歌手/专辑字段到底叫 ar/al 还是 artists/album？
  2. 免费曲目的播放地址能不能真拿到（付费曲目 -110 是正常的）
  3. 歌词、歌单详情、每日推荐各自走哪个明文端点

用法:
    python tools/netease_probe_plain.py
"""

import json
import urllib.error
import urllib.parse
import urllib.request

UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0 Safari/537.36"
)
BASE = "https://music.163.com"
KEYWORD = "晴天"


def fetch(path, form=None, method=None):
    url = BASE + path
    data = urllib.parse.urlencode(form).encode("ascii") if form is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("User-Agent", UA)
    req.add_header("Referer", BASE)
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
    print("=== 1. 明文搜索，看原始字段名 ===")
    status, text = fetch("/api/search/get/web?csrf_token=",
                         {"s": KEYWORD, "type": 1, "offset": 0, "limit": 2, "total": "true"},
                         method="POST")
    obj = json.loads(text)
    songs = obj["result"]["songs"]
    print("  HTTP %s | songCount=%s | 拿到 %d 首" % (status, obj["result"].get("songCount"), len(songs)))
    print("  第一首的键名：%s" % sorted(songs[0].keys()))
    print("  简化后：")
    first = songs[0]
    print("     id       =", first.get("id"))
    print("     name     =", first.get("name"))
    print("     ar       =", [a.get("name") for a in first.get("ar", [])])
    print("     artists  =", [a.get("name") for a in (first.get("artists") or [])])
    print("     al       =", (first.get("al") or {}).get("name"))
    print("     album    =", (first.get("album") or {}).get("name"))
    print("     dt       =", first.get("dt"), " duration =", first.get("duration"))
    print("     fee      =", first.get("fee"), "（0 免费 / 1 会员 / 8 低音质免费）")
    print()

    free_id = None
    for s in songs:
        if s.get("fee") in (0, 8):
            free_id = s["id"]
            break
    print("  挑一首免费的测播放地址：", free_id or "（本页都是付费曲，改用固定 id 33894312）")
    print()

    print("=== 2. 明文播放地址（免费曲目）===")
    for tid in [free_id or 33894312]:
        status, text = fetch("/api/song/enhance/player/url?ids=[%s]&br=320000" % tid)
        data = json.loads(text)["data"][0]
        print("  id=%s HTTP %s | url=%s" % (tid, status, (data.get("url") or "空")[:90]))
        print("     code=%s br=%s fee=%s size=%s" % (data.get("code"), data.get("br"), data.get("fee"), data.get("size")))
    print()

    print("=== 3. 歌词 ===")
    status, text = fetch("/api/song/lyric?id=%s&lv=-1&kv=-1&tv=-1" % (free_id or 33894312))
    obj = json.loads(text)
    lrc = (obj.get("lrc") or {}).get("lyric") or ""
    print("  HTTP %s | 歌词 %d 字 | 头两行：%s" % (status, len(lrc), lrc.split("\n")[:2]))
    print()

    print("=== 4. 歌单详情（明文档）===")
    status, text = fetch("/api/v6/playlist/detail?id=3778678")
    obj = json.loads(text)
    pl = obj.get("playlist") or {}
    print("  HTTP %s | code=%s | 歌单名=%s | 曲目数=%s"
          % (status, obj.get("code"), pl.get("name"), len(pl.get("tracks") or [])))
    print()

    print("=== 5. 每日推荐（需登录 cookie，匿名看返回什么）===")
    status, text = fetch("/api/discovery/recommend/songs?csrf_token=", {}, method="POST")
    obj = json.loads(text)
    print("  HTTP %s | code=%s | %s" % (status, obj.get("code"), text[:150]))
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
