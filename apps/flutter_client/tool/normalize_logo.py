#!/usr/bin/env python3
"""CI 用：把 logo_url 下载来的任意常见格式图片转成 PNG。

支持 PNG / JPEG / WebP / BMP / GIF（取首帧）等 Pillow 能打开的格式；
输出一律是 PNG。透明通道保留；调色板/CMYK 先转 RGB/RGBA；动图只取首帧。
打不开就报错退出（构建直接失败，不出包）。

用法（在 apps/flutter_client 下）：
    python3 tool/normalize_logo.py <下载来的文件> assets/logo/logo.png
依赖：Pillow（pip install pillow）。
"""
import sys
from pathlib import Path

from PIL import Image


def main() -> int:
    if len(sys.argv) != 3:
        print("用法：normalize_logo.py <输入图片> <输出 PNG 路径>", file=sys.stderr)
        return 2
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    try:
        with Image.open(src) as im:
            im.load()
            fmt = im.format or "?"
            w, h = im.size
            if im.mode == "P":
                im = im.convert("RGBA" if "transparency" in im.info else "RGB")
            elif im.mode == "CMYK":
                im = im.convert("RGB")
            elif im.mode not in ("RGB", "RGBA", "L", "LA"):
                im = im.convert("RGBA" if "A" in im.getbands() else "RGB")
            im.save(dst, "PNG")
    except Exception as exc:  # noqa: BLE001 - 任何打不开的输入都算失败
        print(
            f"logo 转换失败：{src} 不是可用的图片（{exc}），请检查 logo_url",
            file=sys.stderr,
        )
        return 1
    print(f"Logo 已转成 PNG：{dst}（原格式 {fmt}，{w}x{h}）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
