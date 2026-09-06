"""Slice assets/characters/player_spritesheet_2.png into a uniform animation grid.

The source is a presentation sheet: labels painted into it, frames on no grid,
and neighbouring frames whose limbs overlap in x. What saves it is the alpha
channel — the art is already cut out, and the painted gradient lives only in the
RGB channels, so no colour keying is needed. `player_spritesheet_2.png` looks
like it has a background only because a viewer composites the RGB over
something; alpha is effectively binary.

Frames are therefore lifted as connected components rather than sliced at x
cuts. That matters: run[1] spans x191-347 and run[2] spans x338-502, so any
vertical cut between them severs somebody's boot. Taking each figure as a
component separates them exactly, whatever they overlap.

Output is `player_frames.png`: one uniform CELL_W x CELL_H cell per frame, rows
grouped by animation, which is what Godot's SpriteFrames wants.

Re-run after editing the source sheet:  python tools/slice_player_sheet.py
"""

import json
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "assets" / "characters" / "player_spritesheet_2.png"
OUT = ROOT / "assets" / "characters" / "player_frames.png"
# Grid geometry and the frame count per row, for build_sprite_frames.py. Written
# rather than duplicated so the .tres can't quietly drift out of step with the
# sheet after someone retimes or re-cuts a clip here.
MANIFEST = ROOT / "assets" / "characters" / "player_frames.json"

ALPHA_CUTOFF = 128
MIN_AREA = 50  # drops a stray 1px speck in the crouch row
# Below this a component is debris — a puff of kicked-up dust that broke away
# from its figure — not a frame. It gets folded back into its nearest neighbour
# rather than counted as one.
FRAME_MIN_AREA = 3000

CELL_W, CELL_H = 288, 240
# Ground line inside a cell. The 32px underneath is not just headroom for the
# slide's dust: an airborne pose anchored by its head hangs *below* the ground
# line whenever it is taller than a standing figure, and jump[1] — trailing leg
# still extended just after take-off — is 211px against a 190px stand.
BASELINE = CELL_H - 32
# Upright standing height, measured off the first shoot and run frames. Only
# used to anchor airborne poses; see ALIGN below.
STAND_H = 190

# Painted-in captions. Blanked before component labelling so a letter can never
# be picked up as a frame.
LABELS = [(28, 232, 10, 76), (14, 213, 272, 337), (21, 192, 557, 613),
          (742, 943, 551, 609), (18, 231, 800, 852)]

# Bands are keyed on the vertical centre of each component.
ROWS = {"run": (40, 290), "jump": (290, 570), "mid": (600, 810), "crouch": (840, 1020)}
# The slide and shoot strips share a band; they split cleanly on x.
MID_SPLIT_X = 735

# The three ground-slide poses are welded into one component by the dust streak
# they all sit in, so this is the one place an x cut is unavoidable. Cuts are
# the midpoints of the gaps between the figures' hats and shoulders, measured
# above the dust line.
SLIDE_BLOB_CUTS = (406, 577)

# How each frame is anchored vertically in its cell:
#   "bottom" — lowest opaque pixel sits on BASELINE. Right whenever the pose is
#              touching the ground.
#   "top"    — silhouette top sits STAND_H above BASELINE. Right for airborne
#              poses: physics supplies the arc, and with the legs tucked the
#              feet stop being the anchor. Bottom-aligning an airborne frame
#              pins the tucked boot to the floor and drags the head down, so the
#              character appears to duck at the apex of every jump.
ALIGN = {
    "run": "bottom",
    "jump": ["bottom", "top", "top", "top"],
    "fall": "top",
    "land": "bottom",
    "slide": "bottom",
    "shoot": "bottom",
    "crouch": "bottom",
}

# Row 2 is one continuous take, cut into three clips by where the figure is in
# its arc: it rises through frame 4, descends, then plants its feet.
JUMP_SPLIT = {"jump": (0, 4), "fall": (4, 6), "land": (6, 8)}


# Vertical slice of the figure used to locate it horizontally, as a fraction of
# its height measured up from the lowest pixel. Roughly hip to lower chest.
TORSO_BAND = (0.35, 0.65)


