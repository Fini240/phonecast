#!/usr/bin/env python3
"""Turns the chosen Higgsfield icon (art/src_higgsfield.png, screen lit; GPT Image 2 via Higgsfield) into the two PhoneCast
states: src_on.png = as generated (connected, screen gives off a little light), src_off.png = the
same picture with the screen switched off and the light spill on the hand/tile removed.
Both are cropped to the tile (the rounded corners get filled with tile colour; make_icons masks them)."""
import os, numpy as np
from PIL import Image
from scipy import ndimage
HERE = os.path.dirname(os.path.abspath(__file__))
im = np.asarray(Image.open(os.path.join(HERE, 'src_higgsfield.png')).convert('RGB')).astype(float)
L = im.mean(2)

# screen = the bright area inside the bezel around the screen centre, holes (cast symbol, camera pill) filled
box = np.zeros_like(L, bool); box[185:760, 362:662] = True
lit = (L > 90) & box
lab, _ = ndimage.label(lit); screen = lab == lab[600, 500]
screen = ndimage.binary_fill_holes(screen)
soft = ndimage.gaussian_filter(ndimage.binary_dilation(screen, iterations=1).astype(float), 0.8)[..., None]

# tile background per row, sampled from a column far away from the drawing
bg_row = ndimage.median_filter(im[:, 100:130].mean(1), size=(9, 1))          # (H, 3)
bg = np.repeat(bg_row[:, None, :], im.shape[1], 1)

off = im.copy()
# remove the light spill: anything that isn't a white stroke goes back down to the plain tile colour
nonstroke = (L < 150); nonstroke[:130] = False; nonstroke[900:] = False; nonstroke = nonstroke[..., None]   # top rows: corners, keep as is
off = np.where(nonstroke, np.minimum(off, bg + 2), off)
# dark screen with a faint top-to-bottom sheen, camera pill a touch darker
ys = np.linspace(0, 1, im.shape[0])[:, None, None]
xs = np.linspace(0, 1, im.shape[1])[None, :, None]
# glass that is off: a bit lighter than the black bezel so it still reads as a screen, faint diagonal sheen
dark = np.array([40, 41, 46]) * (1.06 - 0.14 * ys) + 10 * np.clip(1 - 2.2 * np.abs((xs + ys) - 0.75), 0, 1) + np.zeros_like(im)
pill = screen & (L < 80); pill[300:] = False
dark[pill] = [8, 8, 9]
off = off * (1 - soft) + dark * soft

def finish(a, name):
    a = np.where((a.mean(2) < 10)[..., None], bg_row[:, None, :] * 0 + [21, 21, 24], a)   # black outside the tile -> tile colour
    a = a[28:977, 40:983]                       # crop to the tile
    Image.fromarray(np.clip(a, 0, 255).astype(np.uint8)).resize((1024, 1024), Image.LANCZOS).save(os.path.join(HERE, name))
finish(im, 'src_on.png'); finish(off, 'src_off.png')
print('screen px', int(screen.sum()))
