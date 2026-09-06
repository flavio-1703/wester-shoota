"""Generate the parallax background layers for desert_bg.tscn.

The look is taken from `assets/backgrounds/background_reference.png`: a western
comic panel — flat fills, heavy black ink outlines, hard-edged lit facets, print
halftone and paper grain. That style is reproducible procedurally in a way a
painted background is not, which is the only reason this script exists. It is a
very good greybox, not shippable art.

The palette is sampled from the reference, not invented; see PALETTE below.

    python tools/gen_background.py

Then re-check coverage:

    Godot_v4.7.2-stable_win64.exe --path . --script res://tools/check_bg_coverage.gd

Every canvas size and placement here is copied from desert_bg.tscn, where it was
derived from the camera coverage budget. The two are hand-kept in sync, so this
script PRINTS the geometry it used on every run — if what it prints stops
matching the .tscn, a layer has been resized and coverage is no longer verified.
Same guard as slice_player_sheet.py printing the muzzle constants.

--------------------------------------------------------------- the shape rules

Three things separate this from the sine-profile version it replaces, and all
three are what made that one read as lumpy terrain rather than as a drawing:

- **The desert floor is FLAT.** Horizons are dead level to within a few pixels.
  A rolling ground line is the single loudest tell that terrain was generated;
  the reference has none, and neither does any western.
- **Relief is built from explicit faceted forms**, not from a height field.
  Cones and flat-topped buttes are polygons with named peaks, so the lit facets
  and the ridge linework can be drawn FROM the peak. A height field has no peak
  to draw from, which is why the old hatching read as scratches.
- **Depth is carried by value, not by detail.** Each layer's fill is blended
  toward paper by a fixed haze fraction, so the range reads as pale-far to
  saturated-near. Adding linework to separate layers that sit at the same
  lightness does not work; it just adds noise.
"""

from __future__ import annotations

import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

OUT = Path("assets/backgrounds/generated")

# Sampled from background_reference.png. Ink is not pure black in the reference
# but reads as it; a hair of warmth keeps it from looking like a UI stroke.
PALETTE = {
    "paper": (243, 237, 223),
    "paper_warm": (246, 229, 197),
    "sun": (215, 169, 58),
    "cloud": (245, 224, 106),
    "mtn": (150, 125, 160),
    "mtn_light": (198, 152, 168),
    "scrub": (166, 168, 104),
    "scrub_deep": (138, 142, 84),
    "sand": (231, 193, 125),
    "sand_deep": (212, 167, 97),
    "cactus": (108, 127, 72),
    "cactus_rib": (74, 90, 50),
    "rock": (112, 104, 93),
    "rock_light": (154, 145, 131),
    "ink": (26, 22, 20),
}

INK = (*PALETTE["ink"], 255)

# name -> (canvas w, h, local x, y, tiling pitch or None). Mirrors desert_bg.tscn.
#
# WIDTHS ARE LOAD-BEARING and are not touched here: they come from the coverage
# budget in the README (width = V + scroll_scale * (B - V)) and from repeat_size.
# The heights grew upward instead, and every `local y + h` is unchanged at 1600
# / 800 / 1420 — the bottom edge is what check_bg_coverage.gd measures, so
# growing a layer upward for headroom cannot invalidate it.
#
# The headroom is the point: saguaros and buttes stand UP from their ground line,
# and the previous canvases started a few pixels above it, so everything tall was
# guillotined at the top edge of its own texture.
LAYERS = {
    "sky":         (2860, 1600, -120, -200, None),
    "clouds":      (1800,  500,    0,  300, 1800),
    "far_ridge":   (2200, 1250,    0,  350, 2200),
    "mesas":       (2600, 1100,    0,  500, 2600),
    "buttes":      (4080, 1050, -380,  550, None),
    "near_rocks":  (4680, 1100, -480,  500, None),
    "foreground":  (1400,  360,    0, 1060, 1400),
}

# Where each layer's horizon sits in WORLD y. Kept at the values the old layers
# composed at, because the layers scroll vertically at different rates and the
# stacking on screen is a product of those rates — moving a horizon here shifts
# the composition, growing the canvas above it does not.
#
# The gap between `buttes` and `near_rocks` is the one to watch. Those are the
# two inked horizon lines the player actually sees, and at 865/956 the vertical
# parallax landed them ~30px apart on screen — two dead-parallel rules across
# the whole frame, which reads as railway track rather than as distance.
HORIZON = {
    "far_ridge": 905,
    "mesas": 960,
    "buttes": 820,
    "near_rocks": 956,
}


# --------------------------------------------------------------------- helpers


def rgba(name: str, a: int = 255) -> tuple[int, int, int, int]:
    r, g, b = PALETTE[name]
    return (r, g, b, a)


def mix(a, b, t: float) -> tuple[int, int, int, int]:
    """Blend two palette entries. `t` = 0 is all `a`."""
    ca, cb = PALETTE[a], PALETTE[b]
    return (*(int(round(x * (1.0 - t) + y * t)) for x, y in zip(ca, cb)), 255)


def haze(colour, t: float) -> tuple[int, int, int, int]:
    """Blend a colour toward paper — atmospheric perspective.

    This is the whole depth cue. `t` runs 0 (near, full saturation) to ~0.45
    (far, nearly paper), and every layer picks one value and uses it for all of
    its fills, so a layer reads as a single plane rather than as a pile.

    Takes a palette name or an already-mixed rgb(a) tuple.
    """
    c = PALETTE[colour] if isinstance(colour, str) else colour
    p = PALETTE["paper"]
    return (*(int(round(cv * (1.0 - t) + pv * t)) for cv, pv in zip(c[:3], p)), 255)


def canvas_y(layer: str, world_y: float) -> float:
    """World y -> y inside that layer's texture."""
    return world_y - LAYERS[layer][3]


