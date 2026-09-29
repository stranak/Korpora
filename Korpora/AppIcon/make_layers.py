# Generates the Icon Composer layers for the Korpora "Monogram" app icon.
import math, os
OUT = os.path.dirname(os.path.abspath(__file__))
S = 1024/824            # old 824-px icon body -> Icon Composer's full-bleed 1024 canvas
DX = -38                # the monogram's optical-centering shift
def T(x, y): return ((x + DX - 100) * S, (y - 100) * S)

def pill(x0, x1, yc, r=11, n=10):
    pts = []
    for i in range(n + 1):                       # right cap
        a = -math.pi/2 + math.pi*i/n
        pts.append((x1 + r*math.cos(a), yc + r*math.sin(a)))
    for i in range(n + 1):                       # left cap
        a = math.pi/2 + math.pi*i/n
        pts.append((x0 + r*math.cos(a), yc + r*math.sin(a)))
    return pts

def clip(subject, poly):                         # Sutherland–Hodgman, convex clip poly
    def inside(p, a, b): return (b[0]-a[0])*(p[1]-a[1]) - (b[1]-a[1])*(p[0]-a[0]) >= 0
    def inter(p, q, a, b):
        x1,y1=p; x2,y2=q; x3,y3=a; x4,y4=b
        d=(x1-x2)*(y3-y4)-(y1-y2)*(x3-x4)
        t=((x1-x3)*(y3-y4)-(y1-y3)*(x3-x4))/d
        return (x1+t*(x2-x1), y1+t*(y2-y1))
    out = subject
    # orient clip polygon counter-clockwise in SVG coords (y down) for the inside test
    area = sum(poly[i][0]*poly[(i+1)%len(poly)][1]-poly[(i+1)%len(poly)][0]*poly[i][1] for i in range(len(poly)))
    if area < 0: poly = poly[::-1]
    for i in range(len(poly)):
        a, b = poly[i], poly[(i+1) % len(poly)]
        inp, out = out, []
        if not inp: break
        s = inp[-1]
        for e in inp:
            if inside(e, a, b):
                if not inside(s, a, b): out.append(inter(s, e, a, b))
                out.append(e)
            elif inside(s, a, b): out.append(inter(s, e, a, b))
            s = e
    return out

def path(pts):
    q = [T(*p) for p in pts]
    return "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in q) + " Z"

arms = [[(412,610),(412,480),(648,240),(790,240)], [(474,467),(553,394),(800,784),(660,784)]]
dashA = [60,36,30,36,110,36,50,36]; dashB = [100,36,50,36,70,36,40,36]

stem, text = [], []
for k in range(16):
    yc = 240 + 17 + 34*k
    stem.append(path(pill(300+11, 412-11, yc)))
    dash = dashA if k % 2 == 0 else dashB
    x, i = 446, 0
    while x < 900:
        L = dash[i % len(dash)]
        if i % 2 == 0:
            seg = pill(x, min(x+L, 900), yc)
            for poly in arms:
                c = clip(seg, poly)
                if len(c) >= 3: text.append(path(c))
        x += L; i += 1

def svg(name, color, paths):
    body = "\n".join(f'  <path d="{d}"/>' for d in paths)
    open(os.path.join(OUT, name), "w").write(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'
        f'<g fill="{color}">\n{body}\n</g>\n</svg>\n')

svg("stem.svg", "#E9BC62", stem)
svg("arms.svg", "#F3E9D6", text)
# flat preview/fallback with the background, for a pre-Tahoe .icns or a quick look
bg = ('<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#8E2636"/>'
      '<stop offset="1" stop-color="#480E17"/></linearGradient></defs><rect width="1024" height="1024" rx="229" fill="url(#bg)"/>')
open(os.path.join(OUT, "preview.svg"), "w").write(
    '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n' + bg +
    '\n<g fill="#E9BC62">' + "".join(f'<path d="{d}"/>' for d in stem) + '</g>\n<g fill="#F3E9D6">' +
    "".join(f'<path d="{d}"/>' for d in text) + '</g>\n</svg>\n')
print(len(stem), len(text))
