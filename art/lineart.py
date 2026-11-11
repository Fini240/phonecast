"""PhoneCast icon art: vector line drawing of a hand holding a phone (SVG, rendered by headless Chrome).
on  = connected: lit screen with cast waves
off = not connected: dark, sleeping screen
draw(state, size, tall, bg) -> RGBA PIL image (size x size*tall). tall > 1 lets the wrist run on down."""
import os, subprocess, tempfile, math
from PIL import Image

CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
INK = '#1d1d1f'
SCREEN_OFF = '#2c2c2e'
W = 1024
SW = 30   # stroke width on the 1024 grid

def capsule(a, b, r):
    (ax, ay), (bx, by) = a, b
    ang = math.atan2(by - ay, bx - ax); nx, ny = -math.sin(ang) * r, math.cos(ang) * r
    return (f'M{ax+nx:.1f},{ay+ny:.1f} L{bx+nx:.1f},{by+ny:.1f} A{r},{r} 0 0 0 {bx-nx:.1f},{by-ny:.1f} '
            f'L{ax-nx:.1f},{ay-ny:.1f} Z')

def svg(state, tall=1.0, bg=True, zoom=1.0):
    H = W * tall; e = (H - 512) / zoom + 512 - 1080 + 80   # wrist runs on past the canvas bottom
    fingers = [((430, 425), (238, 335), 40), ((430, 510), (226, 474), 43),
               ((430, 598), (233, 578), 41), ((430, 682), (252, 670), 37)]
    finger_paths = ''.join(f'<path d="{capsule(*f)}"/>' for f in fingers)
    palm = (f'M650,332 C650,284 716,272 730,320 C754,422 852,532 854,692 C855,767 830,817 817,862 '
            f'C832,932 902,1012 942,1080 L{942 + e * 0.5:.0f},{1080 + e:.0f} L{702 + e * 0.5:.0f},{1080 + e:.0f} L702,1080 '
            f'C662,1002 612,937 574,902 C674,807 707,642 678,502 C666,432 650,382 650,332 Z')
    if state == 'on':
        screen = f'<rect x="371" y="189" width="272" height="602" rx="40" fill="#f3f4f7" stroke="none"/>'
        cx, cy = 494, 545
        waves = (f'<circle cx="{cx}" cy="{cy}" r="21" fill="{INK}" stroke="none"/>'
                 + ''.join(f'<path d="M{cx - r*0.7071:.1f},{cy - r*0.7071:.1f} A{r},{r} 0 0 1 {cx + r*0.7071:.1f},{cy - r*0.7071:.1f}" '
                           f'fill="none" stroke="{INK}" stroke-width="{SW}" stroke-linecap="round"/>' for r in (72, 128)))
        island = INK
    else:
        screen = f'<rect x="371" y="189" width="272" height="602" rx="40" fill="{SCREEN_OFF}" stroke="none"/>'
        waves = ''; island = '#0a0a0b'
    back = ('<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1">'
            '<stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#e6e7eb"/></linearGradient>'
            '<filter id="s" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#000" flood-opacity="0.10"/></filter></defs>'
            f'<rect width="{W}" height="{H}" fill="url(#g)"/>') if bg else ''
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H:.0f}" viewBox="0 0 {W} {H:.0f}">{back}
<g transform="translate(512 {H/2:.0f}) scale({zoom}) translate(-526 -{H/2:.0f})"{' filter="url(#s)"' if bg else ''} stroke="{INK}" stroke-width="{SW}" stroke-linejoin="round" stroke-linecap="round" fill="#fff">
{finger_paths}
<rect x="340" y="158" width="334" height="664" rx="68"/>
{screen}
<rect x="462" y="206" width="90" height="26" rx="13" fill="{island}" stroke="none"/>
{waves}
<path d="{palm}"/>
</g></svg>'''

def draw(state, size=1024, tall=1.0, bg=True, zoom=1.0):
    h = int(size * tall)
    with tempfile.TemporaryDirectory() as t:
        src = os.path.join(t, 'icon.html'); png = os.path.join(t, 'icon.png')
        body = svg(state, tall, bg, zoom).replace(f'width="{W}" height="{W * tall:.0f}"', f'width="{size}" height="{h}"')
        open(src, 'w').write(f'<html><body style="margin:0;background:transparent">{body}</body></html>')
        subprocess.run([CHROME, '--headless', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
                        f'--window-size={size},{h}', '--default-background-color=00000000',
                        f'--screenshot={png}', 'file://' + src], check=True, capture_output=True)
        return Image.open(png).convert('RGBA').copy()

if __name__ == '__main__':
    import sys
    for st in ('on', 'off'): draw(st).save(f'{sys.argv[1]}/art_{st}.png')