def torso_anchor(frame_mask: np.ndarray) -> float:
    """Horizontal anchor: the centre of mass of the figure's midriff.

    The collision box is the body, so the body is what has to sit still — and
    neither obvious anchor does that. The full bounding box lurches sideways the
    moment an arm extends: the shoot poses reach ~90px right, which would shove
    the body half that far left on the frame the clip starts. The feet are no
    better, because stance width is not constant either — every leaning pose
    (run, jump, crouch) puts the torso well forward of the point midway between
    the boots, so anchoring on the feet makes the body jump ~30px right the
    instant idle becomes run.

    A band from hip to lower chest dodges both. It sits below the arms — the
    firing poses extend at shoulder height — and above the legs. Across the
    shoot row it moves by 7px while the frame width nearly doubles.
    """
    ys = np.where(frame_mask.any(axis=1))[0]
    height = ys[-1] - ys[0] + 1
    lo, hi = TORSO_BAND
    band = frame_mask[ys[-1] - int(height * hi):ys[-1] - int(height * lo) + 1]
    if not band.any():  # degenerate pose; fall back to the whole silhouette
        band = frame_mask
    return float(np.where(band)[1].mean())


# Sprite scale in player.tscn. Only used to report muzzle offsets in the units
# player.gd wants; nothing in the slicing depends on it.
SPRITE_SCALE = 0.9
# Which cells have a muzzle flash painted in, as (row, first col, count).
FLASH_CELLS = {"MUZZLE_STAND": ("shoot", 3, 4), "MUZZLE_CROUCH": ("crouch", 7, 1)}


def measure_muzzles(sheet: np.ndarray) -> list[str]:
    """Report where the painted muzzle flashes land, in player.gd's units.

    `MUZZLE_STAND` and `MUZZLE_CROUCH` are hand-copied constants, so redrawing a
    firing pose silently moves the flash away from where bullets spawn. Printing
    the measurement every run makes that visible instead.
    """
    order = ["run", "jump", "fall", "land", "slide", "shoot", "crouch"]
    lines = ["  muzzle offsets measured from the painted flashes "
             f"(sprite scale {SPRITE_SCALE}):"]

    for const, (row_name, first, count) in FLASH_CELLS.items():
        row = order.index(row_name)
        found = []
        for col in range(first, first + count):
            cell = sheet[row * CELL_H:(row + 1) * CELL_H,
                         col * CELL_W:(col + 1) * CELL_W]
            r, g, b, a = (cell[..., i].astype(int) for i in range(4))
            # Saturated yellow, well clear of the character's tan shirt.
            flash = (a > 40) & (r >= 230) & (g >= 190) & (b <= 90)
            if flash.any():
                ys, xs = np.where(flash)
                found.append((xs.mean() - CELL_W / 2, ys.mean() - BASELINE))

        if not found:
            lines.append(f"    {const}: no flash found — check FLASH_CELLS")
            continue
        x = np.mean([p[0] for p in found]) * SPRITE_SCALE
        y = np.mean([p[1] for p in found]) * SPRITE_SCALE
        lines.append(f"    {const} := Vector2({x:.0f}, {y:.0f})"
                     f"   (from {len(found)} frame(s))")
    return lines


def find_frames(mask: np.ndarray) -> dict[str, list[np.ndarray]]:
    """Group connected components into per-animation lists of frame masks."""
    labelled, count = ndimage.label(mask, structure=np.ones((3, 3)))
    rows: dict[str, list] = {name: [] for name in ROWS}

    for index, box in enumerate(ndimage.find_objects(labelled), start=1):
        piece = labelled[box] == index
        if piece.sum() < MIN_AREA:
            continue
        y_mid = (box[0].start + box[0].stop) / 2
        for name, (lo, hi) in ROWS.items():
            if lo <= y_mid < hi:
                full = np.zeros_like(mask)
                full[box] = piece
                rows[name].append(full)
                break

    def by_x(frame: np.ndarray) -> int:
        return int(np.where(frame.any(axis=0))[0][0])

    anims: dict[str, list[np.ndarray]] = {}
    anims["run"] = sorted(rows["run"], key=by_x)
    anims["crouch"] = sorted(rows["crouch"], key=by_x)

    jump_row = sorted(rows["jump"], key=by_x)
    for name, (lo, hi) in JUMP_SPLIT.items():
        anims[name] = jump_row[lo:hi]

    mid = sorted(rows["mid"], key=by_x)
    slide = [f for f in mid if by_x(f) < MID_SPLIT_X]
    anims["shoot"] = [f for f in mid if by_x(f) >= MID_SPLIT_X]

    # Split the welded ground-slide component into its three poses. Any small
    # detached puff of dust rides along with whichever pose it sits under.
    split: list[np.ndarray] = []
    for frame in slide:
        xs = np.where(frame.any(axis=0))[0]
        if xs[-1] - xs[0] + 1 < 300:
            split.append(frame)
            continue
        edges = [xs[0], *SLIDE_BLOB_CUTS, xs[-1] + 1]
        for lo, hi in zip(edges, edges[1:]):
            part = frame.copy()
            part[:, :lo] = False
            part[:, hi:] = False
            if part.any():
                split.append(part)
    anims["slide"] = sorted(split, key=by_x)

    return {name: absorb_debris(frames) for name, frames in anims.items()}


