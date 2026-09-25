#!/usr/bin/env python3
"""在 netease_probe.py 的基础上做「哪种姿势能搜出来」的对照实验。

已知：匿名 + 不带 cookie 的 weapi 搜索 → {"code":50000005}（校验失败）。
本脚本逐个变体试，找出能返回 songs 的那一种，用来指导 Swift 端怎么改。

用法:
    python tools/netease_probe_variants.py
"""

import base64
import hashlib
import json
import os
import secrets
import urllib.error
import urllib.parse
import urllib.request

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

AES_PRESET_KEY = b"0CoJUm6Qyw8W8jud"
AES_IV = b"0102030405060708"
EAPI_KEY = b"e82ckenh8dichen8"
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
EAPI_BASE = "https://interface.music.163.com"

KEYWORD = "周杰伦"


def aes_b64(text, key):
    raw = text.encode("utf-8")
    pad = 16 - len(raw) % 16
    raw += bytes([pad]) * pad
    enc = Cipher(algorithms.AES(key), modes.CBC(AES_IV)).encryptor()
    return base64.b64encode(enc.update(raw) + enc.finalize()).decode("ascii")


def rsa_raw(secret):
    message = int(secret[::-1].encode("utf-8").hex(), 16)
    result = message % RSA_MODULUS
    for _ in range(16):
        result = (result * result) % RSA_MODULUS
    return "%0256x" % ((result * message) % RSA_MODULUS)


def weapi(params):
    secret = "".join(secrets.choice(BASE62) for _ in range(16))
    data = {"csrf_token": ""}
    data.update(params)
    text = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    return {
        "params": aes_b64(aes_b64(text, AES_PRESET_KEY), secret.encode("ascii")),
        "encSecKey": rsa_raw(secret),
    }


def eapi(path, payload):
    """eapi：AES-128-ECB + MD5 摘要，请求发到 interface.music.163.com。"""
    text = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    message = "nobody" + path + "use" + text + "md5forencrypt"
    digest = hashlib.md5(message.encode("utf-8")).hexdigest()
    raw = (path + "-36cd479b6b5-" + text + "-36cd479b6b5-" + digest).encode("utf-8")
    pad = 16 - len(raw) % 16
    raw += bytes([pad]) * pad
    enc = Cipher(algorithms.AES(EAPI_KEY), modes.ECB()).encryptor()
    return {"params": (enc.update(raw) + enc.finalize()).hex().upper()}


def post(url, form, cookie="", extra_headers=None, warm=False):
    data = urllib.parse.urlencode(form).encode("ascii")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("User-Agent", UA)
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    if cookie:
        req.add_header("Cookie", cookie)
    for k, v in (extra_headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return resp.status, resp.read(), resp.headers.get("Set-Cookie")
    except urllib.error.HTTPError as e:
        return e.code, e.read(), e.headers.get("Set-Cookie")
    except Exception as e:
        return 0, ("网络异常: %r" % e).encode(), None


def verdict(status, body):
    text = body.decode("utf-8", "replace")
    try:
        obj = json.loads(text)
    except Exception:
        return "非 JSON", text[:120]
    code = obj.get("code")
    songs = ((obj.get("result") or {}).get("songs")) if isinstance(obj.get("result"), dict) else None
    if songs:
        return "✅ 搜到了 %d 首" % len(songs), text[:100]
    return "❌ code=%s" % code, text[:160]


def main():
    cases = []

    # A: 只在 URL 上加 ?csrf_token=（标准写法），无 cookie
    cases.append((
        "A 无cookie + URL带csrf",
        lambda: post(BASE + "/weapi/cloudsearch/get/web?csrf_token=",
                     weapi({"s": KEYWORD, "type": 1, "limit": 3, "offset": 0, "total": True})),
    ))

    # B: cookie 里塞 os=pc
    cases.append((
        "B cookie=os=pc",
        lambda: post(BASE + "/weapi/cloudsearch/get/web?csrf_token=",
                     weapi({"s": KEYWORD, "type": 1, "limit": 3, "offset": 0, "total": True}),
                     cookie="os=pc"),
    ))

    # C: 完整匿名 cookie 组合（社区常见的设备标识）
    anon = "os=pc; appver=2.10.6; NMTID=%s; _ntes_nuid=%s" % (
        os.urandom(16).hex(), os.urandom(16).hex())
    cases.append((
        "C cookie=os=pc+appver+NMTID",
        lambda: post(BASE + "/weapi/cloudsearch/get/web?csrf_token=",
                     weapi({"s": KEYWORD, "type": 1, "limit": 3, "offset": 0, "total": True}),
                     cookie=anon),
    ))

    # D: 加 X-Real-IP（有些实现靠它过风控）
    cases.append((
        "D 无cookie + X-Real-IP",
        lambda: post(BASE + "/weapi/cloudsearch/get/web?csrf_token=",
                     weapi({"s": KEYWORD, "type": 1, "limit": 3, "offset": 0, "total": True}),
                     extra_headers={"X-Real-IP": "118.88.88.88", "X-Forwarded-For": "118.88.88.88"}),
    ))

    # E: eapi（换一条通道，NeteaseCloudMusicApi 现在主推）
    def case_e():
        return post(EAPI_BASE + "/eapi/cloudsearch/get/web?csrf_token=",
                    eapi("/api/cloudsearch/get/web",
                         {"s": KEYWORD, "type": 1, "limit": 3, "offset": 0, "total": True}),
                    cookie=anon)
    cases.append(("E eapi 通道", case_e))

    # F: linuxapi（又一条通道）
    def case_f():
        payload = json.dumps(
            {"method": "POST", "url": "https://music.163.com/api/cloudsearch/get/web",
             "params": {"s": KEYWORD, "type": 1, "limit": 3, "offset": 0, "total": True}},
            ensure_ascii=False, separators=(",", ":"))
        raw = payload.encode("utf-8")
        pad = 16 - len(raw) % 16
        raw += bytes([pad]) * pad
        enc = Cipher(algorithms.AES(b"rFgB&h#%2?^eDg:Q"), modes.ECB()).encryptor()
        return post("https://music.163.com/api/linux/forward",
                    {"eparams": (enc.update(raw) + enc.finalize()).hex().upper()},
                    cookie=anon)
    cases.append(("F linuxapi 通道", case_f))

    for name, fn in cases:
        status, body, set_cookie = fn()
        tag, detail = verdict(status, body)
        print("%-28s HTTP %-3s %s" % (name, status, tag))
        print("      %s" % detail)
        if set_cookie:
            print("      Set-Cookie: %s" % set_cookie[:100])
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