def wrap_x(pitch):
    """Offsets to draw each shape at so it survives the tile boundary.

    PIL clips at the canvas edge, so a shape straddling x=0 or x=pitch would be
    cut in half and the neighbouring copy would start fresh — a hard seam. Drawn
    at -pitch, 0 and +pitch instead, the halves meet. Non-tiling layers get (0,).

    The sine profiles this file used to be built from were seamless by
    construction. Discrete faceted shapes are NOT, so on a tiling layer every
    shape has to go through here and none may be wider than the pitch.
    """
    return (-pitch, 0, pitch) if pitch else (0,)


def clip_to(img: Image.Image, overlay: Image.Image, mask=None) -> None:
    """Composite `overlay` onto `img`, masked by where `mask` is solid.

    Linework and facets are drawn full-bleed and then trimmed to the shape they
    belong to, which is far easier to get right than clipping at draw time.
    `mask` defaults to `img` itself; pass one explicitly when the target is
    already opaque everywhere and the shape to clip against is separate.
    """
    a = np.asarray(img if mask is None else mask)[:, :, 3]
    s = np.asarray(overlay).copy()
    s[:, :, 3] = (s[:, :, 3] * (a > 0)).astype(np.uint8)
    img.alpha_composite(Image.fromarray(s))


def capsule(d, x0, y0, x1, y1, width, col):
    """A round-capped thick line. PIL's line caps are square, which turns a
    saguaro into scaffolding — the caps are the whole reason this exists."""
    d.line([(x0, y0), (x1, y1)], fill=col, width=max(1, int(round(width))))
    r = width / 2.0
    for px, py in ((x0, y0), (x1, y1)):
        d.ellipse([px - r, py - r, px + r, py + r], fill=col)


def draw_group(d, prims, fill, ink_px):
    """Draw a union of primitives twice: fat in ink, then the fill on top.

    Two passes over the WHOLE list rather than shape by shape, so the lobes of a
    cactus or a cloud don't outline each other internally — the group reads as
    one inked object, which is what a comic panel does.

    The ink sits OUTSIDE the fill, not inset. That is correct here and it is the
    reason the silhouettes now read: a mountain against the sky wants a black
    line around it, and every layer below the sky is composited over an opaque
    one, so there is nothing for the line to halo into.
    """
    for pad, col in ((float(ink_px), INK), (0.0, fill)):
        for p in prims:
            kind = p[0]
            if kind == "ellipse":
                _, cx, cy, rx, ry = p
                d.ellipse([cx - rx - pad, cy - ry - pad,
                           cx + rx + pad, cy + ry + pad], fill=col)
            elif kind == "rect":
                _, x0, y0, x1, y1 = p
                d.rectangle([x0 - pad, y0 - pad, x1 + pad, y1 + pad], fill=col)
            elif kind == "capsule":
                _, x0, y0, x1, y1, w = p
                capsule(d, x0, y0, x1, y1, w + 2.0 * pad, col)
            elif kind == "poly":
                pts = list(p[1])
                d.polygon(pts, fill=col)
                if pad > 0.0:
                    d.line(pts + [pts[0]], fill=col,
                           width=max(1, int(round(2.0 * pad))), joint="curve")
            else:
                raise ValueError(f"unknown primitive {kind!r}")


def grain(img, amount=7.0, seed=0):
    """Paper tooth. Applied to RGB only, so cut-out edges stay clean."""
    rng = np.random.default_rng(seed)
    a = np.asarray(img).astype(np.int16)
    noise = rng.normal(0.0, amount, a.shape[:2])[:, :, None]
    a[:, :, :3] = np.clip(a[:, :, :3] + noise, 0, 255)
    return Image.fromarray(a.astype(np.uint8))


def halftone(img, spacing, radius, colour="ink", alpha=26, y0=None, y1=None,
             grow=False, mask=None):
    """A print dot screen, clipped to the shape.

    On a hexagonal lattice rather than a square one: an axis-aligned grid beats
    against the pixel grid and crawls when the layer scrolls. The dot radius
    fades from full at y0 to nothing at y1 (or the reverse, with `grow`), which
    is how the reference grades a flat fill without a gradient — and it is the
    only way to darken the bottom of the sand without ruling another hard line
    across the frame.
    """
    w, h = img.size
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    y0 = 0.0 if y0 is None else float(y0)
    y1 = float(h) if y1 is None else float(y1)
    lo, hi = (y0, y1) if y0 <= y1 else (y1, y0)

    row = 0
    y = lo
    step = spacing * 0.866
    while y < hi:
        t = (y - y0) / (y1 - y0) if y1 != y0 else 0.0
        r = radius * (t if grow else 1.0 - t)
        if r > 0.35:
            x = (row % 2) * spacing * 0.5
            while x < w + spacing:
                d.ellipse([x - r, y - r, x + r, y + r], fill=(*PALETTE[colour], alpha))
                x += spacing
        y += step
        row += 1

    clip_to(img, layer, mask)


def stamp(img, box, render):
    """Render into a local tile and composite it in.

    Anything drawn by `render` after the silhouette can be clipped to that
    silhouette's alpha, which is how crack lines and lit facets stay INSIDE the
    rock they belong to. Drawn straight onto the layer they overhang the outline
    and read as whiskers.
    """
    x0, y0, x1, y1 = (int(round(v)) for v in box)
    tw, th = max(1, x1 - x0), max(1, y1 - y0)
    tile = Image.new("RGBA", (tw, th), (0, 0, 0, 0))
    render(tile, x0, y0)

    # alpha_composite refuses a negative destination, and shapes legitimately
    # hang off every edge — the tiling layers draw each shape at -pitch. Crop
    # the tile to the overlap instead; no overlap means nothing to draw.
    W, H = img.size
    cx0, cy0 = max(0, -x0), max(0, -y0)
    cx1, cy1 = min(tw, W - x0), min(th, H - y0)
    if cx1 <= cx0 or cy1 <= cy0:
        return
    if (cx0, cy0, cx1, cy1) != (0, 0, tw, th):
        tile = tile.crop((cx0, cy0, cx1, cy1))
    img.alpha_composite(tile, (x0 + cx0, y0 + cy0))


