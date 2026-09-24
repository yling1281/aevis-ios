#!/usr/bin/env python3
"""角色卡解析算法的参照实现 + 对拍测试。

为什么要有这个文件：
在 Windows 上跑不了 Swift，而 PNG 分块解析是**最容易写错、错了还静默**的一类代码
（长度字段是大端、末尾有 CRC、Data 切片下标溢出会直接崩）。
所以先用 Python 把算法实现一遍并用构造出来的样本卡验证，
再把同样的结构照搬到 Swift —— 这样至少算法层面是验过的。

用到的代码：
    python3 tools/character_card_reference.py
"""

import base64
import json
import struct
import zlib

PASS = []
FAIL = []


def check(name, got, want):
    if got == want:
        PASS.append(name)
    else:
        FAIL.append("%s\n     得到: %r\n     期望: %r" % (name, got, want))


def check_truth(name, condition, detail=""):
    if condition:
        PASS.append(name)
    else:
        FAIL.append("%s  %s" % (name, detail))


# ——— 构造 PNG ———

def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def make_png(extra_chunks):
    """造一张最小可用 PNG，中间插入给定的块。"""
    ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)
    raw = b"\x00\x00\x00\x00\x00"  # 1 像素 RGBA
    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", ihdr)
    for item in extra_chunks:
        out += item
    out += chunk(b"IDAT", zlib.compress(raw))
    out += chunk(b"IEND", b"")
    return out


def text_chunk(keyword, text):
    return chunk(b"tEXt", keyword.encode("latin-1") + b"\x00" + text.encode("utf-8"))


def itxt_chunk(keyword, text, compressed=False):
    payload = (keyword.encode("latin-1") + b"\x00"
               + bytes([1 if compressed else 0]) + b"\x00"
               + b"zh\x00" + b"\x00")
    if compressed:
        payload += zlib.compress(text.encode("utf-8"))
    else:
        payload += text.encode("utf-8")
    return chunk(b"iTXt", payload)


# ——— 与 Swift 同结构的解析 ———

def read_uint32(data, offset):
    if offset < 0 or offset + 4 > len(data):
        return None
    return struct.unpack(">I", data[offset:offset + 4])[0]


def decode_text_chunk(payload):
    sep = payload.find(b"\x00")
    if sep < 0:
        return None
    keyword = payload[:sep].decode("utf-8", "replace")
    if keyword not in ("chara", "ccv3"):
        return None
    return payload[sep + 1:].decode("utf-8", "replace")


def decode_itxt_chunk(payload):
    sep = payload.find(b"\x00")
    if sep < 0:
        return None
    keyword = payload[:sep].decode("utf-8", "replace")
    if keyword not in ("chara", "ccv3"):
        return None

    cursor = sep + 1
    if cursor + 1 >= len(payload):
        return None
    compression_flag = payload[cursor]
    cursor += 2

    lang_end = payload.find(b"\x00", cursor)
    if lang_end < 0:
        return None
    cursor = lang_end + 1

    trans_end = payload.find(b"\x00", cursor)
    if trans_end < 0:
        return None
    cursor = trans_end + 1

    if compression_flag != 0:
        return None
    return payload[cursor:].decode("utf-8", "replace")


def decode_card_text(text):
    trimmed = text.strip()
    if trimmed.startswith("{"):
        return trimmed.encode("utf-8")
    compact = "".join(trimmed.split())
    try:
        return base64.b64decode(compact)
    except Exception:
        return None


def extract_png_payload(data):
    signature = bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    if len(data) <= 8 or data[:8] != signature:
        return None

    offset = 8
    scanned = 0
    while offset + 8 <= len(data) and scanned < 512:
        scanned += 1
        length = read_uint32(data, offset)
        if length is None:
            return None
        type_start = offset + 4
        if type_start + 4 > len(data):
            return None
        tag = data[type_start:type_start + 4].decode("ascii", "replace")

        payload_start = type_start + 4
        payload_end = payload_start + length
        if payload_end < payload_start or payload_end + 4 > len(data):
            return None
        payload = data[payload_start:payload_end]

        if tag == "tEXt":
            text = decode_text_chunk(payload)
            if text is not None:
                decoded = decode_card_text(text)
                if decoded is not None:
                    return decoded
        if tag == "iTXt":
            text = decode_itxt_chunk(payload)
            if text is not None:
                decoded = decode_card_text(text)
                if decoded is not None:
                    return decoded
        if tag == "IEND":
            break

        offset = payload_end + 4
    return None


