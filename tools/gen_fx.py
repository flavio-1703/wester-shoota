"""Generate the character-FX sprites: dust puffs and a muzzle flash.

Same screen-print/riso language as the background — flat fill, ink rim, paper
grain — so the effects sit in the world rather than on top of it. The palette
and the helpers are IMPORTED from gen_background.py rather than copied, so there
is one source for the colours.

    python tools/gen_fx.py

Output goes to assets/fx/generated/. Don't hand-edit it; edit this.
"""

from __future__ import annotations

import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

from gen_background import PALETTE, grain, rgba

OUT = Path("assets/fx/generated")

# Dust off pale sand reads lighter than the ground it came from.
DUST = tuple(int(s * 0.45 + p * 0.55)
             for s, p in zip(PALETTE["sand"], PALETTE["paper"]))
FLASH_CORE = (255, 246, 214)
FLASH_RIM = PALETTE["sun"]


def _ink_then_fill(d, shapes, fill, ink_px):
    """Draw every shape fattened in ink, then the fills inside them.

    Two passes over the whole cluster rather than per-shape, so overlapping
    lobes don't outline each other down the middle of the cloud.
    """
    for kind, args, _ in shapes:
        if kind == "ellipse":
            x, y, rw, rh = args
            d.ellipse([x - rw - ink_px, y - rh - ink_px,
                       x + rw + ink_px, y + rh + ink_px], fill=rgba("ink"))
        else:
            d.polygon([(px, py) for px, py in args], fill=rgba("ink"))
    for kind, args, inset in shapes:
        if kind == "ellipse":
            x, y, rw, rh = args
            d.ellipse([x - rw + inset, y - rh + inset,
                       x + rw - inset, y + rh - inset], fill=fill)
        else:
            cx = sum(p[0] for p in args) / len(args)
            cy = sum(p[1] for p in args) / len(args)
            d.polygon([((px - cx) * 0.86 + cx, (py - cy) * 0.86 + cy)
                       for px, py in args], fill=fill)


def build_puff(size=(128, 104), seed=4):
    """A lobed dust cloud. Asymmetric on purpose — it gets randomly rotated and
    flipped at spawn, and a radially symmetric blob would read as the same
    sprite every time however it was turned."""
    rng = np.random.default_rng(seed)
    img = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    w, h = size
    cx, cy = w * 0.5, h * 0.56

    lobes = []
    for i in range(6):
        ang = (i / 6.0) * math.tau + rng.uniform(-0.35, 0.35)
        dist = rng.uniform(0.16, 0.30) * w
        r = rng.uniform(0.13, 0.21) * w
        lobes.append(("ellipse",
                      (cx + math.cos(ang) * dist, cy + math.sin(ang) * dist * 0.68,
                       r, r * rng.uniform(0.78, 1.0)),
                      3))
    lobes.append(("ellipse", (cx, cy, w * 0.22, h * 0.20), 3))

    _ink_then_fill(d, lobes, (*DUST, 255), ink_px=3)
    return grain(img, amount=4.0, seed=seed)


def build_flash(size=(148, 112), seed=6):
    """A horizontal muzzle burst: spiked star plus a hot core.

    Only ever drawn for clips whose art has NO painted flash — see
    UNPAINTED_FLASH_CLIPS in player.gd — so it has to match the flashes the
    artist painted into shoot[3..6], which are wide, flat and warm.
    """
    img = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    w, h = size
    cx, cy = w * 0.42, h * 0.5

    pts = []
    spikes = 9
    for i in range(spikes * 2):
        ang = (i / (spikes * 2.0)) * math.tau
        long_spike = i % 2 == 0
        rx = (w * 0.46 if long_spike else w * 0.20)
        ry = (h * 0.34 if long_spike else h * 0.17)
        # Squashed horizontally: a muzzle flash points where the barrel does.
        pts.append((cx + math.cos(ang) * rx, cy + math.sin(ang) * ry))

    _ink_then_fill(d, [("poly", pts, 0)], (*FLASH_RIM, 255), ink_px=4)
    d.ellipse([cx - w * 0.17, cy - h * 0.13, cx + w * 0.17, cy + h * 0.13],
              fill=(*FLASH_CORE, 255))
    return grain(img, amount=3.0, seed=seed)


BUILDERS = {"puff": build_puff, "muzzle_flash": build_flash}


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for name, build in BUILDERS.items():
        img = build()
        img.save(OUT / f"{name}.png")
        print("  %-14s %s" % (name, "x".join(str(v) for v in img.size)))
    print(f"\nwrote {len(BUILDERS)} sprites to {OUT}")


if __name__ == "__main__":
    main()
