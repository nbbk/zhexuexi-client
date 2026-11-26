#!/usr/bin/env python3
"""CI 用：把用户提供的 Logo 重编成 Android 启动器图标。

输入：任意尺寸的 PNG（CI 上 logo_url 下载来的）；输出：5 档 mipmap
ic_launcher.png。做法：Logo 等比缩放（最长边 ≤1400px）、居中贴在
1600×1600 墨蓝底（#082E63）上，再 LANCZOS 缩到各密度。Logo 本身不改色，
只加底；透明像素按底色处理。

与 tool/generate_launcher_icons.py 的区别：那个只认 1600×1600 的 v1
定稿（含白角修复）；这个认任意尺寸的外部 Logo，不做白角填充。

用法（在 apps/flutter_client 下）：
    python3 tool/regen_launcher_icons.py assets/logo/logo.png
依赖：Pillow（pip install pillow）。
"""
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SIZES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
BG = (8, 46, 99)  # 墨蓝 #082E63


def main() -> int:
    src = (
        Path(sys.argv[1])
        if len(sys.argv) > 1
        else ROOT / "assets" / "logo" / "logo.png"
    )
    im = Image.open(src)
    # 透明图先贴到底色上；不透明图直接转 RGB。
    if im.mode in ("RGBA", "LA", "PA"):
        base = Image.new("RGB", im.size, BG)
        base.paste(im, mask=im.split()[-1])
        im = base
    else:
        im = im.convert("RGB")
    # 等比缩放进 1400×1400，居中贴到 1600×1600 墨蓝底上。
    im.thumbnail((1400, 1400), Image.LANCZOS)
    canvas = Image.new("RGB", (1600, 1600), BG)
    canvas.paste(im, ((1600 - im.width) // 2, (1600 - im.height) // 2))
    res = ROOT / "android" / "app" / "src" / "main" / "res"
    for density, size in SIZES.items():
        out = res / f"mipmap-{density}" / "ic_launcher.png"
        canvas.resize((size, size), Image.LANCZOS).save(out, "PNG")
        print(f"{density}: {size}x{size} -> {out.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
