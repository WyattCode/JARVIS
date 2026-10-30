"""Render the iOS AppIcon variants (light, dark, tinted) from the approved B1 double-coil vector.

Run with a Python that has Pillow:  python3 tools/render_ios_icons.py
The glyph's outer ring is 628px of 1024."""
import json
import re
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SVG = (ROOT / 'design/icon/platform-candidates/coil/foreground.svg').read_text()
OUT = ROOT / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
SIZE = 1024
SS = 4  # supersampling for the glyph masks
RING_DIAMETER = 628  # px: 570 (first iOS icon) * 1.05 * 1.05
UNIT = RING_DIAMETER / (2 * 27 + 1.6)  # px per SVG unit (outer ring incl. its stroke)
CYAN = '#8FDCEB'


def paths():
    for match in re.finditer(r'<path ([^>]*)/>', SVG):
        attrs = dict(re.findall(r'([\w-]+)="([^"]*)"', match.group(1)))
        yield attrs['stroke'].upper(), float(attrs['stroke-width']), attrs['d']


def masks(size=SIZE, ring=RING_DIAMETER):
    """(ink, cyan) coverage masks at size x size (L mode); ring = outer ring diameter in px."""
    n = size * SS
    unit = ring / (2 * 27 + 1.6)
    ink, cyan = Image.new('L', (n, n), 0), Image.new('L', (n, n), 0)
    scale = unit * SS

    def px(x, y):
        return ((x - 54) * scale + n / 2, (y - 54) * scale + n / 2)

    for stroke, width, d in paths():
        draw = ImageDraw.Draw(cyan if stroke == CYAN else ink)
        w = max(1, round(width * scale))
        arc = re.match(r'M([\d.]+),([\d.]+) A([\d.]+),', d)
        if arc:  # a circle centred on (54, 54)
            r = float(arc.group(3)) * scale
            c = n / 2
            draw.ellipse((c - r - w / 2, c - r - w / 2, c + r + w / 2, c + r + w / 2), outline=255, width=w)
            continue
        x1, y1, x2, y2 = (float(v) for v in re.match(r'M([\d.]+),([\d.]+) L([\d.]+),([\d.]+)', d).groups())
        a, b = px(x1, y1), px(x2, y2)
        draw.line((*a, *b), fill=255, width=w)
        for cx, cy in (a, b):  # round caps
            draw.ellipse((cx - w / 2, cy - w / 2, cx + w / 2, cy + w / 2), fill=255)
    down = lambda m: m.resize((size, size), Image.Resampling.LANCZOS)
    return down(ink), down(cyan)


def gradient(top, bottom, diagonal=False, size=SIZE):
    image = Image.new('RGB', (size, size))
    draw = ImageDraw.Draw(image)
    steps = size * (2 if diagonal else 1)
    for i in range(steps):
        t = i / (steps - 1)
        color = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
        if diagonal:
            draw.line((i, 0, i - size, size), fill=color, width=2)
        else:
            draw.line((0, i, size, i), fill=color)
    return image


def paint(base, color, mask, opacity=1.0):
    layer = Image.new('RGB', base.size, color) if isinstance(color, tuple) else color
    m = mask.point(lambda v: round(v * opacity))
    base.paste(layer, (0, 0), m)


def shadow(base, mask, offset, blur, opacity, color=(0, 0, 0)):
    moved = ImageChops.offset(mask, 0, offset).filter(ImageFilter.GaussianBlur(blur))
    paint(base, color, moved, opacity)


def glow(base, mask, blur, opacity, color):
    paint(base, color, mask.filter(ImageFilter.GaussianBlur(blur)), opacity)


def plain(top, bottom, ink_color, cyan_color, ink, cyan):
    image = gradient(top, bottom)
    paint(image, ink_color, ink)
    paint(image, cyan_color, cyan)
    return image


def vivid(ink, cyan):
    """Light appearance: vivid blue plate, white glyph with a soft glow. Scales with the mask size."""
    size = ink.size[0]
    k = size / SIZE
    image = gradient((24, 96, 255), (0, 205, 245), diagonal=True, size=size)
    shadow(image, ink, max(1, round(10 * k)), max(1, round(10 * k)), 0.35, (0, 30, 110))
    paint(image, (255, 255, 255), ink)
    glow(image, cyan, max(1, round(16 * k)), 0.6, (200, 250, 255))
    paint(image, (214, 250, 255), cyan)
    return image


if __name__ == '__main__':
    ink, cyan = masks()
    images = {
        'AppIcon.png': vivid(ink, cyan),
        'AppIcon-Dark.png': plain((36, 36, 38), (8, 8, 10), (236, 248, 252), (143, 220, 235), ink, cyan),
        'AppIcon-Tinted.png': plain((0, 0, 0), (0, 0, 0), (255, 255, 255), (200, 200, 200), ink, cyan),
    }
    for name, image in images.items():
        image.save(OUT / name)

    entry = lambda name, extra=None: {
        **({'appearances': extra} if extra else {}),
        'filename': name, 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024',
    }
    contents = {
        'images': [
            entry('AppIcon.png'),
            entry('AppIcon-Dark.png', [{'appearance': 'luminosity', 'value': 'dark'}]),
            entry('AppIcon-Tinted.png', [{'appearance': 'luminosity', 'value': 'tinted'}]),
        ],
        'info': {'author': 'xcode', 'version': 1},
    }
    (OUT / 'Contents.json').write_text(json.dumps(contents, indent=2) + '\n')
    print('Rendered', ', '.join(images))
