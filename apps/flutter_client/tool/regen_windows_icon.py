#!/usr/bin/env python3
"""CI 用：把 Logo 重编成 Windows 应用图标（.ico）。

输入：任意尺寸的 PNG（CI 上 logo_url 下载来的，或仓里自带的
assets/logo/logo.png）；输出：windows/runner/resources/app_icon.ico，
含 16/32/48/256 四档。做法与 Android 启动器图标同路（见
tool/regen_launcher_icons.py）：Logo 就是完整图标（含底色），按 cover
方式填满正方形（等比缩放盖满、居中裁切，不拉伸、不加底），再缩到
各尺寸。方形图就是原样缩放；透明像素原样保留，不贴底色。

背景色是 Logo 的一部分：不要在这里加底，想换底色就换 Logo 图本身。

0.1.19 新增：此前 CI 品牌注入只重编 Android 图标，Windows 的
app_icon.ico 一直是 Flutter 默认 Logo（任务栏与 exe 图标都不对）；
exe 名与窗口标题也一并改品牌（见 windows/CMakeLists.txt 的
BINARY_NAME 与 windows/runner/main.cpp）。

用法（在 apps/flutter_client 下）：
    python3 tool/regen_windows_icon.py assets/logo/logo.png
依赖：Pillow（pip install pillow）。
"""
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ICO_SIZES = [(16, 16), (32, 32), (48, 48), (256, 256)]


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
    out = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"
    cover_square(im, 256).save(out, format="ICO", sizes=ICO_SIZES)
    print(f"ico: 16/32/48/256 -> {out.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