# ——— 与 Swift 同结构的映射 ———

CARD_V2 = {
    "spec": "chara_card_v2",
    "spec_version": "2.0",
    "data": {
        "name": "林知夏",
        "description": "27 岁，牙科医生，独居。养了一只叫团子的橘猫。",
        "personality": "表面冷淡，熟了之后话很多。嘴硬心软，不会说好听的。",
        "scenario": "同城，认识两年，最近刚开始约会",
        "first_mes": "……你怎么这么晚还没睡。",
        "mes_example": "<START>\n{{user}}: 在干嘛\n{{char}}: 刚洗完澡，在吹头发。\n{{user}}: 想你了\n{{char}}: 嗯。\n{{char}}: 我也是。",
    },
}

CARD_V1 = {
    "name": "旧版卡",
    "description": "平铺格式的老卡片",
    "personality": "安静",
    "scenario": "同事",
    "first_mes": "早。",
    "mes_example": "{{user}}: 早\n{{char}}: 早。",
}


def clean_example(raw):
    text = raw
    # 先处理「{{char}}:」这种带冒号的写法 ——
    # 只删 {{char}} 会留下一个孤零零的冒号在行首（对拍时发现的）
    for token in ("{{char}}:", "{{char}}：", "{{char}}"):
        text = text.replace(token, "")
    text = text.replace("{{user}}", "对方")
    for token in ("<START>", "<start>", "<START >"):
        text = text.replace(token, "")
    lines = [line.strip() for line in text.split("\n")]
    # 清掉占位符后可能只剩冒号，这种行没信息量
    lines = [line for line in lines if any(ch.isalnum() for ch in line)]
    return "\n".join(lines[:12])


def parse_json_card(data, origin):
    try:
        root = json.loads(data.decode("utf-8"))
    except Exception:
        return None
    if not isinstance(root, dict):
        return None
    body = root.get("data") if isinstance(root.get("data"), dict) else root

    def field(key):
        value = body.get(key)
        return value.strip() if isinstance(value, str) else ""

    name, description = field("name"), field("description")
    personality, scenario = field("personality"), field("scenario")
    example, first = field("mes_example"), field("first_mes")
    if not (name or description or personality):
        return None

    # personality 为主，description 补充（两个都填才拼起来）
    traits = []
    if personality:
        traits.append(personality)
    if description and description != personality:
        traits.append(description)

    return {
        "name": name,
        "personality": "\n\n".join(traits),
        "relationship": scenario,
        "speakingStyle": clean_example(example),
        "gender": "unspecified",
        "firstMessage": first or None,
        "origin": origin,
    }


