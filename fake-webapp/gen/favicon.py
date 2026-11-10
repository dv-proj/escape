#!/usr/bin/env python3
"""Deterministic favicon.ico generator (stdlib only).

Usage: favicon.py --seed HEX --name "APP NAME" [--out PATH] [--force]
"""
import argparse
import colorsys
import hashlib
import math
import os
import random
import re
import struct
import sys
import tempfile
import zlib

SIZES = (16, 32, 48)
SEED_RE = re.compile(r"^[0-9a-f]{16,64}$")

_FONT_SRC = """
A 01110 10001 10001 11111 10001 10001 10001
B 11110 10001 10001 11110 10001 10001 11110
C 01110 10001 10000 10000 10000 10001 01110
D 11110 10001 10001 10001 10001 10001 11110
E 11111 10000 10000 11110 10000 10000 11111
F 11111 10000 10000 11110 10000 10000 10000
G 01110 10001 10000 10111 10001 10001 01111
H 10001 10001 10001 11111 10001 10001 10001
I 01110 00100 00100 00100 00100 00100 01110
J 00111 00010 00010 00010 00010 10010 01100
K 10001 10010 10100 11000 10100 10010 10001
L 10000 10000 10000 10000 10000 10000 11111
M 10001 11011 10101 10101 10001 10001 10001
N 10001 11001 10101 10011 10001 10001 10001
O 01110 10001 10001 10001 10001 10001 01110
P 11110 10001 10001 11110 10000 10000 10000
Q 01110 10001 10001 10001 10101 10010 01101
R 11110 10001 10001 11110 10100 10010 10001
S 01111 10000 10000 01110 00001 00001 11110
T 11111 00100 00100 00100 00100 00100 00100
U 10001 10001 10001 10001 10001 10001 01110
V 10001 10001 10001 10001 10001 01010 00100
W 10001 10001 10001 10101 10101 11011 10001
X 10001 10001 01010 00100 01010 10001 10001
Y 10001 10001 01010 00100 00100 00100 00100
Z 11111 00001 00010 00100 01000 10000 11111
0 01110 10001 10011 10101 11001 10001 01110
1 00100 01100 00100 00100 00100 00100 01110
2 01110 10001 00001 00010 00100 01000 11111
3 11110 00001 00001 01110 00001 00001 11110
4 00010 00110 01010 10010 11111 00010 00010
5 11111 10000 11110 00001 00001 10001 01110
6 00110 01000 10000 11110 10001 10001 01110
7 11111 00001 00010 00100 01000 01000 01000
8 01110 10001 10001 01110 10001 10001 01110
9 01110 10001 10001 01111 00001 00010 01100
"""
FONT = {}
for _line in _FONT_SRC.strip().splitlines():
    _p = _line.split()
    FONT[_p[0]] = [[c == "1" for c in row] for row in _p[1:]]


def _lum(c):
    def f(v):
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2])


def _contrast(a, b):
    la, lb = _lum(a), _lum(b)
    if la < lb:
        la, lb = lb, la
    return (la + 0.05) / (lb + 0.05)


def make_style(seed):
    rng = random.Random(hashlib.sha256(("favicon:" + seed).encode()).digest())
    h = rng.random()
    s = rng.uniform(0.5, 0.72)
    l = rng.uniform(0.36, 0.52)
    bg = colorsys.hls_to_rgb(h, l, s)
    white, dark = (1.0, 1.0, 1.0), (0.08, 0.09, 0.11)
    fg = white if _contrast(bg, white) >= _contrast(bg, dark) else dark
    radius = rng.choice([0.5, 0.5, 0.42, 0.34, 0.26, 0.18, 0.08])
    grad = rng.uniform(0.0, 0.14)
    ring = rng.random() < 0.4
    glyph = rng.choice(["diamond", "triangle", "ring", "bars"])
    return {"bg": bg, "fg": fg, "radius": radius, "grad": grad,
            "ring": ring, "glyph": glyph}


def first_char(name):
    m = re.search(r"[A-Za-z0-9]", name)
    return m.group(0).upper() if m else None


def _sdf_box(x, y, half, r):
    qx = abs(x - 0.5) - (half - r)
    qy = abs(y - 0.5) - (half - r)
    return math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - r


