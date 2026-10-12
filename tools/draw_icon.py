"""Draws Veil's app icon. Usage: python3 tools/draw_icon.py out.png"""
from PIL import Image, ImageDraw, ImageFilter, ImageChops
import math, sys
S = 4                     # supersample
W = 1024 * S

def bez(p0, p1, p2, p3, n=200):
    pts = []
    for i in range(n + 1):
        t = i / n
        a = (1-t)**3; b = 3*(1-t)**2*t; c = 3*(1-t)*t**2; d = t**3
        pts.append((a*p0[0]+b*p1[0]+c*p2[0]+d*p3[0], a*p0[1]+b*p1[1]+c*p2[1]+d*p3[1]))
    return pts

def sc(p): return (p[0]*S, p[1]*S)

top_y, hem_y = 250, 846
left_top, right_top = (478, 262), (546, 262)
left_hem, right_hem = (196, hem_y), (828, hem_y)

# Outline: left edge down, scalloped hem, right edge up, rounded crown over the top.
left = bez(left_top, (400, 420), (230, 600), left_hem)
right = bez(right_hem, (794, 600), (624, 420), right_top)
hem = []
scallops = 3
span = (right_hem[0] - left_hem[0]) / scallops
for k in range(scallops):
    x0 = left_hem[0] + k * span
    x1 = x0 + span
    hem += bez((x0, hem_y), (x0 + span*0.3, hem_y + 34), (x1 - span*0.3, hem_y + 34), (x1, hem_y), 60)[1:]
crown = [right_top, left_top]
outline = [sc(p) for p in left + hem + right + crown]

img = Image.new("RGB", (W, W), (0, 0, 0))

# Fabric: white at the top fading to soft gray at the hem.
grad = Image.new("L", (W, W))
gd = ImageDraw.Draw(grad)
for y in range(W):
    t = min(max((y/S - top_y) / (hem_y - top_y), 0), 1)
    # Solid near the top, turning sheer toward the hem.
    sheer = max(0.0, (t - 0.55) / 0.45)
    gd.line([(0, y), (W, y)], fill=int((250 - 40 * t) * (1 - 0.5 * sheer)))
mask = Image.new("L", (W, W), 0)
ImageDraw.Draw(mask).polygon(outline, fill=255)
fabric = Image.merge("RGB", (grad, grad, grad))
img.paste(fabric, (0, 0), mask)

# Folds: soft darker lines fanning out from the crown to the dips of the scallops.
folds = Image.new("L", (W, W), 0)
fd = ImageDraw.Draw(folds)
for k in range(1, 6):
    x_end = left_hem[0] + k * (right_hem[0] - left_hem[0]) / 6
    x_start = 512 + (k - 3) * 9
    pts = bez((x_start, 272), (x_start + (x_end-512)*0.15, 480), (x_end - (x_end-512)*0.1, 680), (x_end, hem_y + 4), 120)
    fd.line([sc(p) for p in pts], fill=255, width=7*S, joint="curve")
folds = folds.filter(ImageFilter.GaussianBlur(7*S))
folds = ImageChops.multiply(folds, mask)
shade = Image.new("RGB", (W, W), (120, 120, 120))
img = Image.composite(shade, img, folds.point(lambda v: int(v * 0.55)))

# Comb: a slim bar the veil hangs from, with a row of small teeth.
d = ImageDraw.Draw(img)
d.rounded_rectangle([sc((428, 236)), sc((596, 262))], radius=13*S, fill=(255, 255, 255))
for i in range(7):
    x = 446 + i * 22
    d.ellipse([sc((x - 5, 222)), sc((x + 5, 232))], fill=(255, 255, 255))

img = img.resize((1024, 1024), Image.LANCZOS)
img.save(sys.argv[1])