def main():
    v2_json = json.dumps(CARD_V2, ensure_ascii=False)

    # 1) V2 平铺 JSON（直接给 JSON 文件，不走 PNG）
    result = parse_json_card(v2_json.encode("utf-8"), "JSON 角色卡")
    check("V2 嵌套：取出名字", result["name"], "林知夏")
    check("V2 嵌套：性别不预设", result["gender"], "unspecified")
    check("V2 嵌套：场景进关系", result["relationship"], "同城，认识两年，最近刚开始约会")
    check_truth("V2 嵌套：性格含两段",
                result["personality"].startswith("表面冷淡") and "牙科医生" in result["personality"],
                result["personality"][:60])
    check_truth("V2 嵌套：示例去掉了占位符",
                "{{" not in result["speakingStyle"] and "<START>" not in result["speakingStyle"],
                result["speakingStyle"])
    check_truth("V2 嵌套：user 变成「对方」，且没留下孤零零的冒号",
                "对方" in result["speakingStyle"]
                and not any(line.startswith(":") for line in result["speakingStyle"].split("\n")),
                result["speakingStyle"])

    # 2) V1 平铺
    v1 = parse_json_card(json.dumps(CARD_V1, ensure_ascii=False).encode("utf-8"), "JSON 角色卡")
    check("V1 平铺：名字", v1["name"], "旧版卡")
    # personality 在前，description 补充在后 —— 这是有意的（卡片作者经常只填一个）
    check("V1 平铺：性格排在前、描述补充在后", v1["personality"], "安静\n\n平铺格式的老卡片")
    check("V1 平铺：开场白", v1["firstMessage"], "早。")

    # 3) 不是卡片
    check("空 JSON 不算卡片", parse_json_card(b"{}", "x"), None)
    check("乱码不算卡片", parse_json_card(b"not json at all", "x"), None)

    # 4) PNG + tEXt(chara, base64)
    png = make_png([text_chunk("chara", base64.b64encode(v2_json.encode("utf-8")).decode("ascii"))])
    payload = extract_png_payload(png)
    check_truth("PNG tEXt：取到了负载", payload is not None)
    if payload:
        parsed = parse_json_card(payload, "PNG 角色卡")
        check("PNG tEXt：映射出名字", parsed["name"], "林知夏")
        check("PNG tEXt：来源标记", parsed["origin"], "PNG 角色卡")

    # 5) base64 里夹换行
    b64 = base64.b64encode(v2_json.encode("utf-8")).decode("ascii")
    wrapped = "\n".join(b64[i:i + 60] for i in range(0, len(b64), 60))
    png_wrapped = make_png([text_chunk("chara", wrapped)])
    check_truth("PNG tEXt：base64 夹换行也能读", extract_png_payload(png_wrapped) is not None)

    # 6) iTXt 未压缩
    png_itxt = make_png([itxt_chunk("chara", v2_json)])
    check_truth("PNG iTXt：未压缩能读", extract_png_payload(png_itxt) is not None)

    # 7) iTXt 压缩的：老老实实返回 None，不要崩
    png_itxt_z = make_png([itxt_chunk("chara", v2_json, compressed=True)])
    check("PNG iTXt：压缩的按不支持处理", extract_png_payload(png_itxt_z), None)

    # 8) tEXt 里直接放 JSON（不走 base64）
    png_raw = make_png([text_chunk("chara", v2_json)])
    check_truth("PNG tEXt：直接放 JSON 也能读", extract_png_payload(png_raw) is not None)

    # 9) 关键字不对：不该误取
    png_other = make_png([text_chunk("Comment", v2_json)])
    check("PNG：别的关键字不取", extract_png_payload(png_other), None)

    # 10) 坏文件：截断 / 长度字段撒谎 / 空数据 —— 都必须安全返回 None
    check("截断的 PNG 安全返回", extract_png_payload(png[:20]), None)
    check("只有签名的 PNG", extract_png_payload(b"\x89PNG\r\n\x1a\n"), None)
    check("空数据", extract_png_payload(b""), None)
    check("不是 PNG 的二进制", extract_png_payload(b"\x00" * 64), None)

    lying = bytearray()
    lying += b"\x89PNG\r\n\x1a\n"
    lying += struct.pack(">I", 0xFFFFFFF0) + b"tEXt" + b"chara\x00{}"
    check("长度字段撒谎不崩", extract_png_payload(bytes(lying)), None)

    # 11) ccv3 关键字也认
    png_ccv3 = make_png([text_chunk("ccv3", base64.b64encode(v2_json.encode("utf-8")).decode("ascii"))])
    check_truth("PNG ccv3：也认", extract_png_payload(png_ccv3) is not None)

    # 12) 坏 base64 不崩
    png_badb64 = make_png([text_chunk("chara", "!!!not base64!!!")])
    check("坏 base64 安全返回", extract_png_payload(png_badb64), None)

    print("通过 %d 项" % len(PASS))
    for name in PASS:
        print("  ok  %s" % name)
    if FAIL:
        print("\n失败 %d 项：" % len(FAIL))
        for item in FAIL:
            print("  !!  %s" % item)
        return 1
    print("\n全部通过。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
