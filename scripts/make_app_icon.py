"""Renders the Artboard 1 clock icon at 1024x1024 (iOS applies the corner mask itself)."""
import math
import sys

from PIL import Image, ImageDraw

SIZE = 1024
SCALE = 4  # supersample for smooth edges
S = SIZE * SCALE


def polar(cx, cy, length, degrees):
    rad = math.radians(degrees - 90)  # 0° = 12 o'clock
    return cx + length * math.cos(rad), cy + length * math.sin(rad)


def main(out_path):
    img = Image.new("RGB", (S, S), "white")
    d = ImageDraw.Draw(img)
    cx = cy = S / 2
    r = S * 0.33
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(64, 64, 64))

    minute_deg, hour_deg = 0, 145  # hands from the artboard: 12 o'clock and ~4:50
    # Shadow wedge between the hands
    tip_m = polar(cx, cy, r * 0.70, minute_deg)
    tip_h = polar(cx, cy, r * 0.62, hour_deg - 12)
    d.polygon([(cx, cy), tip_m, polar(cx, cy, r * 0.30, 22), tip_h], fill=(26, 26, 26))
    width = int(S * 0.018)
    d.line([(cx, cy), polar(cx, cy, r * 0.74, minute_deg)], fill="white", width=width)
    d.line([(cx, cy), polar(cx, cy, r * 0.60, hour_deg - 12)], fill="white", width=width)

    img.resize((SIZE, SIZE), Image.LANCZOS).save(out_path)


if __name__ == "__main__":
    main(sys.argv[1])
