#!/usr/bin/env python3
"""Detect bright-red (#FF0000-ish) pixels in a PNG screenshot.

Part of the drawing e2e (milestone D1+). The draw-app (net.scrcpy.e2edraw)
renders strokes as thick bright-red (#FF0000) anti-aliased lines on a white
canvas. This tool quantifies those red pixels in a screenshot so the harness can
assert (a) standalone: a swipe injected on the emulator produced visible red
along the path, and later (b) display round-trip: the red shape B drew is visible
in A's decoded remote-view screenshot.

A pixel counts as "red" when it is clearly red-dominant:
    R > R_MIN (default 180), G < GB_MAX (default 80), B < GB_MAX (default 80)
This rejects white (R,G,B all high), black, and the anti-aliased pink fringe
while keeping the saturated red core of the stroke.

Usage:
    detect_red.py <png> [crop]
        crop (optional): "x0,y0,x1,y1" — restrict analysis to that box (inclusive
        x0,y0; exclusive x1,y1), e.g. to A's remote-view surface region.

Output (single line, machine-parseable, on stdout):
    red_count=<n> bbox=<minx>,<miny>,<maxx>,<maxy> centroid=<cx>,<cy>
When no red pixel is found:
    red_count=0 bbox=NA centroid=NA

Tunable via env: RED_R_MIN, RED_GB_MAX.
Exit code is always 0 when the image loads (the count IS the result); exits 2 on
a usage / load error so a caller can distinguish "no red" (rc 0, red_count=0)
from "could not analyze" (rc 2).
"""
import os
import sys

try:
    from PIL import Image
except ImportError:
    sys.stderr.write("detect_red.py: Pillow (PIL) not available\n")
    sys.exit(2)


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: detect_red.py <png> [x0,y0,x1,y1]\n")
        return 2
    path = argv[1]
    try:
        img = Image.open(path).convert("RGB")
    except Exception as e:  # noqa: BLE001
        sys.stderr.write("detect_red.py: cannot open %s: %s\n" % (path, e))
        return 2

    w, h = img.size
    x0, y0, x1, y1 = 0, 0, w, h
    if len(argv) >= 3 and argv[2].strip():
        try:
            cx0, cy0, cx1, cy1 = (int(v) for v in argv[2].split(","))
        except ValueError:
            sys.stderr.write("detect_red.py: bad crop '%s' (want x0,y0,x1,y1)\n" % argv[2])
            return 2
        x0 = max(0, min(cx0, w))
        y0 = max(0, min(cy0, h))
        x1 = max(0, min(cx1, w))
        y1 = max(0, min(cy1, h))
        if x1 <= x0 or y1 <= y0:
            sys.stderr.write("detect_red.py: empty crop after clamping\n")
            return 2

    r_min = int(os.environ.get("RED_R_MIN", "180"))
    gb_max = int(os.environ.get("RED_GB_MAX", "80"))

    px = img.load()
    count = 0
    minx = miny = None
    maxx = maxy = None
    sumx = 0
    sumy = 0
    for y in range(y0, y1):
        for x in range(x0, x1):
            r, g, b = px[x, y]
            if r > r_min and g < gb_max and b < gb_max:
                count += 1
                sumx += x
                sumy += y
                if minx is None or x < minx:
                    minx = x
                if maxx is None or x > maxx:
                    maxx = x
                if miny is None or y < miny:
                    miny = y
                if maxy is None or y > maxy:
                    maxy = y

    if count == 0:
        print("red_count=0 bbox=NA centroid=NA")
        return 0
    cx = sumx // count
    cy = sumy // count
    print(
        "red_count=%d bbox=%d,%d,%d,%d centroid=%d,%d"
        % (count, minx, miny, maxx, maxy, cx, cy)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
