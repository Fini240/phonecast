#!/usr/bin/env python3
"""Builds every PhoneCast icon from art/src_on.png (screen lit = connected) and
art/src_off.png (screen dark = not connected). Both come from one GPT Image 2 picture via Higgsfield
(art/src_higgsfield.png); make_dark_states.py makes the dark-screen copy so they line up exactly.
Small monochrome glyphs (menu bar, status bar, tiles) are drawn here to match the object."""
import os
from PIL import Image, ImageDraw, ImageFilter, ImageEnhance
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'out'); os.makedirs(OUT, exist_ok=True)

def load(st):
    im = Image.open(os.path.join(HERE, f'src_{st}.png')).convert('RGB')
    return im
SRC = {st: load(st) for st in ('on', 'off')}

def rounded_mask(size, inset, radius):
    m = Image.new('L', (size * 4, size * 4), 0)
    ImageDraw.Draw(m).rounded_rectangle([inset * 4, inset * 4, (size - inset) * 4 - 1, (size - inset) * 4 - 1], radius * 4, fill=255)
    return m.resize((size, size), Image.LANCZOS)

def tile(st, size, inset_frac, radius_frac, shadow=False):
    inset = int(size * inset_frac); body = size - 2 * inset
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    mask = rounded_mask(size, inset, int(body * radius_frac))
    if shadow:
        sh = Image.new('RGBA', (size, size), (0, 0, 0, 0)); sh.putalpha(mask.point(lambda v: v * 110 // 255))
        img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(size * 0.014)), (0, int(size * 0.01)))
    art = Image.new('RGBA', (size, size)); art.paste(SRC[st].resize((body, body), Image.LANCZOS), (inset, inset))
    art.putalpha(mask); img.alpha_composite(art)
    return img

def bleed(st, n, scale=0.62):
    """Full-bleed square for Android adaptive icons: the tile's own charcoal gradient, with the drawing
    scaled into the 66dp safe zone and its edges feathered into it."""
    src = SRC[st]
    # tile gradient, sampled beside the drawing; the rounded-corner rows are replaced by their neighbours
    c = src.crop((150, 0, 151, src.height)); top, bot = c.getpixel((0, 140)), c.getpixel((0, 880))
    for y in range(src.height):
        if y < 140: c.putpixel((0, y), top)
        elif y > 880: c.putpixel((0, y), bot)
    col = c.resize((1, n), Image.LANCZOS).resize((n, n))
    base = col.copy()
    k = int(n * scale); art = src.resize((k, k), Image.LANCZOS)
    feather = Image.new('L', (k, k), 0); e = int(k * 0.09)
    ImageDraw.Draw(feather).rounded_rectangle([e, e, k - e, k - e], radius=k * 0.2, fill=255)
    base.paste(art, ((n - k) // 2, (n - k) // 2), feather.filter(ImageFilter.GaussianBlur(e * 0.5)))
    return base

def glyph(size, lit, pad=0.10):
    """Monochrome phone-on-a-stand: lit = filled screen, not lit = empty screen. White on transparent."""
    S = 8; N = size * S
    m = Image.new('L', (N, N), 0); d = ImageDraw.Draw(m)
    p = N * pad; w = N - 2 * p
    pw, ph = w * 0.46, w * 0.74; x0 = (N - pw) / 2; y0 = p
    t = w * 0.085
    d.rounded_rectangle([x0, y0, x0 + pw, y0 + ph], radius=pw * 0.22, fill=255)
    if lit: d.rounded_rectangle([x0 + t, y0 + t, x0 + pw - t, y0 + ph - t], radius=pw * 0.12, fill=0); \
            d.rounded_rectangle([x0 + t * 1.9, y0 + t * 1.9, x0 + pw - t * 1.9, y0 + ph - t * 1.9], radius=pw * 0.06, fill=255)
    else: d.rounded_rectangle([x0 + t, y0 + t, x0 + pw - t, y0 + ph - t], radius=pw * 0.12, fill=0)
    bw, bh = w * 0.66, w * 0.15; by = y0 + ph + w * 0.04
    d.rounded_rectangle([(N - bw) / 2, by, (N + bw) / 2, by + bh], radius=bh / 2, fill=255)
    out = Image.new('RGBA', (size, size), (255, 255, 255, 255)); out.putalpha(m.resize((size, size), Image.LANCZOS))
    return out

def save(img, *path):
    p = os.path.join(OUT, *path); os.makedirs(os.path.dirname(p), exist_ok=True); img.save(p); return p

# Mac: Apple grid (824 px body on 1024), .icns + Dock images
for st in SRC:
    big = tile(st, 1024, 100 / 1024, 0.225, shadow=True)
    save(big, 'mac', f'icon_{st}_1024.png')
    iconset = os.path.join(OUT, 'mac', f'AppIcon_{st}.iconset'); os.makedirs(iconset, exist_ok=True)
    for s in (16, 32, 128, 256, 512):
        big.resize((s, s), Image.LANCZOS).save(f'{iconset}/icon_{s}x{s}.png')
        big.resize((s * 2, s * 2), Image.LANCZOS).save(f'{iconset}/icon_{s}x{s}@2x.png')
    os.system(f'iconutil -c icns "{iconset}" -o "{OUT}/mac/AppIcon_{st}.icns"')
for s, name in ((16, 'MenuGlyph'), (32, 'MenuGlyph@2x')):
    for lit in (True, False):
        save(glyph(s, lit, pad=0.04), 'mac', f'{name.replace("Glyph", "Glyph" + ("On" if lit else "Off"))}.png')

# Windows .ico
os.makedirs(os.path.join(OUT, 'windows'), exist_ok=True)
for st in SRC:
    big = tile(st, 256, 0.02, 0.2)
    big.save(os.path.join(OUT, 'windows', f'phonecast_{st}.ico'), sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])

# Android: adaptive (art as background, empty foreground), legacy, themed mono, status bar
dens = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}
for d, k in dens.items():
    n = int(108 * k)
    for st in SRC:
        save(bleed(st, n, 0.62), 'android', f'mipmap-{d}', f'ic_launcher_{st}_bg.png')
        save(tile(st, int(48 * k), 0.04, 0.22), 'android', f'mipmap-{d}', f'ic_launcher_{st}.png')
    save(Image.new('RGBA', (n, n), (0, 0, 0, 0)), 'android', f'mipmap-{d}', 'ic_launcher_fg.png')
    lines = bleed('off', n, 0.62).convert('L').point(lambda v: max(0, min(255, (v - 70) * 255 // 150)))   # themed icon = the white outlines
    mono = Image.new('RGBA', (n, n), (255, 255, 255, 255)); mono.putalpha(lines)
    save(mono, 'android', f'mipmap-{d}', 'ic_launcher_mono.png')
    save(glyph(int(24 * k), True), 'android', f'drawable-{d}', 'ic_stat_phonecast.png')
    save(glyph(int(24 * k), False), 'android', f'drawable-{d}', 'ic_stat_phonecast_off.png')
print('done')