def absorb_debris(frames: list[np.ndarray]) -> list[np.ndarray]:
    """Fold stray fragments back into the figure they belong to.

    The slide kicks up a puff of dust that is drawn detached from the body, so
    it labels as its own component and would otherwise be counted as an extra
    frame — a 19x16 speck sitting in the animation between two real poses.
    """
    real = [f for f in frames if f.sum() >= FRAME_MIN_AREA]
    if not real:
        return frames

    def x_centre(frame: np.ndarray) -> float:
        xs = np.where(frame.any(axis=0))[0]
        return (xs[0] + xs[-1]) / 2.0

    for fragment in (f for f in frames if f.sum() < FRAME_MIN_AREA):
        centre = x_centre(fragment)
        nearest = min(real, key=lambda f: abs(x_centre(f) - centre))
        nearest |= fragment
    return real


def main() -> None:
    src = Image.open(SRC).convert("RGBA")
    rgba = np.array(src)
    mask = rgba[..., 3] > ALPHA_CUTOFF
    for x0, x1, y0, y1 in LABELS:
        mask[y0:y1 + 1, x0:x1 + 1] = False

    anims = find_frames(mask)
    order = ["run", "jump", "fall", "land", "slide", "shoot", "crouch"]
    cols = max(len(anims[name]) for name in order)
    sheet = Image.new("RGBA", (cols * CELL_W, len(order) * CELL_H), (0, 0, 0, 0))

    report = []
    for row, name in enumerate(order):
        aligns = ALIGN[name]
        if isinstance(aligns, str):
            aligns = [aligns] * len(anims[name])

        for col, frame_mask in enumerate(anims[name]):
            ys = np.where(frame_mask.any(axis=1))[0]
            xs = np.where(frame_mask.any(axis=0))[0]
            y0, y1, x0, x1 = ys[0], ys[-1], xs[0], xs[-1]

            # Alpha comes from the component, not from the source rectangle, so
            # an overlapping neighbour inside this bounding box is dropped
            # rather than welded on. Original alpha values are kept where the
            # component is, which preserves the anti-aliased outline.
            patch = rgba[y0:y1 + 1, x0:x1 + 1].copy()
            patch[..., 3] = np.where(frame_mask[y0:y1 + 1, x0:x1 + 1],
                                     patch[..., 3], 0)
            frame = Image.fromarray(patch, "RGBA")
            fw, fh = frame.size

            off_x = round(CELL_W / 2 - torso_anchor(frame_mask[y0:y1 + 1, x0:x1 + 1]))
            off_y = BASELINE - (fh if aligns[col] == "bottom" else STAND_H)

            # Composited into its own cell-sized tile first, so an overflowing
            # frame is clipped rather than allowed to corrupt the cell beside
            # it — bleed is silent and looks like a bad crop, not a sizing bug.
            tile = Image.new("RGBA", (CELL_W, CELL_H), (0, 0, 0, 0))
            tile.alpha_composite(frame, (max(off_x, 0), max(off_y, 0)))
            sheet.alpha_composite(tile, (col * CELL_W, row * CELL_H))

            report.append(f"  {name}[{col}] src x{x0}-{x1} y{y0}-{y1} "
                          f"{fw}x{fh} align={aligns[col]}")
            if off_x < 0 or off_y < 0 or off_x + fw > CELL_W or off_y + fh > CELL_H:
                report.append(f"    !! clipped — {fw}x{fh} at ({off_x},{off_y}) "
                              f"does not fit cell {CELL_W}x{CELL_H}")

    sheet.save(OUT)
    report += measure_muzzles(np.array(sheet))
    MANIFEST.write_text(json.dumps({
        "sheet": OUT.name,
        "cell_w": CELL_W,
        "cell_h": CELL_H,
        "baseline": BASELINE,
        "stand_h": STAND_H,
        "rows": {name: len(anims[name]) for name in order},
    }, indent=2) + "\n")

    print(f"{OUT.relative_to(ROOT)}  {sheet.size[0]}x{sheet.size[1]}  "
          f"cell {CELL_W}x{CELL_H}  baseline {BASELINE}")
    print("  ".join(f"{n}={len(anims[n])}" for n in order))
    print("\n".join(report))


if __name__ == "__main__":
    main()