def oval_poly(cx, cy, rx, ry, angle, n=30):
    """A rotated ellipse as a polygon. PIL cannot draw one, and an unrotatable
    ellipse is why the prickly pears came out as a bunch of grapes — real pads
    are flat paddles fanned out at angles."""
    ca, sa = math.cos(angle), math.sin(angle)
    out = []
    for t in np.linspace(0.0, 2.0 * math.pi, n, endpoint=False):
        px, py = rx * math.cos(t), ry * math.sin(t)
        out.append((cx + px * ca - py * sa, cy + px * sa + py * ca))
    return out


# ------------------------------------------------------------- terrain shapes


def cone_points(px, base_y, height, half_l, half_r, seed, flare=1.42, facets=5):
    """The skyline of one mountain, base-left over the peak to base-right.

    `flare` > 1 makes the flanks concave — steep at the peak, splaying out at
    the base — which is the silhouette of every volcanic cone in the reference.
    A straight-sided triangle (`flare` 1.0) reads as a road sign and `flare`
    below 1 reads as a hill, so this is the one number that decides whether it
    looks western. Keep it near 1.4: past about 1.7 the curve goes flat around
    the summit and the mountain turns into a dome.

    The facet joints are jittered a little so the two flanks aren't mirror
    images, but the jitter is a small fraction of the span: enough to look drawn,
    far too little to reintroduce the lumpiness this replaced.
    """
    rng = np.random.default_rng(seed)

    def flank(half, sign):
        # One flank carries a shoulder — a short step back up to a secondary
        # summit. A ridge with exactly one apex and two smooth flanks is a tent
        # however good its proportions are; the sub-peak is what makes it a
        # mountain, and it is the cheapest single thing in this file.
        shoulder = int(rng.integers(1, facets - 1)) if facets > 3 else -1
        out = []
        for i in range(facets, 0, -1):
            t = i / facets
            x = px + sign * half * t
            y = base_y - height * (1.0 - t ** flare)
            if i < facets:
                x += sign * rng.uniform(-0.05, 0.05) * half
                y += rng.uniform(-0.055, 0.055) * height
            out.append((x, y))
            if i == shoulder:
                out.append((x - sign * half * rng.uniform(0.05, 0.12),
                            y - height * rng.uniform(0.03, 0.09)))
                out.append((x - sign * half * rng.uniform(0.13, 0.20),
                            y + height * rng.uniform(0.01, 0.05)))
        return out

    # The summit is a short irregular cap, not a needle. A single apex point is
    # the other half of the tent, and it is what every lit facet and erosion
    # stroke gets struck from — so blunting it here blunts all of them.
    cap = [(px - half_l * 0.05, base_y - height * rng.uniform(0.90, 0.97)),
           (px, base_y - height),
           (px + half_r * 0.06, base_y - height * rng.uniform(0.89, 0.98))]

    return flank(half_l, -1) + cap + flank(half_r, 1)[::-1]


def butte_points(px, base_y, height, half_w, seed):
    """A flat-topped mesa: talus skirt, near-vertical cliff, level cap.

    The cap is the whole read. A butte whose top is not level is a hill, and the
    level line against a level horizon is what makes a desert look like one.
    """
    rng = np.random.default_rng(seed)
    cap = half_w * rng.uniform(0.48, 0.62)
    skirt = height * rng.uniform(0.22, 0.34)
    lip = height * rng.uniform(0.86, 0.92)
    top = base_y - height

    return [
        (px - half_w, base_y),
        (px - half_w * rng.uniform(0.74, 0.82), base_y - skirt),
        (px - cap * rng.uniform(1.04, 1.14), base_y - lip),
        (px - cap, top),
        (px + cap, top),
        (px + cap * rng.uniform(1.04, 1.14), base_y - lip),
        (px + half_w * rng.uniform(0.74, 0.82), base_y - skirt),
        (px + half_w, base_y),
    ]


def relief(size, offsets, skyline, px, base_y, height, fill, lit, seed,
           ink_px=5, wedges=3, ridges=10, lit_side=1):
    """One landform as its own RGBA tile: silhouette, lit facets, ridge lines.

    Built in isolation and composited, rather than drawn straight into the
    layer, so the facets and linework can be masked to THIS shape's alpha. The
    version this replaces derived its lit faces from the FINISHED layer's alpha
    via argmax down each column — which returns row 0 for an empty column, so
    every silhouette edge became a fake slope and grew a wedge that belonged to
    nothing.

    The wedges radiate from the peak to the base line and the ridge lines run
    the same way, because that is what the reference draws: light and erosion
    both come off the summit.
    """
    w, h = size
    tile = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(tile)
    rng = np.random.default_rng(seed)

    # Silhouette. Extended past the bottom of the canvas so the layer in front
    # covers the base rather than a hard edge landing mid-frame.
    for dx in offsets:
        pts = [(x + dx, y) for x, y in skyline]
        poly = pts + [(pts[-1][0], h + 40.0), (pts[0][0], h + 40.0)]
        draw_group(d, [("poly", poly)], fill, ink_px)

    facet = Image.new("RGBA", size, (0, 0, 0, 0))
    fd = ImageDraw.Draw(facet)

    for dx in offsets:
        pts = [(x + dx, y) for x, y in skyline]
        top = min(range(len(pts)), key=lambda i: pts[i][1])
        peak = pts[top]

        # The lit face is bounded by the REAL skyline on its outer edge, not by
        # a ray struck from the summit. That is the whole difference between a
        # mountain and a circus tent: a triangle pasted from the apex to the
        # base has a straight outer edge that ignores the silhouette, and every
        # such triangle in the frame points at the same spot.
        flank = pts[top:] if lit_side > 0 else pts[:top + 1][::-1]
        flank = flank[: max(2, int(len(flank) * 0.66))]
        span = abs(pts[-1][0] - peak[0]) if lit_side > 0 else abs(peak[0] - pts[0][0])
        if len(flank) >= 2:
            # The inner edge is kinked rather than a single ray to the base. A
            # straight split from the summit to the foot halves the mountain
            # into two flat panels, which is a pyramid however good the outline
            # is — the kink is what keeps it reading as one lumpy solid.
            mid = (peak[0] + lit_side * span * rng.uniform(0.04, 0.17),
                   peak[1] + height * rng.uniform(0.45, 0.68))
            inner = peak[0] + lit_side * span * rng.uniform(0.12, 0.30)
            fd.polygon(flank + [(flank[-1][0], base_y + 4.0),
                                (inner, base_y + 4.0), mid], fill=lit)

        # A couple of shadow creases cut back OUT of that face. Irregular
        # widths, struck from points near — not on — the summit, so they don't
        # all converge on one pixel.
        for k in range(max(1, wedges - 1)):
            a = 0.18 + (0.62 / max(1, wedges - 1)) * (k + rng.uniform(0.0, 0.45))
            b = a + rng.uniform(0.07, 0.17)
            apex = (peak[0] + rng.uniform(-0.05, 0.05) * height,
                    peak[1] + rng.uniform(0.02, 0.13) * height)
            fd.polygon([apex,
                        (peak[0] + lit_side * span * a, base_y + 4.0),
                        (peak[0] + lit_side * span * b, base_y + 4.0)], fill=fill)

        # Erosion strokes HANG OFF THE SKYLINE and stay short — a third of the
        # flank at most. Run them to the base instead and they become the spokes
        # of the same umbrella the facets were.
        for _ in range(ridges):
            i = int(rng.integers(1, max(2, len(pts) - 1)))
            sx, sy = pts[i]
            if sy > base_y - height * 0.12:
                continue
            length = height * rng.uniform(0.16, 0.38)
            lean = 0.42 * (1.0 if sx >= peak[0] else -1.0) * rng.uniform(0.6, 1.3)
            fd.line([(sx, sy), (sx + lean * length, sy + length)],
                    fill=(*PALETTE["ink"], 46), width=2)

    clip_to(tile, facet)
    return tile


