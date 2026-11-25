#!/usr/bin/env python3
"""生成 Android 启动器图标（Logo v1）。

源素材：apps/flutter_client/assets/logo/logo.png（Logo v1 定稿，与仓库根目录
assets/logo.png 是同一文件，sha256 相同；v2 是 assets/logo-v2.png，备选，不用）。

为什么不直接缩放原图：原图是 1600x1600 方形没错，金色主体也有安全边距
（x 21.8%-79.2%、y 26.5%-76.8%），但四角是白色不透明像素（圆角蓝底贴在
白底上），直接缩放会把白角带进启动器图标。本脚本先把近白像素
（min(r,g,b) > 200，只出现在四角及圆角抗锯齿边上，金色 b~98、蓝底 r~7-9
都不会误伤）填成 v1 底色 #082E63（实测底色在 (7-9,46-47,97-99) 之间浮动，
取中值），得到全幅方形不透明底，再用 LANCZOS 缩放到各密度尺寸；系统按需
裁圆角/遮罩，主体不顶边。

为什么不用 SignalPhilosopherPainter 渲染：试过，线条版在启动器尺寸下不可读
——脸部鼻唇处的折线间距小于线宽，缩到 48px 只剩一团金色弯钩，而实心 v1
在小尺寸下仍是清晰的哲人侧脸剪影；线条版留在应用内大开关上用。

运行（在 apps/flutter_client 下）：
    python3 tool/generate_launcher_icons.py
依赖：Pillow（pip install pillow）。
"""
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "assets" / "logo" / "logo.png"
# 密度 -> 边长 (px)，与 Android mipmap 规范一致
SIZES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
FILL = (8, 46, 99)  # v1 底色 #082E63


def main() -> int:
    im = Image.open(SRC).convert("RGB")
    if im.size != (1600, 1600):
        print(f"unexpected source size: {im.size}, abort", file=sys.stderr)
        return 1
    # 白角修复：近白像素 -> 底色
    px = im.load()
    fixed = 0
    for y in range(im.height):
        for x in range(im.width):
            r, g, b = px[x, y]
            if min(r, g, b) > 200:
                px[x, y] = FILL
                fixed += 1
    print(f"repaired {fixed} near-white corner pixels -> #{FILL[0]:02X}{FILL[1]:02X}{FILL[2]:02X}")
    res = ROOT / "android" / "app" / "src" / "main" / "res"
    for density, size in SIZES.items():
        out = res / f"mipmap-{density}" / "ic_launcher.png"
        im.resize((size, size), Image.LANCZOS).save(out, "PNG")
        print(f"{density}: {size}x{size} -> {out.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
