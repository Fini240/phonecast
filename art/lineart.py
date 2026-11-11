"""PhoneCast icon art, drawn in code: black line drawing of a hand holding a phone, on white.
on  = connected: cast waves on the screen
off = not connected: empty screen, lines a shade lighter."""
from PIL import Image, ImageDraw

W = 1024          # design grid
S = 4             # supersample
INK_ON, INK_OFF, PAPER = (17, 17, 17), (95, 95, 95), (255, 255, 255)
LW = 34           # line width on the design grid

def bez(p0, p1, p2, p3, n=40):
    return [tuple(((1-t)**3*a + 3*(1-t)**2*t*b + 3*(1-t)*t**2*c + t**3*d) for a, b, c, d in zip(p0, p1, p2, p3))
            for t in (i / n for i in range(n + 1))]

def path(start, *segs):
    """segs: ('L', p) or ('C', c1, c2, p)"""
    pts = [start]; cur = start
    for s in segs:
        if s[0] == 'L': pts.append(s[1]); cur = s[1]
        else: pts += bez(cur, s[1], s[2], s[3])[1:]; cur = s[3]
    return pts

def rrect(x0, y0, x1, y1, r, n=12):
    import math
    pts = []
    for cx, cy, a0 in ((x1 - r, y0 + r, -90), (x1 - r, y1 - r, 0), (x0 + r, y1 - r, 90), (x0 + r, y0 + r, 180)):
        for i in range(n + 1):
            a = math.radians(a0 + 90 * i / n); pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts

def draw(state, size=1024, paper=PAPER, ink=None, transparent=False, tall=1.0):
    """tall > 1 makes the canvas taller and lets the wrist run on down to its bottom edge."""
    ink = ink or (INK_ON if state == 'on' else INK_OFF)
    N = W * S
    bg = (0, 0, 0, 0) if transparent else paper + (255,)
    H = int(N * tall); im = Image.new('RGBA', (N, H), bg); d = ImageDraw.Draw(im)
    fillc = paper + (255,)
    k = lambda pts: [(x * S, y * S) for x, y in pts]
    lw = LW * S

    def shape(pts, closed=True):
        """outline in ink, inside filled with paper so later shapes hide what's behind them"""
        P = k(pts)
        if closed: P = P + [P[0]]
        d.line(P, fill=ink, width=lw)
        for x, y in P: d.ellipse([x - lw / 2, y - lw / 2, x + lw / 2, y + lw / 2], fill=ink)
        if closed: d.polygon(P, fill=fillc if not transparent else (0, 0, 0, 0))

    def capsule(a, b, r):
        import math
        (ax, ay), (bx, by) = a, b
        ang = math.atan2(by - ay, bx - ax); nx, ny = -math.sin(ang), math.cos(ang)
        pts = []
        for cx, cy, a0 in ((bx, by, ang - math.pi / 2), (ax, ay, ang + math.pi / 2)):
            for i in range(17):
                t = a0 + math.pi * i / 16; pts.append((cx + r * math.cos(t), cy + r * math.sin(t)))
        shape(pts)

    # fingers behind the phone (left edge), index finger longest and steepest
    capsule((300, 420), (205, 345), 40)
    capsule((330, 505), (225, 475), 42)
    capsule((330, 600), (232, 580), 41)
    capsule((330, 690), (248, 675), 38)
    # phone
    shape(rrect(305, 150, 665, 845, 62))
    # speaker slot
    d.line(k([(440, 215), (530, 215)]), fill=ink, width=lw)
    for x in (440, 530): d.ellipse([x * S - lw / 2, 215 * S - lw / 2, x * S + lw / 2, 215 * S + lw / 2], fill=ink)
    e = W * tall - 1080 + 60   # how far the wrist runs on past the design grid
    # palm + thumb in front, wrapping the right edge, wrist leaving the bottom
    shape(path((640, 330),
               ('C', (640, 285), (700, 275), (712, 318)),
               ('C', (735, 430), (835, 540), (835, 690)),
               ('C', (835, 770), (805, 820), (800, 860)),
               ('C', (810, 920), (880, 1000), (920, 1080)), ('L', (920 + e / 2, 1080 + e)), ('L', (690 + e / 2, 1080 + e)), ('L', (690, 1080)),
               ('C', (650, 1000), (600, 930), (560, 895)),
               ('C', (660, 800), (690, 640), (660, 500)),
               ('C', (648, 430), (640, 380), (640, 330))))
    if state == 'on':   # cast waves: dot + two arcs, centred on the screen
        cx, cy = 470, 560
        r0 = 26; d.ellipse([(cx - r0) * S, (cy - r0) * S, (cx + r0) * S, (cy + r0) * S], fill=ink)
        for r in (95, 165):
            R = r + LW / 2   # PIL draws the arc width inward from the box
            d.arc([(cx - R) * S, (cy - R) * S, (cx + R) * S, (cy + R) * S], 225, 315, fill=ink, width=lw)
            import math
            for a in (225, 315):
                x = cx + r * math.cos(math.radians(a)); y = cy + r * math.sin(math.radians(a))
                d.ellipse([(x * S) - lw / 2, (y * S) - lw / 2, (x * S) + lw / 2, (y * S) + lw / 2], fill=ink)
    return im.resize((size, int(size * tall)), Image.LANCZOS)

if __name__ == '__main__':
    import sys
    for st in ('on', 'off'): draw(st).save(f'{sys.argv[1]}/art_{st}.png')
