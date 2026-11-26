#!/usr/bin/env python3
"""CI 用：把用户提供的 Logo 重编成 Android 启动器图标。

输入：任意尺寸的 PNG（CI 上 logo_url 下载来的）；输出：5 档 mipmap
ic_launcher.png。做法：Logo 就是完整图标（含底色），按 cover 方式
填满正方形（等比缩放盖满、居中裁切，不拉伸、不加底），再 LANCZOS
缩到各密度。方形图就是原样缩放；透明像素原样保留，不贴底色。

背景色是 Logo 的一部分：不要在这里加底，想换底色就换 Logo 图本身。
默认品牌图标（仓里自带 Logo）不走这个脚本，走
tool/generate_launcher_icons.py（v1 定稿，墨蓝底 #082E63）。

用法（在 apps/flutter_client 下）：
    python3 tool/regen_launcher_icons.py assets/logo/logo.png
依赖：Pillow（pip install pillow）。
"""
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SIZES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}


def cover_square(im: Image.Image, size: int) -> Image.Image:
    """等比缩放盖满 size×size，居中裁切；不拉伸。"""
    w, h = im.size
    scale = max(size / w, size / h)
    nw, nh = round(w * scale), round(h * scale)
    im = im.resize((nw, nh), Image.LANCZOS)
    left = (nw - size) // 2
    top = (nh - size) // 2
    return im.crop((left, top, left + size, top + size))


def main() -> int:
    src = (
        Path(sys.argv[1])
        if len(sys.argv) > 1
        else ROOT / "assets" / "logo" / "logo.png"
    )
    im = Image.open(src)
    # 透明通道原样保留；不透明图转 RGB。
    if im.mode in ("RGBA", "LA", "PA"):
        im = im.convert("RGBA")
    else:
        im = im.convert("RGB")
    res = ROOT / "android" / "app" / "src" / "main" / "res"
    for density, size in SIZES.items():
        out = res / f"mipmap-{density}" / "ic_launcher.png"
        cover_square(im, size).save(out, "PNG")
        print(f"{density}: {size}x{size} -> {out.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
