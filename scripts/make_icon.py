#!/usr/bin/env python3
"""生成 Aevis 的 App 图标，不依赖任何第三方库（纯 zlib 手写 PNG）。

用法:
    python3 scripts/make_icon.py [输出根目录]     默认 Aevis/Resources

会在 <根目录>/Assets.xcassets/AppIcon.appiconset/ 下生成 1024x1024 图标与
两份 Contents.json。CI 里在 xcodegen generate 之前调用。
"""

import math
import os
import struct
import sys
import zlib

SIZE = 1024


def _lerp(a, b, t):
    return a + (b - a) * t


def render(size):
    """渲染一张 size×size 的 RGBA 原始像素（每行前置一个 filter byte）。

    注意：iOS 会把图标裁成圆角方形（squircle），沿对角线方向的可视边界约在
    半径 0.42×边长 处，所以所有装饰元素都要控制在这个半径以内，否则四角会被切掉。
    """
    rows = bytearray()
    center = size / 2.0
    glow_radius = size * 0.33      # 光核
    ring_radius = size * 0.38      # 外环（安全线以内）
    ring_width = 0.020

    for y in range(size):
        rows.append(0)  # PNG filter type: none
        py = y + 0.5 - center
        ny = (y + 0.5) / size
        for x in range(size):
            px = x + 0.5 - center
            nx = (x + 0.5) / size

            # 背景：左上偏紫、右下偏青的柔和渐变
            t = nx * 0.42 + ny * 0.58
            r = _lerp(26, 8, t)
            g = _lerp(18, 32, t)
            b = _lerp(66, 84, t)

            # 中央光核
            d = math.sqrt(px * px + py * py) / glow_radius
            if d < 1.0:
                k = (1.0 - d) ** 1.5
                r += 185 * k
                g += 150 * k
                b += 215 * k

            # 外圈细环
            ring = abs(math.sqrt(px * px + py * py) / ring_radius - 1.0)
            if ring < ring_width:
                w = (1.0 - ring / ring_width) * 0.45
                r += 130 * w
                g += 145 * w
                b += 180 * w

            rows += bytes((
                255 if r > 255 else int(r),
                255 if g > 255 else int(g),
                255 if b > 255 else int(b),
                255,
            ))
    return bytes(rows)


def _chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def write_png(path, size, raw):
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)  # 8-bit RGBA
    with open(path, "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n")
        handle.write(_chunk(b"IHDR", ihdr))
        handle.write(_chunk(b"IDAT", zlib.compress(raw, 9)))
        handle.write(_chunk(b"IEND", b""))


SET_CONTENTS = """{
  "images" : [
    {
      "filename" : "AppIcon1024.png",
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
    root = sys.argv[1] if len(sys.argv) > 1 else "Aevis/Resources"
    catalog = os.path.join(root, "Assets.xcassets")
    icon_set = os.path.join(catalog, "AppIcon.appiconset")
    os.makedirs(icon_set, exist_ok=True)

    target = os.path.join(icon_set, "AppIcon1024.png")
    print("rendering %dx%d icon ..." % (SIZE, SIZE))
    write_png(target, SIZE, render(SIZE))
    print("wrote %s (%d bytes)" % (target, os.path.getsize(target)))

    with open(os.path.join(catalog, "Contents.json"), "w", encoding="utf-8") as handle:
        handle.write(ROOT_CONTENTS)
    with open(os.path.join(icon_set, "Contents.json"), "w", encoding="utf-8") as handle:
        handle.write(SET_CONTENTS)
    print("wrote Contents.json")


if __name__ == "__main__":
    main()
