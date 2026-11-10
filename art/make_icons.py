#!/usr/bin/env python3
"""Builds every PhoneCast icon from art/gen/glyph_mask.png (Recraft glyph, white = symbol).
Two states: on (connected: blue→teal) and off (not connected: grey)."""
import os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageChops
HERE = os.path.dirname(os.path.abspath(__file__))
G = Image.open(os.path.join(HERE, 'gen/glyph_mask.png')).convert('L')
OUT = os.path.join(HERE, 'out'); os.makedirs(OUT, exist_ok=True)
STATES = {'on': ((0x2F, 0x6B, 0xF2), (0x12, 0xB5, 0xA6)), 'off': ((0x7A, 0x80, 0x8C), (0x4A, 0x50, 0x5C))}

def gradient(size, a, b):
    w, h = size
    # diagonal: top-left a -> bottom-right b
    m = Image.new('L', size)
    m.putdata([int(255 * (x + y) / max(1, w + h - 2)) for y in range(h) for x in range(w)])
    return Image.composite(Image.new('RGB', size, b), Image.new('RGB', size, a), m)

def glyph(size, frac, alpha=255):
    """White glyph scaled so its larger side is frac*size, centred, as an RGBA layer."""
    s = int(size * frac); gw, gh = G.size; k = s / max(gw, gh)
    g = G.resize((max(1, int(gw * k)), max(1, int(gh * k))), Image.LANCZOS)
    if alpha != 255: g = g.point(lambda v: v * alpha // 255)
    layer = Image.new('RGBA', (size, size), (255, 255, 255, 0))
    layer.putalpha(0)
    m = Image.new('L', (size, size), 0); m.paste(g, ((size - g.width) // 2, (size - g.height) // 2))
    layer = Image.new('RGBA', (size, size), (255, 255, 255, 255)); layer.putalpha(m)
    return layer

def rounded_mask(size, inset, radius):
    m = Image.new('L', (size * 4, size * 4), 0)
    ImageDraw.Draw(m).rounded_rectangle([inset * 4, inset * 4, (size - inset) * 4 - 1, (size - inset) * 4 - 1], radius * 4, fill=255)
    return m.resize((size, size), Image.LANCZOS)

def tile(state, size, inset_frac, radius_frac, glyph_frac, shadow=False):
    """Rounded-square icon (Mac, Windows, legacy Android)."""
    a, b = STATES[state]
    inset = int(size * inset_frac); radius = int((size - 2 * inset) * radius_frac)
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    mask = rounded_mask(size, inset, radius)
    if shadow:
        sh = Image.new('RGBA', (size, size), (0, 0, 0, 0)); sh.putalpha(mask.point(lambda v: v * 90 // 255))
        sh = sh.filter(ImageFilter.GaussianBlur(size * 0.012)); img.alpha_composite(sh, (0, int(size * 0.008)))
    bg = gradient((size, size), a, b).convert('RGBA'); bg.putalpha(mask)
    img.alpha_composite(bg)
    # soft top highlight
    hl = Image.new('RGBA', (size, size), (255, 255, 255, 0))
    hm = Image.linear_gradient('L').transpose(Image.FLIP_TOP_BOTTOM).resize((size, size)).point(lambda v: v * 28 // 255)
    hl.putalpha(ImageChops.multiply(hm, mask)); img.alpha_composite(hl)
    img.alpha_composite(glyph(size, glyph_frac, 255 if state == 'on' else 225))
    return img

def save(img, *path):
    p = os.path.join(OUT, *path); os.makedirs(os.path.dirname(p), exist_ok=True); img.save(p); return p

# ---- Mac (.icns per state; Apple grid: 824 px body on 1024, ~22.5 % corners) ----
for st in STATES:
    big = tile(st, 1024, 100 / 1024, 0.225, 0.50, shadow=True)
    save(big, 'mac', f'icon_{st}_1024.png')
    iconset = os.path.join(OUT, 'mac', f'AppIcon_{st}.iconset'); os.makedirs(iconset, exist_ok=True)
    for s in (16, 32, 128, 256, 512):
        big.resize((s, s), Image.LANCZOS).save(f'{iconset}/icon_{s}x{s}.png')
        big.resize((s * 2, s * 2), Image.LANCZOS).save(f'{iconset}/icon_{s}x{s}@2x.png')
    os.system(f'iconutil -c icns "{iconset}" -o "{OUT}/mac/AppIcon_{st}.icns"')

# ---- Windows .ico per state ----
for st in STATES:
    big = tile(st, 256, 0.03, 0.22, 0.60)
    big.save(os.path.join(OUT, 'windows', f'phonecast_{st}.ico') if os.makedirs(os.path.join(OUT, 'windows'), exist_ok=True) is None else '',
             sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    save(big, 'windows', f'phonecast_{st}_256.png')

# ---- Android ----
dens = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}
for st in STATES:
    a, b = STATES[st]
    for d, k in dens.items():
        n = int(108 * k)   # adaptive layers are 108dp; the safe zone is the middle 66dp
        save(gradient((n, n), a, b), 'android', f'mipmap-{d}', f'ic_launcher_{st}_bg.png')
        save(glyph(n, 0.48, 255 if st == 'on' else 225), 'android', f'mipmap-{d}', f'ic_launcher_{st}_fg.png')
        m = int(48 * k)    # legacy icon for old launchers
        save(tile(st, m, 0.04, 0.24, 0.58), 'android', f'mipmap-{d}', f'ic_launcher_{st}.png')
for d, k in dens.items():
    save(glyph(int(108 * k), 0.48), 'android', f'mipmap-{d}', 'ic_launcher_mono.png')     # themed icons
    save(glyph(int(24 * k), 0.92), 'android', f'drawable-{d}', 'ic_stat_phonecast.png')   # status bar
print('done', OUT)