def ground_plane(img, y_top, colour, ink_px, amp=0.0, seed=0, pitch=None):
    """The desert floor: a level horizon with an inked top edge.

    `amp` is deliberately tiny (single-digit pixels) or zero. The reference's
    floor is dead flat, and a visibly undulating one is the loudest possible
    signal that the terrain was generated rather than drawn.
    """
    w, h = img.size
    if amp <= 0.0:
        xs = np.array([-8.0, w + 8.0])
        ys = np.array([y_top, y_top])
    else:
        rng = np.random.default_rng(seed)
        n = 220
        xs = np.linspace(-8.0, w + 8.0, n)
        if pitch:
            # Seamless: integer-frequency sines close on themselves exactly.
            t = np.linspace(0.0, 2.0 * math.pi, n)
            ys = np.zeros(n)
            for freq, a in ((1, 1.0), (3, 0.45), (7, 0.2)):
                ys += a * np.sin(freq * t + rng.uniform(0.0, 2.0 * math.pi))
            ys = y_top + ys / np.abs(ys).max() * amp
        else:
            raw = rng.normal(0.0, 1.0, n)
            k = np.ones(31) / 31.0
            sm = np.convolve(raw, k, mode="same")
            ys = y_top + sm / max(1e-6, np.abs(sm).max()) * amp

    d = ImageDraw.Draw(img)
    pts = [(float(x), float(y)) for x, y in zip(xs, ys)]
    d.polygon(pts + [(w + 8.0, h + 8.0), (-8.0, h + 8.0)], fill=colour)
    if ink_px > 0:
        d.line(pts, fill=INK, width=ink_px, joint="curve")
    return lambda x: float(np.interp(x, xs, ys))


# ------------------------------------------------------------- desert objects


def saguaro(d, x, base_y, height, arms, colour, ink_px=None):
    """Trunk plus elbowed arms, all round-capped, inked as one silhouette.

    Trunk width is a fraction of HEIGHT, not an absolute scale. Sizing it
    absolutely made every cactus a 16px stick at 200px tall, which read as
    scaffolding rather than as a saguaro however good the caps were.
    """
    trunk_w = height * 0.125
    arm_w = height * 0.096
    # Ink weight is capped, not purely proportional: a 320px saguaro with a
    # proportional 8px outline reads as a sticker pasted on the frame rather
    # than as ink on paper. Everything on the near layer wants the same weight.
    ink_px = min(5.5, max(3.0, height * 0.020)) if ink_px is None else ink_px

    prims = [("capsule", x, base_y, x, base_y - height, trunk_w)]
    for side, at, alen, reach in arms:
        ay = base_y - height * at
        ax = x + side * height * reach
        prims.append(("capsule", x, ay, ax, ay, arm_w))
        prims.append(("capsule", ax, ay, ax, ay - height * alen, arm_w))
    draw_group(d, prims, colour, ink_px)

    # Ribs. Skipped on the far layers, where the trunk is too narrow to hold
    # them and they just muddy the fill.
    if trunk_w >= 15.0:
        for off in (-0.26, 0.0, 0.26):
            rx = x + off * trunk_w
            d.line([(rx, base_y - trunk_w * 0.35),
                    (rx, base_y - height + trunk_w * 0.7)],
                   fill=(*PALETTE["cactus_rib"], 130), width=2)


