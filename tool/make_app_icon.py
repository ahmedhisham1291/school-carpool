#!/usr/bin/env python3
"""Draws the default app icon master (1024 x 1024, no alpha) into
tool/ios/AppIcon/icon_1024.png. Run by a developer, not by the build:

    python3 tool/make_app_icon.py          (needs Pillow)

The owner can replace icon_1024.png with a designer's icon instead: a
1024 x 1024 PNG, square corners (iOS rounds them), no transparency.
tool/patch_native.py refuses an icon with the wrong size or with alpha.
Colors: docs/DESIGN.md direction A (teal).
"""

from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent / "ios" / "AppIcon" / "icon_1024.png"
SIZE = 1024
SCALE = 4  # supersampling for smooth edges
TEAL_TOP = (20, 122, 113)
TEAL_BOTTOM = (10, 78, 73)
WHITE = (255, 255, 255)
GLASS = (14, 94, 88)


def main() -> None:
    n = SIZE * SCALE
    image = Image.new("RGB", (n, n), TEAL_BOTTOM)
    draw = ImageDraw.Draw(image)
    for y in range(n):
        t = y / (n - 1)
        draw.line([(0, y), (n, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(TEAL_TOP, TEAL_BOTTOM)))

    def box(x0, y0, x1, y1):
        return [x0 * SCALE, y0 * SCALE, x1 * SCALE, y1 * SCALE]

    # A friendly car seen from the front: cabin, body, lights, wheels.
    draw.rounded_rectangle(box(318, 300, 706, 560), radius=96 * SCALE, fill=WHITE)      # cabin
    draw.rounded_rectangle(box(366, 348, 658, 500), radius=52 * SCALE, fill=GLASS)      # windscreen
    draw.rounded_rectangle(box(232, 468, 792, 700), radius=84 * SCALE, fill=WHITE)      # body
    draw.ellipse(box(292, 540, 380, 628), fill=GLASS)                                  # lights
    draw.ellipse(box(644, 540, 732, 628), fill=GLASS)
    draw.rounded_rectangle(box(440, 566, 584, 602), radius=18 * SCALE, fill=GLASS)      # grille
    draw.rounded_rectangle(box(276, 676, 384, 772), radius=30 * SCALE, fill=WHITE)      # wheels
    draw.rounded_rectangle(box(640, 676, 748, 772), radius=30 * SCALE, fill=WHITE)
    draw.rounded_rectangle(box(232, 640, 792, 700), radius=30 * SCALE, fill=WHITE)      # bumper
    # Two small heads behind the windscreen: children on the school run.
    draw.ellipse(box(424, 404, 492, 472), fill=WHITE)
    draw.ellipse(box(532, 404, 600, 472), fill=WHITE)
    draw.rectangle(box(366, 470, 658, 500), fill=WHITE)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    image.resize((SIZE, SIZE), Image.LANCZOS).save(OUT, "PNG", optimize=True)
    print(f"make_app_icon: wrote {OUT}")


if __name__ == "__main__":
    main()
