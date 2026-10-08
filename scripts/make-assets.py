#!/usr/bin/env python3
"""Generates the reader template's app icons, launch images and fallback cover, and the Settings icon."""
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'app' / 'Resources'
SETTINGS = ROOT / 'settings' / 'Resources'
ORANGE, CREAM, WOOD = (232, 118, 30), (250, 248, 242), (61, 43, 31)


def icon(side):
    scale = 4  # supersample, then downscale for smooth arcs
    s = side * scale
    image = Image.new('RGB', (s, s), ORANGE)
    draw = ImageDraw.Draw(image)
    top = Image.new('RGB', (s, s // 2), (244, 150, 70))
    image.paste(Image.blend(image.crop((0, 0, s, s // 2)), top, 0.5), (0, 0))
    ox, oy, unit = int(s * 0.24), int(s * 0.76), s * 0.13
    for radius in (unit * 3.7, unit * 2.35):
        width = int(unit * 0.8)
        draw.arc([ox - radius, oy - radius, ox + radius, oy + radius], 270, 360, fill='white', width=width)
    dot = unit * 0.65
    draw.ellipse([ox - dot, oy - dot, ox + dot, oy + dot], fill='white')
    return image.resize((side, side), Image.LANCZOS)


def cover(width, height):
    image = Image.new('RGB', (width, height), (40, 40, 40))
    draw = ImageDraw.Draw(image)
    draw.rectangle([0, 0, width, height * 0.21], fill=ORANGE)
    badge = icon(int(width * 0.5))
    image.paste(badge, ((width - badge.width) // 2, int(height * 0.38)))
    return image


def launch(width, height, bar):
    image = Image.new('RGB', (width, height), CREAM)
    ImageDraw.Draw(image).rectangle([0, 0, width, bar], fill=WOOD)
    return image


OUT.mkdir(parents=True, exist_ok=True)
icon(57).save(OUT / 'Icon.png')
icon(114).save(OUT / 'Icon@2x.png')
cover(150, 200).save(OUT / 'Cover.png')
cover(300, 400).save(OUT / 'Cover@2x.png')
launch(320, 460, 44).save(OUT / 'Default.png')
launch(640, 920, 88).save(OUT / 'Default@2x.png')
launch(640, 1096, 88).save(OUT / 'Default-568h@2x.png')
# Settings and app icons come from the Codex-generated artwork when present (art/settings-icon-original.png),
# masked to iOS 6's rounded square; otherwise from the drawn RSS icon.
ART = ROOT / 'art' / 'settings-icon-original.png'


def artwork_icon(side, radius_ratio):
    source = Image.open(ART).convert('RGB')
    inset = int(source.width * 0.012)  # trim the white margin around the drawn frame
    source = source.crop((inset, inset, source.width - inset, source.height - inset))
    big = side * 8
    image = source.resize((big, big), Image.LANCZOS).convert('RGBA')
    mask = Image.new('L', (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, big - 1, big - 1], radius=int(big * radius_ratio), fill=255)
    image.putalpha(mask)
    return image.resize((side, side), Image.LANCZOS)


if ART.exists():
    for side, name, folder in [(29, 'Icon.png', SETTINGS), (58, 'Icon@2x.png', SETTINGS),
                               (57, 'Icon.png', OUT), (114, 'Icon@2x.png', OUT)]:
        artwork_icon(side, 0.2).save(folder / name)
    banner = ROOT / 'art' / 'banner-original.png'
    if banner.exists():
        Image.open(banner).convert('RGB').resize((1280, 640), Image.LANCZOS).save(ROOT / 'art' / 'banner.jpg', quality=88, optimize=True)
else:
    icon(29).save(SETTINGS / 'Icon.png')
    icon(58).save(SETTINGS / 'Icon@2x.png')
print('assets written to', OUT, 'and', SETTINGS)