def prickly_pear(d, x, base_y, scale, colour, seed, ink_px=4):
    """Flat paddles fanning up from a base pad, inked as one silhouette.

    Pads are TALLER than they are wide and each one is tilted. Round pads
    stacked in a heap — the first pass — read as a bunch of grapes; the tilt and
    the flattening are the entire difference between that and an opuntia.
    """
    rng = np.random.default_rng(seed)
    prims = []
    pads = []

    # The root pad sits ON the ground and the rest fan UP and OUT from it.
    # Growing them radially in every direction — and small — turned the plant
    # into a three-leaf clover; an opuntia is a stack that climbs.
    rh0 = rng.uniform(46, 58) * scale
    pads.append((x, base_y - rh0 * 0.92, rh0 * 0.56, rh0, rng.uniform(-0.18, 0.18)))
    for _ in range(int(rng.integers(3, 7))):
        parent = pads[int(rng.integers(0, len(pads)))]
        ang = parent[4] + rng.choice([-1.0, 1.0]) * rng.uniform(0.45, 1.0)
        ang = max(-1.25, min(1.25, ang))
        rh = parent[3] * rng.uniform(0.66, 0.94)
        rw = rh * rng.uniform(0.50, 0.62)
        px = parent[0] + math.sin(ang) * parent[3] * 0.95
        py = parent[1] - math.cos(ang) * parent[3] * 0.95
        pads.append((px, py, rw, rh, ang))

    for px, py, rw, rh, ang in pads:
        prims.append(("poly", oval_poly(px, py, rw, rh, ang)))
    draw_group(d, prims, colour, ink_px)

    for px, py, rw, rh, ang in pads:
        for _ in range(int(rng.integers(3, 6))):
            t = rng.uniform(0.0, 2.0 * math.pi)
            ca, sa = math.cos(ang), math.sin(ang)
            ex, ey = rw * math.cos(t) * 0.72, rh * math.sin(t) * 0.72
            sx, sy = px + ex * ca - ey * sa, py + ex * sa + ey * ca
            d.line([(sx, sy), (sx + rng.uniform(-5, 5) * scale,
                               sy - rng.uniform(3, 7) * scale)],
                   fill=(*PALETTE["cactus_rib"], 175), width=2)


