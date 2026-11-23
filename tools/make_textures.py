#!/usr/bin/env python3
"""
Generates BTH's original procedural texture assets.

All output is our own work (no third-party source), released with the project
under CC0.  The atlas cards are used by the foliage shader; the normal map and
water streak sheets drive the river/waterfall shaders.

Run: python3 tools/make_textures.py
"""
import math
import os
import random

import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from scipy.ndimage import gaussian_filter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "textures", "procedural")


def ensure_dir():
    for sub in ("foliage", "water"):
        os.makedirs(os.path.join(OUT, sub), exist_ok=True)


def conifer_branch(size=512, seed=11):
    rng = random.Random(seed)
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # Central twig.
    d.line([(size * 0.06, size * 0.62), (size * 0.97, size * 0.42)],
           fill=(74, 56, 38, 255), width=7)
    stem_a = np.array([size * 0.06, size * 0.62])
    stem_b = np.array([size * 0.97, size * 0.42])
    # Needle sprays.
    for i in range(700):
        t = rng.random()
        base = stem_a + (stem_b - stem_a) * t
        side = rng.choice([-1, 1])
        length = rng.uniform(0.10, 0.30) * size * (0.55 + 0.45 * (1.0 - t))
        angle = math.radians(rng.uniform(-80, -25) if side < 0 else rng.uniform(25, 80))
        angle += math.atan2(stem_b[1] - stem_a[1], stem_b[0] - stem_a[0])
        end = base + np.array([math.cos(angle), math.sin(angle)]) * length * side
        green = rng.randint(26, 66)
        red = rng.randint(18, 52)
        blue = rng.randint(16, 40)
        alpha = rng.randint(150, 255)
        width = 1 if length < size * 0.15 else 2
        d.line([tuple(base), tuple(end)], fill=(red, green, blue, alpha), width=width)
        # Secondary needlelets give the card a feathered silhouette.
        if length > size * 0.16 and rng.random() < 0.6:
            mid = (base + end) * 0.5
            for _ in range(2):
                a2 = angle + math.radians(rng.uniform(-40, 40))
                end2 = mid + np.array([math.cos(a2), math.sin(a2)]) * length * 0.45 * side
                d.line([tuple(mid), tuple(end2)],
                       fill=(red + 6, green + 10, blue + 4, alpha), width=1)
    return img


def leaf_cluster(size=512, seed=23):
    rng = random.Random(seed)
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cx, cy = size * 0.5, size * 0.56
    d.line([(cx, cy + size * 0.28), (cx + size * 0.04, cy - size * 0.30)],
           fill=(66, 48, 32, 255), width=6)
    for i in range(120):
        ang = rng.uniform(0, math.tau)
        radius = rng.uniform(0.0, 0.40) * size
        px = cx + math.cos(ang) * radius
        py = cy + math.sin(ang) * radius * 0.85
        length = rng.uniform(0.07, 0.14) * size
        width = length * rng.uniform(0.35, 0.55)
        rot = ang + math.radians(rng.uniform(-70, 70))
        pts = []
        for k in range(12):
            a = math.tau * k / 12.0
            rx = math.cos(a) * length * 0.5
            ry = math.sin(a) * width * 0.5
            pts.append((px + rx * math.cos(rot) - ry * math.sin(rot),
                        py + rx * math.sin(rot) + ry * math.cos(rot)))
        r = rng.randint(38, 92)
        g = rng.randint(78, 142)
        b = rng.randint(26, 58)
        shade = rng.uniform(0.8, 1.0)
        d.polygon(pts, fill=(int(r * shade), int(g * shade), int(b * shade), 255))
        # Midrib.
        d.line([(px - math.cos(rot) * length * 0.5, py - math.sin(rot) * length * 0.5),
                (px + math.cos(rot) * length * 0.5, py + math.sin(rot) * length * 0.5)],
               fill=(int(r * 0.6), int(g * 0.65), int(b * 0.6), 190), width=1)
    img = img.filter(ImageFilter.GaussianBlur(0.4))
    return img


