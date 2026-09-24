#!/usr/bin/env python3
"""生成 Aevis 的 App 图标组，不依赖任何第三方库（纯 zlib 手写 PNG）。

用法:
    python3 scripts/make_icon.py [输出根目录]     默认 Aevis/Resources

会写出：
    <根目录>/Assets.xcassets/AppIcon.appiconset/            主图标（紫）
    <根目录>/Assets.xcassets/AppIcon-<Color>.appiconset/     备用图标，供用户切换

备用图标配合编译选项 ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS=YES 使用，
运行时靠 UIApplication.setAlternateIconName(_:) 切换。
**注意：iOS 只允许在 App 内置的图标里切换，不能拿相册里的图当桌面图标。**

构图注意：iOS 会把图标裁成圆角方形（squircle），沿对角线方向的可视半径约
0.42×边长，所以装饰元素都要控制在这个半径以内，否则四角会被切掉。
"""

import math
import os
import struct
import sys
import zlib

SIZE = 1024

# (资源名, 中文名, 主色 RGB 0-1)
VARIANTS = [
    ("AppIcon", "紫", (0.42, 0.35, 0.95)),
    ("AppIcon-Blue", "蓝", (0.20, 0.48, 0.96)),
    ("AppIcon-Teal", "青", (0.13, 0.64, 0.58)),
    ("AppIcon-Rose", "玫红", (0.88, 0.32, 0.52)),
    ("AppIcon-Amber", "橙", (0.92, 0.55, 0.18)),
    ("AppIcon-Green", "绿", (0.40, 0.62, 0.20)),
    ("AppIcon-Ink", "墨", (0.34, 0.35, 0.42)),
]


def _lerp(a, b, t):
    return a + (b - a) * t


def render(size, base):
    """渲染一张 size×size 的 RGBA 原始像素（每行前置一个 filter byte）。

    base 是 0-1 的三元组，决定这张图的色相。
    """
    br, bg, bb = base
    rows = bytearray()
    center = size / 2.0
    glow_radius = size * 0.33
    ring_radius = size * 0.38
    ring_width = 0.020

    for y in range(size):
        rows.append(0)  # PNG filter type: none
        py = y + 0.5 - center
        ny = (y + 0.5) / size
        for x in range(size):
            px = x + 0.5 - center
            nx = (x + 0.5) / size

            # 背景：底色压暗后向右下渐变到近似黑
            t = nx * 0.42 + ny * 0.58
            r = _lerp(br * 255 * 0.52, 9, t)
            g = _lerp(bg * 255 * 0.52, 11, t)
            b = _lerp(bb * 255 * 0.52, 18, t)

            dist = math.sqrt(px * px + py * py)

            # 中央光核：底色本身，中心提亮
            d = dist / glow_radius
            if d < 1.0:
                k = (1.0 - d) ** 1.5
                r += (br * 200 + 62) * k
                g += (bg * 200 + 62) * k
                b += (bb * 200 + 62) * k

            # 外圈细环
            ring = abs(dist / ring_radius - 1.0)
            if ring < ring_width:
                w = (1.0 - ring / ring_width) * 0.42
                r += 150 * w
                g += 155 * w
                b += 170 * w

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
      "filename" : "%s",
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
    os.makedirs(catalog, exist_ok=True)

    with open(os.path.join(catalog, "Contents.json"), "w", encoding="utf-8") as handle:
        handle.write(ROOT_CONTENTS)

    for name, label, base in VARIANTS:
        icon_set = os.path.join(catalog, "%s.appiconset" % name)
        os.makedirs(icon_set, exist_ok=True)

        filename = "%s-1024.png" % name
        target = os.path.join(icon_set, filename)
        write_png(target, SIZE, render(SIZE, base))
        print("wrote %s (%s, %d bytes)" % (target, label, os.path.getsize(target)))

        with open(os.path.join(icon_set, "Contents.json"), "w", encoding="utf-8") as handle:
            handle.write(SET_CONTENTS % filename)

    print("done: %d icon variants" % len(VARIANTS))


if __name__ == "__main__":
    main()
