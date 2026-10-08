#!/usr/bin/env python3
"""生成「零砚后台」的 App 图标（纯 zlib 手写 PNG，不依赖任何第三方库）。

用法:
    python3 LingyanAdmin/scripts/make_icon.py LingyanAdmin/Resources

会写出:
    <根目录>/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png

构图：一方**砚台**（深墨底 + 石青色砚面 + 砚池），跟 Aevis 那个紫色光核明显不同。
两条注意：
  · iOS 会把图标裁成圆角方形（squircle），沿对角线可视半径约 0.42×边长，
    所有装饰都必须落在这个半径以内，否则四个角会被切掉；
  · App Store 不接受带 alpha 的图标 —— 所以这里写 **color type 2（RGB，无 alpha）**。
"""
import math
import os
import struct
import sys
import zlib

SIZE = 1024


def _clamp(v):
    return 0 if v < 0 else (255 if v > 255 else int(v))


def render(size):
    """返回 color type 2（RGB）的原始像素行（每行前置 filter byte）。"""
    rows = bytearray()
    c = size / 2.0

    stone_w = size * 0.52      # 砚面宽
    stone_h = size * 0.40      # 砚面高
    stone_r = size * 0.10      # 砚面圆角

    def in_round_rect(dx, dy, hw, hh, r):
        ax, ay = abs(dx), abs(dy)
        if ax > hw or ay > hh:
            return False
        # 四个角做圆角裁剪
        cx, cy = hw - r, hh - r
        if ax > cx and ay > cy:
            return (ax - cx) ** 2 + (ay - cy) ** 2 <= r * r
        return True

    for y in range(size):
        rows.append(0)                       # PNG filter type: none
        py = y + 0.5 - c
        ny = (y + 0.5) / size
        for x in range(size):
            px = x + 0.5 - c
            nx = (x + 0.5) / size

            # ---- 底：深墨，自上而下压暗 ----
            t = ny
            r = 26 * (1 - t) + 9 * t
            g = 33 * (1 - t) + 11 * t
            b = 46 * (1 - t) + 17 * t

            # ---- 中心偏上的冷光 ----
            d = math.sqrt(px * px + (py + size * 0.06) ** 2) / (size * 0.40)
            if d < 1.0:
                k = (1.0 - d) ** 2.2 * 0.85
                r += 30 * k
                g += 46 * k
                b += 72 * k

            # ---- 砚台投影（比砚面大一圈的暗晕）----
            if in_round_rect(px, py + size * 0.012, stone_w / 2 + size * 0.018,
                             stone_h / 2 + size * 0.018, stone_r + size * 0.01):
                r *= 0.72
                g *= 0.72
                b *= 0.74

            # ---- 砚面：石青（上亮下暗，像一块被光照着的石头）----
            if in_round_rect(px, py, stone_w / 2, stone_h / 2, stone_r):
                shade = 0.86 + 0.28 * (1.0 - (py / stone_h + 0.5))
                r = 96 * shade
                g = 129 * shade
                b = 168 * shade

                # 砚池：椭圆凹槽（墨黑）
                ex = px / (stone_w * 0.30)
                ey = (py - stone_h * 0.04) / (stone_h * 0.26)
                ed = ex * ex + ey * ey
                if ed <= 1.0:
                    depth = 1.0 - ed
                    r -= 74 * (0.35 + depth)
                    g -= 96 * (0.35 + depth)
                    b -= 116 * (0.35 + depth)

                    # 池子里一点残留的墨光（偏青）
                    if ed < 0.30:
                        r += 10
                        g += 34
                        b += 46

                # 砚面上沿的高光细线
                if -stone_h / 2 + size * 0.030 < py < -stone_h / 2 + size * 0.045 \
                        and abs(px) < stone_w * 0.34:
                    r += 46
                    g += 52
                    b += 58

            # ---- 外圈细环（压在最外层，保证四角不越界）----
            dist = math.sqrt(px * px + py * py)
            ring = abs(dist / (size * 0.415) - 1.0)
            if ring < 0.010:
                w = (1.0 - ring / 0.010) * 0.30
                r += 120 * w
                g += 150 * w
                b += 180 * w

            rows += bytes((_clamp(r), _clamp(g), _clamp(b)))
    return bytes(rows)


def _chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def write_png(path, size, raw):
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)   # 8-bit RGB
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(_chunk(b"IHDR", ihdr))
        f.write(_chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(_chunk(b"IEND", b""))


SET_CONTENTS = """{
  "images" : [
    {
      "filename" : "AppIcon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""

ROOT_CONTENTS = """{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "LingyanAdmin/Resources"
    catalog = os.path.join(root, "Assets.xcassets")
    icon_set = os.path.join(catalog, "AppIcon.appiconset")
    os.makedirs(icon_set, exist_ok=True)

    with open(os.path.join(catalog, "Contents.json"), "w", encoding="utf-8") as f:
        f.write(ROOT_CONTENTS)
    with open(os.path.join(icon_set, "Contents.json"), "w", encoding="utf-8") as f:
        f.write(SET_CONTENTS)

    target = os.path.join(icon_set, "AppIcon-1024.png")
    write_png(target, SIZE, render(SIZE))
    print("wrote %s (%d bytes)" % (target, os.path.getsize(target)))


if __name__ == "__main__":
    main()