def _geo(kind, x, y):
    u, v = x - 0.5, y - 0.5
    if kind == "diamond":
        return abs(u) + abs(v) <= 0.26
    if kind == "triangle":
        return -0.24 <= v <= 0.22 and abs(u) <= (v + 0.24) * 0.5 * 0.96 + 0.0
    if kind == "ring":
        d = math.hypot(u, v)
        return 0.15 <= d <= 0.26
    return (abs(v - -0.14) <= 0.05 or abs(v) <= 0.05 or abs(v - 0.14) <= 0.05) \
        and abs(u) <= 0.24


def render(size, style, ch):
    ss = 8 if size <= 16 else 5 if size <= 32 else 4
    half = 0.5 - 0.5 / size * 0.5 - 0.01
    r = min(style["radius"], half)
    bg, fg = style["bg"], style["fg"]
    # letter placement in unit coordinates
    lh = 0.58
    sc = lh / 7.0
    lw = 5 * sc
    x0, y0 = 0.5 - lw / 2, 0.5 - lh / 2
    glyph = FONT.get(ch) if ch else None
    use_ring = style["ring"] and size >= 32
    raw = bytearray()
    for py in range(size):
        raw.append(0)
        for px in range(size):
            ar = ag = ab = aa = 0.0
            for sy in range(ss):
                y = (py + (sy + 0.5) / ss) / size
                for sx in range(ss):
                    x = (px + (sx + 0.5) / ss) / size
                    d = _sdf_box(x, y, half, r)
                    if d > 0:
                        continue
                    k = 1.0 + style["grad"] * (0.5 - y) * 2 * 0.5
                    c = [min(1.0, v * k) for v in bg]
                    if use_ring and -0.085 < d < -0.06:
                        c = [c[i] * 0.65 + fg[i] * 0.35 for i in range(3)]
                    if glyph:
                        gx, gy = (x - x0) / sc, (y - y0) / sc
                        if 0 <= gx < 5 and 0 <= gy < 7 and glyph[int(gy)][int(gx)]:
                            c = fg
                    elif _geo(style["glyph"], x, y):
                        c = fg
                    ar += c[0]; ag += c[1]; ab += c[2]; aa += 1.0
            if aa == 0:
                raw += b"\x00\x00\x00\x00"
            else:
                n = ss * ss
                raw += bytes((
                    min(255, round(ar / aa * 255)),
                    min(255, round(ag / aa * 255)),
                    min(255, round(ab / aa * 255)),
                    min(255, round(aa / n * 255)),
                ))
    return bytes(raw)


def png_encode(size, raw):
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + \
            struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def build_pngs(seed, name):
    style = make_style(seed)
    ch = first_char(name)
    return [png_encode(s, render(s, style, ch)) for s in SIZES]


def build_ico(pngs):
    n = len(pngs)
    out = bytearray(struct.pack("<HHH", 0, 1, n))
    off = 6 + 16 * n
    for s, p in zip(SIZES, pngs):
        out += struct.pack("<BBBBHHII", s, s, 0, 0, 1, 32, len(p), off)
        off += len(p)
    for p in pngs:
        out += p
    return bytes(out)


def generate(seed, name):
    return build_ico(build_pngs(seed, name))


def atomic_write(path, data):
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(prefix=".favicon-", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main(argv=None):
    ap = argparse.ArgumentParser(description="Generate a deterministic favicon.ico")
    ap.add_argument("--seed", required=True, help="hex seed, 16-64 chars [0-9a-f]")
    ap.add_argument("--name", required=True, help="application name")
    ap.add_argument("--out", help="output path (default: stdout)")
    ap.add_argument("--force", action="store_true", help="overwrite existing --out")
    a = ap.parse_args(argv)
    if not SEED_RE.match(a.seed):
        ap.error("--seed must match ^[0-9a-f]{16,64}$")
    if not a.name.strip():
        ap.error("--name must be non-empty")
    data = generate(a.seed, a.name)
    if a.out is None:
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
        return 0
    if os.path.lexists(a.out) and not a.force:
        print("error: %s exists (use --force)" % a.out, file=sys.stderr)
        return 1
    try:
        atomic_write(a.out, data)
    except OSError as e:
        print("error: %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
