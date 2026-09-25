#!/usr/bin/env python3
"""网易云接口探针 —— 用和 Swift 版**同一套加密算法**真去打网易，
看到底返回什么。这样「获取错误」就不会只靠猜。

用法:
    python tools/netease_probe.py                      # 匿名探
    python tools/netease_probe.py "MUSIC_U=xxx; ..."   # 带自己的 Cookie 探

会依次打印每一步的 HTTP 状态码 + 响应体片段，包括：
  1. 首页预热（拿匿名 cookie，这步能显著降低风控概率）
  2. /weapi/cloudsearch/get/web      搜索（用户报的就是这个错）
  3. /weapi/song/enhance/player/url       老版播放地址
  4. /weapi/song/enhance/player/url/v1    新版播放地址（带 level/encodeType）
"""

import base64
import hashlib
import json
import secrets
import sys
import urllib.parse
import urllib.request

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

AES_PRESET_KEY = b"0CoJUm6Qyw8W8jud"
AES_IV = b"0102030405060708"
BASE62 = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
RSA_EXPONENT = 0x010001
RSA_MODULUS = int(
    "00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725"
    "152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ec"
    "bda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d8"
    "13cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7",
    16,
)

UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0 Safari/537.36"
)
BASE = "https://music.163.com"


def aes_b64(text: str, key: bytes) -> str:
    raw = text.encode("utf-8")
    pad = 16 - len(raw) % 16
    raw += bytes([pad]) * pad
    encryptor = Cipher(algorithms.AES(key), modes.CBC(AES_IV)).encryptor()
    return base64.b64encode(encryptor.update(raw) + encryptor.finalize()).decode("ascii")


def enc_sec_key(secret: str) -> str:
    message = int(secret[::-1].encode("utf-8").hex(), 16)
    result = message % RSA_MODULUS
    for _ in range(16):
        result = (result * result) % RSA_MODULUS
    result = (result * message) % RSA_MODULUS
    return "%0256x" % result


def weapi(params: dict) -> dict:
    secret = "".join(secrets.choice(BASE62) for _ in range(16))
    data = {"csrf_token": ""}
    data.update(params)
    text = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    return {
        "params": aes_b64(aes_b64(text, AES_PRESET_KEY), secret.encode("ascii")),
        "encSecKey": enc_sec_key(secret),
    }


class Session:
    def __init__(self, cookie: str = ""):
        self.cookie = cookie

    def request(self, path: str, form: dict = None, method: str = "POST", warm: bool = False):
        url = BASE + path
        data = None
        if form is not None:
            data = urllib.parse.urlencode(form).encode("ascii")
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("User-Agent", UA)
        req.add_header("Referer", BASE)
        req.add_header("Origin", BASE)
        if data is not None:
            req.add_header("Content-Type", "application/x-www-form-urlencoded")
        if self.cookie:
            req.add_header("Cookie", self.cookie)
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                body = resp.read()
                status = resp.status
                set_cookie = resp.headers.get("Set-Cookie")
        except urllib.error.HTTPError as e:
            body = e.read()
            status = e.code
            set_cookie = e.headers.get("Set-Cookie")
        except Exception as e:  # 网络层错误要原样暴露，这正是 App 里被吞掉的东西
            return None, 0, "网络层异常：%r" % e, None
        if warm and set_cookie:
            names = [c.split(";")[0] for c in set_cookie.split(",")]
            parts = [p for p in (self.cookie.split("; ") if self.cookie else []) if p]
            have = {p.split("=")[0].strip() for p in parts}
            for item in names:
                if item.split("=")[0].strip() not in have:
                    parts.append(item)
            self.cookie = "; ".join(parts)
        return status, body, set_cookie


def show(label, status, body):
    text = body.decode("utf-8", "replace") if isinstance(body, bytes) else str(body)
    print("  HTTP %s | %d 字节" % (status, len(text)))
    print("  " + text[:400].replace("\n", " "))
    print()


def main():
    cookie = sys.argv[1] if len(sys.argv) > 1 else ""
    s = Session(cookie)

    print("=== 0. 首页预热（拿匿名 cookie）===")
    status, body, set_cookie = s.request("/", method="GET", warm=True)
    print("  HTTP", status, "| Set-Cookie 得到:", (set_cookie or "无")[:160])
    print("  当前 cookie:", (s.cookie or "空")[:200])
    print()

    print("=== 1. 搜索 /weapi/cloudsearch/get/web  ===")
    enc = weapi({"s": "周杰伦", "type": 1, "limit": 5, "offset": 0, "total": True})
    status, body, _ = s.request("/weapi/cloudsearch/get/web", enc)
    show("cloudsearch", status, body)

    print("=== 2. 老版播放地址 /weapi/song/enhance/player/url ===")
    enc = weapi({"ids": "[347230]", "br": 320000})
    status, body, _ = s.request("/weapi/song/enhance/player/url", enc)
    show("player/url", status, body)

    print("=== 3. 新版播放地址 /weapi/song/enhance/player/url/v1 ===")
    enc = weapi({"ids": "[347230]", "level": "standard", "encodeType": "mp3"})
    status, body, _ = s.request("/weapi/song/enhance/player/url/v1", enc)
    show("player/url/v1", status, body)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