def boulder(img, x, base_y, w, h, colour, lit, seed, ink_px=5):
    """An angular rock with one flat lit facet and a few cracks.

    Angular, not domed: an outline built from a half-ellipse with jittered
    radii is a pebble at any size. The reference's rocks are faceted slabs with
    straight edges and a hard highlight along the top plane.

    Drawn through `stamp` so the facet and the cracks are clipped to the
    silhouette. Drawn straight onto the layer they overshoot the outline, which
    put a scattering of loose diagonal ticks around every rock.
    """
    rng = np.random.default_rng(seed)
    pad = ink_px + 6

    def render(tile, ox, oy):
        d = ImageDraw.Draw(tile)
        cx, cy = x - ox, base_y - oy

        n = int(rng.integers(4, 7))
        pts = []
        for i in range(n):
            t = i / (n - 1)
            ang = math.pi * t
            pts.append((cx - math.cos(ang) * w * rng.uniform(0.78, 1.0),
                        cy - math.sin(ang) * h * rng.uniform(0.50, 1.0)))
        poly = [(cx - w, cy + 10.0)] + pts + [(cx + w, cy + 10.0)]
        draw_group(d, [("poly", poly)], colour, ink_px)

        det = Image.new("RGBA", tile.size, (0, 0, 0, 0))
        dd = ImageDraw.Draw(det)

        # Top facet: the sunward half of the outline closed back on a chord.
        top = pts[: max(2, n // 2 + 1)]
        if len(top) >= 2:
            chord = [(px + w * 0.14, py + h * 0.38) for px, py in reversed(top)]
            dd.polygon(top + chord, fill=lit)

        for _ in range(int(rng.integers(2, 5))):
            i = int(rng.integers(0, len(pts)))
            sx, sy = pts[i]
            dd.line([(sx, sy + h * 0.10), (sx + w * 0.14, sy + h * 0.55)],
                    fill=(*PALETTE["ink"], 70), width=2)

        clip_to(tile, det)

    stamp(img, (x - w - pad, base_y - h - pad, x + w + pad, base_y + 12 + pad),
          render)


def scrub_bush(d, x, base_y, scale, colour, seed):
    """A low tuft: a squashed lobed blob plus a few blades poking out."""
    rng = np.random.default_rng(seed)
    prims = []
    for i in range(int(rng.integers(3, 6))):
        px = x + rng.uniform(-1.0, 1.0) * 22 * scale
        py = base_y - rng.uniform(2, 14) * scale
        prims.append(("ellipse", px, py, rng.uniform(13, 22) * scale,
                      rng.uniform(8, 14) * scale))
    draw_group(d, prims, colour, max(2.0, 3.0 * scale))
    for _ in range(int(rng.integers(3, 7))):
        bx = x + rng.uniform(-1.0, 1.0) * 24 * scale
        d.line([(bx, base_y), (bx + rng.uniform(-8, 8) * scale,
                               base_y - rng.uniform(16, 30) * scale)],
               fill=(*PALETTE["ink"], 150), width=2)


def ground_marks(img, y_top, y_bot, seed, density=1.0, wisps=0):
    """The ink shorthand for sand: dashes, pebble ticks, dot clusters, tufts.

    Everything is HORIZONTAL and gets longer and sparser toward the bottom of
    the band. That gradient is the only perspective cue a flat plane has — marks
    at a constant size read as wallpaper, which is what the old uniform speckle
    did.
    """
    w, h = img.size
    rng = np.random.default_rng(seed)
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    span = max(1.0, y_bot - y_top)

    for _ in range(int(2200 * density * w / 4680)):
        x = rng.uniform(0, w)
        t = rng.random() ** 0.65
        y = y_top + t * span
        near = 0.35 + t
        if rng.random() < 0.62:
            run = rng.uniform(10, 46) * near
            dip = rng.uniform(-2.0, 2.0) * near
            d.line([(x, y), (x + run * 0.5, y + dip), (x + run, y)],
                   fill=(*PALETTE["ink"], 78), width=max(1, int(1.6 * near)))
        else:
            r = rng.uniform(1.4, 2.9) * near
            d.ellipse([x - r, y - r, x + r, y + r], fill=(*PALETTE["ink"], 78))

    # Pebbles: a filled tick with a shadow dash under it.
    for _ in range(int(90 * density * w / 4680)):
        x = rng.uniform(0, w)
        t = rng.random() ** 0.5
        y = y_top + t * span
        near = 0.4 + t
        rw, rh = rng.uniform(5, 13) * near, rng.uniform(3, 7) * near
        d.ellipse([x - rw, y - rh, x + rw, y], fill=rgba("rock", 205))
        d.line([(x - rw, y + 1), (x + rw * 1.5, y + 1)],
               fill=(*PALETTE["ink"], 90), width=2)

    # Grass tufts: blades fanning up from one point. Kept faint and small — at
    # four heavy blades apiece they stopped reading as grass and became a field
    # of little arrows.
    for _ in range(int(130 * density * w / 4680)):
        x = rng.uniform(0, w)
        t = rng.random() ** 0.5
        y = y_top + t * span
        near = 0.35 + t * 0.8
        for _ in range(int(rng.integers(2, 5))):
            d.line([(x + rng.uniform(-3, 3), y),
                    (x + rng.uniform(-9, 9) * near,
                     y - rng.uniform(8, 20) * near)],
                   fill=(*PALETTE["ink"], 85), width=2)

    # Dust devils: thin rising S-curves, straight off the reference.
    for _ in range(wisps):
        x = rng.uniform(0, w)
        y = y_top + rng.uniform(0.15, 0.7) * span
        pts = [(x, y)]
        for k in range(1, 9):
            pts.append((x + math.sin(k * 0.9 + rng.uniform(0, 1)) * 11 * (1 + k * 0.1),
                        y - k * rng.uniform(11, 19)))
        d.line(pts, fill=(*PALETTE["ink"], 95), width=2, joint="curve")

    clip_to(img, layer)


# ---------------------------------------------------------------------- layers


def build_sky():
    w, h, _, _, _ = LAYERS["sky"]
    top = np.array(PALETTE["paper"], dtype=float)
    bot = np.array(PALETTE["paper_warm"], dtype=float)
    t = np.linspace(0.0, 1.0, h)[:, None] ** 1.5
    a = (top[None, None, :] * (1 - t[:, :, None]) + bot[None, None, :] * t[:, :, None])
    img = Image.fromarray(
        np.dstack([np.repeat(a, w, axis=1).astype(np.uint8),
                   np.full((h, w), 255, np.uint8)])
    )

    # Sun: a flat disc with a heavy ink rim, sat low so the ridges cut its
    # bottom. Canvas coords = local - layer origin, so local (900, 530) is
    # (1020, 730). It is the one element the whole composition hangs on, so it
    # is large and it does not move — scroll_scale.x is 0 on this layer.
    d = ImageDraw.Draw(img)
    cx, cy, r = 1020, 730, 380
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=INK)
    d.ellipse([cx - r + 9, cy - r + 9, cx + r - 9, cy + r - 9], fill=rgba("sun"))

    # Halftone inside the disc only, fading downward — the print texture in the
    # reference, and it keeps 760px of flat ochre from reading as a UI element.
    #
    # The sky is opaque everywhere, so the dots need a separate mask to clip
    # against. Painting them onto a white scratch disc and filtering the result
    # by brightness does NOT work: ink at alpha 44 over white lands around 216,
    # so any threshold that keeps the dots keeps the disc too, and any threshold
    # that drops the disc drops the dots. That silently produced no sun texture
    # at all.
    mask = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(mask).ellipse([cx - r + 9, cy - r + 9, cx + r - 9, cy + r - 9],
                                 fill=(0, 0, 0, 255))
    halftone(img, spacing=16, radius=5.2, colour="ink", alpha=46,
             y0=cy - r, y1=cy + r * 0.9, mask=mask)

    return grain(img, amount=8.0, seed=1)


def build_clouds():
    w, h, _, ly, pitch = LAYERS["clouds"]
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    rng = np.random.default_rng(7)
    ink = 4

    # Cumulus banks first, so the flat bands read as passing IN FRONT of them —
    # that overlap is what the reference uses to stack the sky in depth.
    #
    # Flat-bottomed: the lobes are circles whose centres sit above a shared
    # baseline, unioned with a slab that ends exactly on it. A cloud with a
    # round bottom is a cartoon sheep; the reference's all sit on a line.
    for base_y in (int(canvas_y("clouds", 690)), int(canvas_y("clouds", 745))):
        x = rng.uniform(0, 700)
        while x < w:
            lobes = []
            n = int(rng.integers(4, 8))
            step = rng.uniform(58, 86)
            for i in range(n):
                lr = rng.uniform(42, 82) * (1.0 - 0.42 * abs(i - (n - 1) / 2) / n)
                lobes.append((x + i * step, base_y - lr * 0.72, lr))
            x0 = lobes[0][0] - lobes[0][2]
            x1 = lobes[-1][0] + lobes[-1][2]
            for dx in wrap_x(pitch):
                prims = [("ellipse", lx + dx, ly_, lr, lr) for lx, ly_, lr in lobes]
                prims.append(("rect", x0 + dx, base_y - 40, x1 + dx, base_y))
                draw_group(d, prims, rgba("cloud"), ink)
            x += (x1 - x0) + rng.uniform(200, 520)

    # Flat bands. Long, level, rounded ends, at fixed heights — the reference
    # stacks them like ruled lines and runs them straight across the sun.
    #
    # The body and BOTH end caps go through one draw_group call. Drawing the
    # caps separately inks each one against the body it sits on, which puts a
    # black circle inside the band and turns every streak into a length of pipe.
    for y, th in ((int(canvas_y("clouds", 520)), 22),
                  (int(canvas_y("clouds", 588)), 32),
                  (int(canvas_y("clouds", 664)), 17),
                  (int(canvas_y("clouds", 742)), 28)):
        x = -rng.uniform(0, 500)
        while x < w:
            run = rng.uniform(420, 1050)
            r = th * 0.5
            for dx in wrap_x(pitch):
                draw_group(d, [
                    ("rect", x + dx + r, y, x + dx + run - r, y + th),
                    ("ellipse", x + dx + r, y + r, r, r),
                    ("ellipse", x + dx + run - r, y + r, r, r),
                ], rgba("cloud"), ink)
            x += run + rng.uniform(420, 900)

    return img


def build_far_ridge():
    name = "far_ridge"
    w, h, _, _, pitch = LAYERS[name]
    base = canvas_y(name, HORIZON[name])
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    offsets = wrap_x(pitch)

    fill = haze("mtn", 0.40)
    lit = haze(mix("mtn_light", "mtn", 0.42), 0.40)

    # Back to front: the low shoulders first, then the hero cone OVER them, and
    # deliberately overlapping. Isolated cones spaced evenly across the layer
    # read as a row of tents no matter what is drawn on their faces; a range
    # reads as a range because the silhouettes interlock.
    #
    # The base:height ratio is the other half of it. These run about 4:1, which
    # is what the reference's volcano measures — at 2.5:1 they are pyramids.
    shoulders = [
        (330, 155, 460, 510),
        (760, 205, 500, 430),
        (1640, 175, 460, 530),
        (2010, 132, 385, 345),
    ]
    for i, (px, ht, hl, hr) in enumerate(shoulders):
        pts = cone_points(px, base, ht, hl, hr, seed=40 + i, flare=1.58, facets=4)
        img.alpha_composite(relief((w, h), offsets, pts, px, base, ht,
                                   fill, lit, seed=40 + i, ink_px=4,
                                   wedges=2, ridges=6))

    px, ht, hl, hr = 1150, 295, 760, 840
    pts = cone_points(px, base, ht, hl, hr, seed=3, flare=1.56, facets=7)
    img.alpha_composite(relief((w, h), offsets, pts, px, base, ht,
                               fill, lit, seed=3, ink_px=5, wedges=3, ridges=11))

    halftone(img, spacing=19, radius=3.6, alpha=22,
             y0=base - 30, y1=base - ht * 0.9)
    return grain(img, amount=5.0, seed=3)


def build_mesas():
    name = "mesas"
    w, h, _, _, pitch = LAYERS[name]
    base = canvas_y(name, HORIZON[name])
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    offsets = wrap_x(pitch)

    fill = haze("mtn", 0.16)
    lit = haze(mix("mtn_light", "mtn", 0.42), 0.16)

    # Nearer than far_ridge, so: lower, darker, and mixed forms. Flat-topped
    # buttes among the cones is what stops the two purple layers reading as one
    # smudge — silhouette variety carries as far as value does.
    #
    # Grouped into two massifs with a long gap, not spread evenly. Even spacing
    # is the same tell as evenly scattered cacti, and it is more obvious here
    # because these are the largest shapes in the frame.
    forms = [
        ("cone", 300, 185, 460, 415, 50),
        ("butte", 690, 215, 245, 51),
        ("cone", 1010, 230, 560, 500, 52),
        ("butte", 1390, 140, 195, 53),
        ("cone", 2120, 180, 430, 470, 54),
        ("butte", 2400, 118, 165, 55),
    ]
    for f in forms:
        if f[0] == "cone":
            _, px, ht, hl, hr, sd = f
            pts = cone_points(px, base, ht, hl, hr, seed=sd, flare=1.58, facets=6)
            ridges = 9
        else:
            _, px, ht, hw, sd = f
            pts = butte_points(px, base, ht, hw, seed=sd)
            ridges = 6
        img.alpha_composite(relief((w, h), offsets, pts, px, base, f[2],
                                   fill, lit, seed=sd, ink_px=5,
                                   wedges=3, ridges=ridges))

    halftone(img, spacing=17, radius=3.4, alpha=24, y0=base - 20, y1=base - 200)
    return grain(img, amount=5.0, seed=5)


def build_buttes():
    name = "buttes"
    w, h, _, _, _ = LAYERS[name]
    base = canvas_y(name, HORIZON[name])
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    rng = np.random.default_rng(9)

    rock_fill = haze("mtn", 0.06)
    rock_lit = haze(mix("mtn_light", "mtn", 0.42), 0.06)

    # Buttes stand behind the scrub line, so they are drawn first and the ground
    # plane crops their bases.
    for i, (px, ht, hw) in enumerate([
        (180, 210, 220), (900, 150, 175), (1520, 250, 245),
        (2340, 130, 150), (3010, 195, 205), (3780, 165, 185),
    ]):
        pts = butte_points(px, base, ht, hw, seed=60 + i)
        img.alpha_composite(relief((w, h), (0,), pts, px, base, ht,
                                   rock_fill, rock_lit, seed=60 + i,
                                   ink_px=4, wedges=2, ridges=5))

    # The scrub strip, then the sand under it. The strip is thin on purpose:
    # widen it and it stops reading as vegetation at the foot of the range and
    # starts reading as a green field.
    #
    # Only the TOP edge is inked. The horizon is one line; a second ruled line
    # 30px under it, dead parallel across all 4080px, reads as railway track,
    # and there is already a third one on the near layer below. The scrub/sand
    # boundary is carried by the colour step and by bushes straddling it.
    ground_plane(img, base, haze("scrub", 0.18), ink_px=4)
    ground_plane(img, base + 30, haze("sand", 0.22), ink_px=0, amp=5, seed=91)

    d = ImageDraw.Draw(img)
    for _ in range(20):
        x = rng.uniform(0, w)
        scrub_bush(d, x, base + rng.uniform(2, 26), rng.uniform(0.45, 0.75),
                   haze("scrub_deep", 0.16), seed=int(rng.integers(0, 10_000)))

    # Distant saguaros. Small, but not the 46px hairs the old layer drew — at
    # this scroll scale anything under ~90px vanishes into the grain. Sparse,
    # for the same reason the near layer is: this band is 4080px of a level the
    # player runs the whole length of.
    for _ in range(13):
        x = rng.uniform(0, w)
        arms = [(1, 0.56, 0.26, 0.20)]
        if rng.random() < 0.5:
            arms.append((-1, 0.70, 0.20, 0.18))
        saguaro(d, x, base + rng.uniform(0, 22), rng.uniform(90, 140),
                arms, haze("cactus", 0.20), ink_px=3)

    ground_marks(img, base + 52, h - 10, seed=9, density=0.55)
    halftone(img, spacing=15, radius=3.0, alpha=18, y0=base + 50, y1=h)
    return grain(img, amount=5.0, seed=9)


def build_near_rocks():
    name = "near_rocks"
    w, h, _, _, _ = LAYERS[name]
    base = canvas_y(name, HORIZON[name])
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    rng = np.random.default_rng(11)

    # The big flat plain. In the reference the sand is ~40% of the frame and it
    # is the largest single value in the picture; letting it be that big is what
    # makes everything above it read as distance.
    ground_plane(img, base, rgba("sand"), ink_px=5)

    d = ImageDraw.Draw(img)

    # Saguaros in CLUSTERS with one dominant stem, not scattered evenly. Even
    # scatter is the other generated-terrain tell; the reference groups them and
    # leaves long empty runs of sand between the groups.
    #
    # The gaps are as authored as the groups. This layer scrolls at 0.8, one
    # step behind the play plane, so a cactus every few hundred pixels becomes a
    # picket fence across the whole level — the first pass did exactly that and
    # buried the mountains behind it. Roughly one group per screen width.
    x = rng.uniform(200, 700)
    while x < w - 200:
        n = int(rng.integers(1, 4))
        lead = rng.uniform(215, 320)
        for i in range(n):
            hx = x + rng.uniform(-24, 24) + i * rng.uniform(78, 140)
            ht = lead * rng.uniform(0.40, 0.80) if i else lead
            # Arm count varies, including none. Every stem carrying exactly one
            # arm at the same height made a row of identical stencils, which is
            # the same failure as the evenly spaced mountains one layer back.
            roll = rng.random()
            arms = []
            if roll > 0.22:
                arms.append((1 if rng.random() < 0.5 else -1,
                             rng.uniform(0.40, 0.66), rng.uniform(0.22, 0.40),
                             rng.uniform(0.16, 0.30)))
            if roll > 0.62:
                arms.append((-arms[0][0], rng.uniform(0.58, 0.80),
                             rng.uniform(0.16, 0.32), rng.uniform(0.15, 0.26)))
            if roll > 0.90:
                arms.append((arms[0][0], rng.uniform(0.24, 0.36),
                             rng.uniform(0.22, 0.34), rng.uniform(0.22, 0.34)))
            saguaro(d, hx, base + rng.uniform(6, 46), ht, arms, rgba("cactus"))
        x += rng.uniform(1500, 2400)

    for _ in range(9):
        prickly_pear(d, rng.uniform(0, w), base + rng.uniform(40, 150),
                     rng.uniform(0.75, 1.1), rgba("cactus"),
                     seed=int(rng.integers(0, 10_000)))

    for _ in range(11):
        bx = rng.uniform(0, w)
        boulder(img, bx, base + rng.uniform(60, 260),
                rng.uniform(55, 130), rng.uniform(34, 78),
                rgba("rock"), rgba("rock_light"),
                seed=int(rng.integers(0, 10_000)))

    ground_marks(img, base + 14, h - 20, seed=11, density=1.0, wisps=5)

    # Ink screen for texture, then a second screen in the deeper sand that GROWS
    # toward the bottom of the layer. That gradient replaces the flat darker
    # band this used to have: the band's top edge was a fourth dead-level line
    # ruled across the frame, and three was already one too many.
    halftone(img, spacing=19, radius=2.4, alpha=15, y0=base + 10, y1=h)
    halftone(img, spacing=13, radius=5.4, colour="sand_deep", alpha=255,
             y0=base + 150, y1=h, grow=True)
    return grain(img, amount=5.0, seed=11)


def build_foreground():
    w, h, _, _, pitch = LAYERS["foreground"]
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    rng = np.random.default_rng(13)

    # This layer draws OVER the player, so it is a bottom fringe and nothing
    # else: everything is anchored below the frame and only the top of each
    # shape is ever seen. Dark, because a foreground element in a comic is the
    # heaviest value on the page — that contrast is what gives the frame depth.
    dark_rock = tuple(int(v * 0.72) for v in PALETTE["rock"]) + (255,)
    dark_cactus = tuple(int(v * 0.70) for v in PALETTE["cactus"]) + (255,)

    for _ in range(8):
        x = rng.uniform(0, w)
        by = h + rng.uniform(30, 90)
        rw, rh = rng.uniform(120, 235), rng.uniform(90, 170)
        sd = int(rng.integers(0, 10_000))
        for dx in wrap_x(pitch):
            boulder(img, x + dx, by, rw, rh, dark_rock,
                    tuple(int(v * 0.8) for v in PALETTE["rock_light"]) + (255,),
                    seed=sd, ink_px=6)
    for _ in range(6):
        x = rng.uniform(0, w)
        by = h + rng.uniform(10, 60)
        sd = int(rng.integers(0, 10_000))
        for dx in wrap_x(pitch):
            prickly_pear(d, x + dx, by, 1.25, dark_cactus, seed=sd, ink_px=5)

    return grain(img, amount=4.0, seed=13)


BUILDERS = {
    "sky": build_sky,
    "clouds": build_clouds,
    "far_ridge": build_far_ridge,
    "mesas": build_mesas,
    "buttes": build_buttes,
    "near_rocks": build_near_rocks,
    "foreground": build_foreground,
}


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    print("Layer geometry used (must match desert_bg.tscn):")
    print("  %-12s %-12s %-14s %-14s %s" % (
        "layer", "canvas", "local pos", "bottom edge", "repeat pitch"))
    for name, build in BUILDERS.items():
        w, h, lx, ly, pitch = LAYERS[name]
        img = build()
        assert img.size == (w, h), f"{name}: built {img.size}, spec {(w, h)}"
        if pitch is not None:
            assert pitch == w, f"{name}: repeat pitch {pitch} != width {w} — seam"
        img.save(OUT / f"{name}.png")
        print("  %-12s %-12s %-14s %-14s %s" % (
            name, f"{w}x{h}", f"({lx}, {ly})", f"y={ly + h}",
            pitch if pitch else "fixed width"))
    print(f"\nwrote {len(BUILDERS)} layers to {OUT}")
    print("re-check coverage: check_bg_coverage.gd (bottom edges must not move)")


if __name__ == "__main__":
    main()
