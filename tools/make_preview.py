#!/usr/bin/env python3
"""Builds preview.png, the 1600x900 marketplace card, in the style of the
author's other cards: icon tile, two-line name, tagline and feature line on
the left, a real screenshot on the right.

The text block sits high on purpose: the marketplace's mini-preview tile crops
the bottom 10-20% of the card.

Run from the repo root:  python3 tools/make_preview.py  (needs docs/window.png)
"""
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1600, 900
SUNSET = [(236, 72, 200), (168, 85, 247), (45, 212, 220)]
WHITE = (238, 236, 240)
DIM = (156, 150, 160)
FAINT = (112, 106, 118)
FONT = "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-{}.ttf"


def font(size, weight="Regular"):
    return ImageFont.truetype(FONT.format(weight), size)


def background():
    bg = Image.new("RGB", (W, H))
    px = bg.load()
    for y in range(H):
        for x in range(W):
            t = x / W * 0.55 + y / H * 0.45
            # a violet-black, lighter toward the top left
            px[x, y] = (max(int(32 - 20 * t), 9), max(int(26 - 16 * t), 8), max(int(38 - 22 * t), 11))
    return bg


def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.width - 1, img.height - 1], radius, fill=255)
    out = Image.new("RGBA", img.size)
    out.paste(img, (0, 0), mask)
    return out


def icon(size=104):
    """The bar widget itself, large: a room of lights in two rows."""
    s = 4
    big = Image.new("RGBA", (size * s, size * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    d.rounded_rectangle([0, 0, size * s - 1, size * s - 1], 26 * s, fill=(24, 22, 30, 255),
                        outline=(255, 255, 255, 30), width=2 * s)
    glow = Image.new("RGBA", big.size, (0, 0, 0, 0))
    g = ImageDraw.Draw(glow)
    dots = [(0.3, 0.38, 0), (0.5, 0.38, 1), (0.7, 0.38, 2), (0.4, 0.62, 2), (0.6, 0.62, 0)]
    for x, y, c in dots:
        r = 0.11 * size * s
        g.ellipse([x * size * s - r * 1.6, y * size * s - r * 1.6, x * size * s + r * 1.6, y * size * s + r * 1.6],
                  fill=SUNSET[c] + (150,))
    big.alpha_composite(glow.filter(ImageFilter.GaussianBlur(9 * s)))
    d = ImageDraw.Draw(big)
    for x, y, c in dots:
        r = 0.075 * size * s
        d.ellipse([x * size * s - r, y * size * s - r, x * size * s + r, y * size * s + r], fill=SUNSET[c] + (255,))
    return big.resize((size, size), Image.LANCZOS)


def main():
    card = background().convert("RGBA")

    win = Image.open("docs/window.png").convert("RGB")
    ww = 880
    wh = round(win.height * ww / win.width)
    win = rounded(win.resize((ww, wh), Image.LANCZOS), 22)
    wx, wy = W - ww - 60, 96
    shadow = Image.new("RGBA", (ww + 120, wh + 120), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([60, 70, ww + 60, wh + 70], 26, fill=(0, 0, 0, 160))
    card.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(28)), (wx - 60, wy - 60))
    card.alpha_composite(win, (wx, wy))
    ImageDraw.Draw(card).rounded_rectangle([wx, wy, wx + ww - 1, wy + wh - 1], 22, outline=(255, 255, 255, 46), width=2)

    card.alpha_composite(icon(), (92, 74))

    d = ImageDraw.Draw(card)
    x = 98
    d.text((x - 4, 196), "Psy", font=font(108, "Bold"), fill=WHITE)
    # "wall" in the sunset palette, letter by letter
    cx = x - 4
    for k, ch in enumerate("wall"):
        d.text((cx, 300), ch, font=font(108, "Bold"), fill=SUNSET[min(2, k * 2 // 3)])
        cx += d.textlength(ch, font=font(108, "Bold"))
    y = 448
    for line in ("Your wallpaper and", "your Hue lights, moving", "to the music."):
        d.text((x, y), line, font=font(34), fill=DIM)
        y += 45
    y += 16
    for line in ("pair · place · beat", "glow · dynamic"):
        d.text((x, y), line, font=font(27), fill=FAINT)
        y += 36
    card.convert("RGB").save("preview.png", optimize=True)
    print("preview.png", card.size, "text ends at y =", y, f"({y / H:.0%} of the height)")


if __name__ == "__main__":
    main()