def grass_tuft(size=512, seed=37):
    rng = random.Random(seed)
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    base_x = size * 0.5
    for i in range(30):
        lean = rng.uniform(-0.42, 0.42) * size
        height = rng.uniform(0.35, 0.95) * size
        width = rng.uniform(3, 9)
        tip_x = base_x + lean
        ctrl_x = base_x + lean * 0.35
        pts_left, pts_right = [], []
        steps = 14
        for k in range(steps + 1):
            t = k / steps
            x = (1 - t) ** 2 * base_x + 2 * (1 - t) * t * ctrl_x + t ** 2 * tip_x
            y = size - t * height
            w = width * (1.0 - t) ** 0.7
            pts_left.append((x - w, y))
            pts_right.append((x + w, y))
        poly = pts_left + pts_right[::-1]
        shade = rng.uniform(0.65, 1.0)
        r = int(84 * shade + rng.randint(0, 26))
        g = int(112 * shade + rng.randint(10, 44))
        b = int(42 * shade + rng.randint(0, 22))
        d.polygon(poly, fill=(r, g, b, 255))
    return img


def ripple_normal(size=512, seed=5):
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    for scale, amp in ((42.0, 1.0), (16.0, 0.55), (7.0, 0.3)):
        noise = rng.normal(size=(size, size)).astype(np.float32)
        noise = gaussian_filter(noise, scale, mode="wrap")
        noise /= max(np.abs(noise).max(), 1e-5)
        field += noise * amp
    field = gaussian_filter(field, 1.2, mode="wrap")
    gy, gx = np.gradient(field)
    nz = np.ones_like(field) * 2.2
    n = np.dstack([-gx, -gy, nz])
    n /= np.linalg.norm(n, axis=2, keepdims=True)
    rgb = ((n * 0.5 + 0.5) * 255).astype(np.uint8)
    return Image.fromarray(rgb, "RGB")


def water_streaks(size=512, seed=101):
    rng = random.Random(seed)
    arr = np.zeros((size, size), dtype=np.float32)
    for i in range(90):
        x = rng.uniform(0, size)
        width = rng.uniform(2, 26)
        strength = rng.uniform(0.25, 1.0)
        for k in range(size):
            wobble = math.sin(k * rng.uniform(0.01, 0.05) + rng.uniform(0, 6.28)) * rng.uniform(2, 14)
            xx = int((x + wobble) % size)
            half = int(width * 0.5)
            for dx in range(-half, half + 1):
                falloff = 1.0 - abs(dx) / max(half, 1)
                arr[k, (xx + dx) % size] += strength * falloff * 0.25
    arr = gaussian_filter(arr, (7.0, 1.5), mode="wrap")
    arr = np.clip(arr / max(arr.max(), 1e-5), 0, 1)
    arr = (arr * 255).astype(np.uint8)
    img = Image.fromarray(arr, "L").convert("RGB")
    return img


def main():
    ensure_dir()
    conifer_branch().save(os.path.join(OUT, "foliage", "conifer_branch.png"))
    leaf_cluster().save(os.path.join(OUT, "foliage", "leaf_cluster.png"))
    grass_tuft().save(os.path.join(OUT, "foliage", "grass_tuft.png"))
    ripple_normal().save(os.path.join(OUT, "water", "ripple_nrm.png"))
    water_streaks().save(os.path.join(OUT, "water", "water_streak.png"))
    for f in ("foliage/conifer_branch.png", "foliage/leaf_cluster.png",
              "foliage/grass_tuft.png", "water/ripple_nrm.png", "water/water_streak.png"):
        p = os.path.join(OUT, f)
        print(f"{f:36s} {os.path.getsize(p)/1024:7.1f} KB")


if __name__ == "__main__":
    main()
