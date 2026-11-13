#!/usr/bin/env python3
"""生成 App 图标 icns。用 PIL 画一张简单的字母图标。"""
import os
import subprocess
import sys
import tempfile

try:
    from PIL import Image, ImageDraw
except ImportError:
    print("  (没有 PIL，跳过图标生成)")
    sys.exit(0)

SIZE = 1024
BG = (28, 30, 34, 255)
FG = (255, 255, 255, 255)
ACCENT = (99, 179, 237, 255)


def make_base() -> Image.Image:
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # 圆角矩形底
    radius = 220
    d.rounded_rectangle([0, 0, SIZE - 1, SIZE - 1], radius=radius, fill=BG)

    # 对话气泡
    bubble = [180, 200, SIZE - 180, SIZE - 320]
    d.rounded_rectangle(bubble, radius=90, fill=FG)
    # 气泡尾巴
    d.polygon(
        [(300, SIZE - 330), (300, SIZE - 200), (430, SIZE - 330)],
        fill=FG,
    )

    # 气泡里的两行字（抽象成横条）
    bar_y = 300
    for i, (x1, x2) in enumerate([(280, 700), (280, 620)]):
        d.rounded_rectangle(
            [x1, bar_y + i * 90, x2, bar_y + i * 90 + 46],
            radius=23,
            fill=ACCENT,
        )

    return img


def main(out_path: str) -> None:
    base = make_base()

    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "icon.iconset")
        os.makedirs(iconset)
        for size in [16, 32, 64, 128, 256, 512]:
            resized = base.resize((size, size), Image.LANCZOS)
            resized.save(os.path.join(iconset, f"icon_{size}x{size}.png"))
            if size != 512:
                double = base.resize((size * 2, size * 2), Image.LANCZOS)
                double.save(os.path.join(iconset, f"icon_{size}x{size}@2x.png"))
        subprocess.run(
            ["iconutil", "-c", "icns", iconset, "-o", out_path],
            check=True,
        )
    print(f"  图标已生成: {out_path}")


if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else "AppIcon.icns"
    main(target)
