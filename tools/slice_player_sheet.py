"""Slice assets/characters/player_spritesheet_3.png into a uniform animation grid.

The source is a presentation sheet: labels painted into it, frames on no grid,
and neighbouring frames whose limbs overlap in x. What saves it is the alpha
channel — the art is already cut out, and the painted gradient lives only in the
RGB channels, so no colour keying is needed. The sheet looks like it has a
background only because a viewer composites the RGB over something; alpha is
effectively binary.

Frames are therefore lifted as connected components rather than sliced at x
cuts. That matters: run[2] spans x821-944 and run[3] spans x930-1057, so any
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
SRC = ROOT / "assets" / "characters" / "player_spritesheet_3.png"
OUT = ROOT / "assets" / "characters" / "player_frames.png"
# Grid geometry and the frame count per row, for build_sprite_frames.py. Written
# rather than duplicated so the .tres can't quietly drift out of step with the
# sheet after someone retimes or re-cuts a clip here.
MANIFEST = ROOT / "assets" / "characters" / "player_frames.json"

ALPHA_CUTOFF = 128
MIN_AREA = 50
# Below this a component is debris — a muzzle flash drawn clear of the barrel —
# not a frame. It gets folded back into the figure it belongs to rather than
# counted as one. See absorb_debris().
FRAME_MIN_AREA = 3000

CELL_W, CELL_H = 288, 240
# Ground line inside a cell. The 32px underneath is not just headroom: an
# airborne pose anchored by its head hangs *below* the ground line whenever it
# is taller than a standing figure, and the jump apex is 178px after scaling
# against a 168px stand.
BASELINE = CELL_H - 32
# Upright standing height, measured off the idle row after scale normalisation.
# Only used to anchor airborne poses; see ALIGN below.
STAND_H = 168

# Painted-in captions, as (x0, x1, y0, y1). Blanked before component labelling
# so a letter can never be picked up as a frame. The RUN AND SHOOT box touches
# the first figure's hat — it ends at y907 and the hat starts at y908 — so that
# one is measured tight rather than padded.
LABELS = [
    (15, 120, 16, 56),      # IDLE
    (626, 794, 16, 57),     # RUNNING
    (16, 176, 244, 285),    # JUMPING
    (870, 1115, 245, 285),  # JUMP SHOOTING
    (19, 166, 485, 527),    # SLIDING
    (823, 979, 487, 525),   # SHOOTING
    (19, 220, 703, 743),    # CROUCHING
    (750, 1014, 703, 743),  # CROUCH WALKING
    (19, 279, 869, 907),    # RUN AND SHOOT
]

# Bands are keyed on the vertical centre of each component. Four of the five
# hold two strips side by side, split on x at a gap wider than any figure.
BANDS = {"top": (40, 240), "air": (250, 480), "mid": (480, 700),
         "crouch": (700, 866), "run_shoot": (866, 1024)}
BAND_SPLITS = {
    # band: (left group, right group, cut x)
    "top": ("idle", "run", 575),          # idle ends x564, run starts x585
    "air": ("jump_arc", "jump_shoot", 860),  # jump ends x837, jump_shoot x879
    "mid": ("slide", "shoot", 800),       # slide ends x758, shoot starts x822
}

# What the artist drew, in figures per strip. Asserted rather than inferred: a
# re-cut sheet that silently loses a frame would otherwise shift every clip
# after it by one, which reads as the animation being subtly wrong rather than
# as a pipeline failure.
GROUP_COUNTS = {"idle": 7, "run": 8, "jump_arc": 9, "jump_shoot": 6,
                "slide": 5, "shoot": 6, "crouch_all": 11, "run_shoot": 8}

# Output row -> (source strip, first figure, stop). Rows rather than clips: the
# clip table lives in build_sprite_frames.py, which slices these further.
#
# `jump_arc` is one continuous take cut by where the figure is in its arc — it
# rises through figure 4, descends, then plants its feet (the last two are the
# only ones whose bottoms sit at y476, 12px below the airborne poses).
#
# `crouch_all` splits at figure 2, not at the CROUCH WALKING caption over figure
# 5. Figures 0 and 1 are a measurably distinct pose — 79 and 75px wide against
# 88-98 for every other figure in the row, and a silhouette difference of 911
# between the two of them against 1394 to the nearest of the rest — so they are
# the settled kneel and 2..10 are the walk. The caption is where it fitted.
#
# `jump_shoot` figure 5 is a grounded landing pose and is deliberately unused:
# the clip loops while airborne, so it would plant the feet in mid-air.
ROW_SOURCE = {
    "idle":        ("idle", 0, 7),
    "run":         ("run", 0, 8),
    "jump":        ("jump_arc", 0, 5),
    "fall":        ("jump_arc", 5, 7),
    "land":        ("jump_arc", 7, 9),
    "slide":       ("slide", 0, 5),
    "shoot":       ("shoot", 0, 6),
    "crouch":      ("crouch_all", 0, 2),
    "crouch_walk": ("crouch_all", 2, 11),
    "run_shoot":   ("run_shoot", 0, 8),
    "jump_shoot":  ("jump_shoot", 0, 5),
}
ORDER = list(ROW_SOURCE)

# How each frame is anchored vertically in its cell:
#   "bottom" — lowest opaque pixel sits on BASELINE. Right whenever the pose is
#              touching the ground.
#   "top"    — silhouette top sits STAND_H above BASELINE. Right for airborne
#              poses: physics supplies the arc, and with the legs tucked the
#              feet stop being the anchor. Bottom-aligning an airborne frame
#              pins the tucked boot to the floor and drags the head down, so the
#              character appears to duck at the apex of every jump.
ALIGN = {
    "idle": "bottom",
    "run": "bottom",
    "jump": "top",
    "fall": "top",
    "land": "bottom",
    "slide": "bottom",
    "shoot": "bottom",
    "crouch": "bottom",
    "crouch_walk": "bottom",
    "run_shoot": "bottom",
    "jump_shoot": "top",
}

# Vertical slice of the figure used to locate it horizontally, as a fraction of
# its height measured up from the lowest pixel. Roughly hip to lower chest.
TORSO_BAND = (0.35, 0.65)

# Height of the slice used to measure boot spread, in pixels above BASELINE.
# Deep enough to catch a whole boot, shallow enough not to reach the shins.
BOOT_DEPTH = 18

# The character's face, as inclusive RGB ranges. This is the sheet's scale
# reference — see group_scales().
FACE_RGB = ((206, 255), (116, 194), (76, 174))
# The strip every other strip is sized against. Idle is the plain standing pose,
# so its height is also what STAND_H and the collision box are fitted to.
SCALE_REFERENCE = "idle"
# A measured factor outside this range means the face detection has gone wrong
# rather than that the artist redrew a strip half-size. Reported, not enforced.
SCALE_SANITY = (0.70, 1.45)

# Sprite scale in player.tscn. Only used to report offsets in the units
# player.gd wants; nothing in the slicing depends on it.
SPRITE_SCALE = 1.0
# Which output rows have a muzzle flash painted in, and in which of their
# frames. Asserted against what is actually found: this is what catches a
# redrawn firing pose, a mis-assigned flash fragment, and a strip that shifted
# by a frame, all of which move where bullets have to spawn.
FLASH_FRAMES = {
    "shoot": [2, 3, 4],
    "run_shoot": [2, 3, 4, 5, 6, 7],
    "jump_shoot": [1, 2, 3, 4],
}
# Which player.gd constant each row's flashes measure.
MUZZLE_CONST = {"shoot": "MUZZLE_STAND", "run_shoot": "MUZZLE_RUN",
                "jump_shoot": "MUZZLE_AIR"}


def torso_anchor(frame_mask: np.ndarray) -> float:
    """Horizontal anchor: the centre of mass of the figure's midriff.

    The collision box is the body, so the body is what has to sit still — and
    neither obvious anchor does that. The full bounding box lurches sideways the
    moment an arm extends: the firing poses reach ~90px right, which would shove
    the body half that far left on the frame the clip starts. The feet are no
    better, because stance width is not constant either — every leaning pose
    (run, jump, crouch) puts the torso well forward of the point midway between
    the boots, so anchoring on the feet makes the body jump ~30px right the
    instant idle becomes run.

    A band from hip to lower chest dodges both. It sits below the arms — the
    firing poses extend at shoulder height — and above the legs.
    """
    ys = np.where(frame_mask.any(axis=1))[0]
    height = ys[-1] - ys[0] + 1
    lo, hi = TORSO_BAND
    band = frame_mask[ys[-1] - int(height * hi):ys[-1] - int(height * lo) + 1]
    if not band.any():  # degenerate pose; fall back to the whole silhouette
        band = frame_mask
    return float(np.where(band)[1].mean())


def face_area(figure: np.ndarray, rgba: np.ndarray) -> int:
    """Area of the largest patch of skin in a figure — its face.

    This is the sheet's scale landmark. Nothing else survived: bounding-box
    height confuses scale with lean, silhouette area confuses it with how far
    the limbs are spread, and the hat merges with the boots because every edge
    in the art is a black outline. The face is drawn at the same angle in every
    pose on the sheet and is the only region that is, so its area varies by
    under 10% within a strip while bbox height varies by 25%.
    """
    (r0, r1), (g0, g1), (b0, b1) = FACE_RGB
    r, g, b = (rgba[..., i].astype(int) for i in range(3))
    skin = figure & (r >= r0) & (r <= r1) & (g >= g0) & (g <= g1) \
        & (b >= b0) & (b <= b1)
    labelled, count = ndimage.label(skin, structure=np.ones((3, 3)))
    if count == 0:
        return 0
    return int(ndimage.sum(skin, labelled, range(1, count + 1)).max())


def group_scales(groups: dict[str, list[np.ndarray]],
                 rgba: np.ndarray) -> tuple[dict[str, float], list[str]]:
    """How much each strip has to be resized to match SCALE_REFERENCE.

    The strips are NOT drawn at one scale. `run_shoot` is the bad one: its
    figures are 111px tall against 160px for `run`, which is the same character
    doing the same thing, so drawing the gun would shrink the player by a fifth
    every time they fired on the move. The others are within 8% of each other,
    which is small enough to be invisible on its own and is normalised anyway
    because doing it per-strip costs nothing once the measurement exists.

    Scale goes as the square root of area, so a strip whose faces measure a
    quarter the reference's is drawn at half size.
    """
    faces = {name: [face_area(f, rgba) for f in frames]
             for name, frames in groups.items()}
    medians = {name: float(np.median(a)) for name, a in faces.items()}
    reference = medians[SCALE_REFERENCE]

    scales, report = {}, ["  strip scales, from face size "
                          f"(reference {SCALE_REFERENCE}):"]
    for name in groups:
        scale = (reference / medians[name]) ** 0.5 if medians[name] else 1.0
        scales[name] = scale
        warn = "" if SCALE_SANITY[0] <= scale <= SCALE_SANITY[1] \
            else "   !! outside sanity range — check FACE_RGB"
        report.append(f"    {name:11s} face {medians[name]:5.0f}px^2  "
                      f"x{scale:.3f}{warn}")
    return scales, report


def measure_flashes(sheet: np.ndarray) -> list[str]:
    """Report where the painted muzzle flashes land, in player.gd's units.

    The MUZZLE_* constants are hand-copied, so redrawing a firing pose silently
    moves the flash away from where bullets spawn. Printing the measurement
    every run makes that visible instead — and the frame list is asserted
    against FLASH_FRAMES, which is what catches a flash fragment that got folded
    into the wrong figure.
    """
    lines = ["  muzzle offsets measured from the painted flashes "
             f"(sprite scale {SPRITE_SCALE}):"]

    for row_name, want in FLASH_FRAMES.items():
        row = ORDER.index(row_name)
        found, seen = [], []
        for col in range(ROW_SOURCE[row_name][2] - ROW_SOURCE[row_name][1]):
            cell = sheet[row * CELL_H:(row + 1) * CELL_H,
                         col * CELL_W:(col + 1) * CELL_W]
            r, g, b, a = (cell[..., i].astype(int) for i in range(4))
            # Saturated yellow, well clear of the character's tan shirt.
            flash = (a > 40) & (r >= 230) & (g >= 190) & (b <= 90)
            if flash.sum() < 20:
                continue
            seen.append(col)
            ys, xs = np.where(flash)
            found.append((xs.mean() - CELL_W / 2, ys.mean() - BASELINE))

        const = MUZZLE_CONST[row_name]
        if not found:
            lines.append(f"    {const}: no flash found in {row_name}")
            continue
        x = np.mean([p[0] for p in found]) * SPRITE_SCALE
        y = np.mean([p[1] for p in found]) * SPRITE_SCALE
        lines.append(f"    {const} := Vector2({x:.0f}, {y:.0f})"
                     f"   from {row_name}{seen}")
        if seen != want:
            lines.append(f"    !! {row_name} flashes on {seen}, expected {want}"
                         " — a fragment went to the wrong figure, or the strip"
                         " moved")
    return lines


def measure_run(sheet: np.ndarray) -> list[str]:
    """Boot spread and feet height per frame of the two run cycles.

    `run_stride` in player.gd is the widest boot band times the sprite scale —
    it is what stops the run skating — and `RUN_CONTACT_PHASE` is where in the
    cycle the boots are at full extension. Both are hand-copied, so both are
    printed.

    Two things about the measurement, both learned by getting them wrong:

    The band is sampled at a FIXED DEPTH above the baseline, not at a fraction
    of the figure's height. Every grounded frame is bottom-aligned, so a fixed
    depth is the same slice of the world in each; a proportional one is not, and
    on the frame where the trailing boot is highest it sampled a slice that
    caught only one boot and reported a 31px spread against a real 109px.

    The phase is the widest PAIR of frames half a cycle apart, not the single
    widest frame. Both clips are two steps, so the two contacts must be
    `count / 2` apart by construction; picking the argmax alone let one noisy
    frame nominate a phase whose partner is a local minimum. Scoring pairs also
    reports how symmetric the cycle is, which is the honest signal about whether
    the strip really is a clean two-step cycle at all.
    """
    lines = []
    for row_name in ("run", "run_shoot"):
        row = ORDER.index(row_name)
        start, stop = ROW_SOURCE[row_name][1], ROW_SOURCE[row_name][2]
        bands, feet = [], []
        for col in range(stop - start):
            cell = sheet[row * CELL_H:(row + 1) * CELL_H,
                         col * CELL_W:(col + 1) * CELL_W, 3] > ALPHA_CUTOFF
            boots = cell[BASELINE - BOOT_DEPTH:BASELINE]
            xs = np.where(boots.any(axis=0))[0]
            bands.append(int(xs[-1] - xs[0] + 1) if len(xs) else 0)
            ys = np.where(cell.any(axis=1))[0]
            feet.append(int(ys[-1]))

        count = len(bands)
        half = count // 2
        pairs = [(bands[i] + bands[i + half]) / 2.0 for i in range(half)]
        first = int(np.argmax(pairs))
        phase = first + half
        spread = abs(bands[first] - bands[first + half])

        lines.append(f"  {row_name} boot band {bands}   (fixed {BOOT_DEPTH}px "
                     f"above the baseline)")
        lines.append(f"  {row_name} feet_y     {feet}")
        lines.append(f"    run_stride := {max(bands) * SPRITE_SCALE:.0f}"
                     f"   RUN_CONTACT_PHASE := {phase}.0"
                     f"   (contacts {first} and {phase}, "
                     f"{bands[first]} vs {bands[first + half]}px, "
                     f"asymmetry {spread}px)")
    return lines


def find_groups(mask: np.ndarray) -> dict[str, list[np.ndarray]]:
    """Group connected components into per-strip lists of frame masks."""
    labelled, _ = ndimage.label(mask, structure=np.ones((3, 3)))
    bands: dict[str, list] = {name: [] for name in BANDS}

    for index, box in enumerate(ndimage.find_objects(labelled), start=1):
        piece = labelled[box] == index
        if piece.sum() < MIN_AREA:
            continue
        y_mid = (box[0].start + box[0].stop) / 2
        for name, (lo, hi) in BANDS.items():
            if lo <= y_mid < hi:
                full = np.zeros_like(mask)
                full[box] = piece
                bands[name].append(full)
                break

    groups: dict[str, list[np.ndarray]] = {}
    for band, frames in bands.items():
        frames = sorted(frames, key=left_x)
        if band in BAND_SPLITS:
            left, right, cut = BAND_SPLITS[band]
            groups[left] = [f for f in frames if left_x(f) < cut]
            groups[right] = [f for f in frames if left_x(f) >= cut]
        else:
            groups["crouch_all" if band == "crouch" else band] = frames

    groups = {name: absorb_debris(frames) for name, frames in groups.items()}

    for name, want in GROUP_COUNTS.items():
        got = len(groups.get(name, []))
        if got != want:
            raise SystemExit(
                f"{name}: found {got} figures, expected {want}. The sheet was "
                f"re-cut — fix BANDS/BAND_SPLITS/GROUP_COUNTS before the clip "
                f"table in build_sprite_frames.py starts slicing the wrong "
                f"frames.")
    return groups


def left_x(frame: np.ndarray) -> int:
    return int(np.where(frame.any(axis=0))[0][0])


def absorb_debris(frames: list[np.ndarray]) -> list[np.ndarray]:
    """Fold stray fragments back into the figure they belong to.

    Six of the eight run-and-shoot poses and four of the jump-shooting ones have
    their muzzle flash drawn clear of the barrel, so it labels as its own
    component and would otherwise be counted as an extra frame.

    Ownership is by nearest opaque pixel, not by nearest bounding-box centre and
    not by "the figure to the left". Both of those get it wrong on this sheet:
    the flash sits 3-6px off its own barrel but the NEXT figure's bounding box
    often already covers it, and jump_shoot's last flash starts one pixel right
    of the following figure's left edge. Pixel distance is the only rule that
    survives all thirteen cases, and measure_flashes() asserts the outcome.
    """
    real = [f for f in frames if f.sum() >= FRAME_MIN_AREA]
    if not real:
        return frames

    for fragment in (f for f in frames if f.sum() < FRAME_MIN_AREA):
        distance = ndimage.distance_transform_edt(~fragment)
        nearest = min(real, key=lambda f: distance[f].min())
        nearest |= fragment
    return real


def cut_out(rgba: np.ndarray, frame_mask: np.ndarray) -> Image.Image:
    """Lift one figure out of the sheet, its own pixels only.

    Alpha comes from the component rather than from the source rectangle, so an
    overlapping neighbour inside this bounding box is dropped rather than welded
    on. Original alpha values are kept where the component is, which preserves
    the anti-aliased outline.
    """
    ys = np.where(frame_mask.any(axis=1))[0]
    xs = np.where(frame_mask.any(axis=0))[0]
    y0, y1, x0, x1 = ys[0], ys[-1], xs[0], xs[-1]
    patch = rgba[y0:y1 + 1, x0:x1 + 1].copy()
    patch[..., 3] = np.where(frame_mask[y0:y1 + 1, x0:x1 + 1], patch[..., 3], 0)
    return Image.fromarray(patch, "RGBA")


def resized(frame: Image.Image, scale: float) -> Image.Image:
    """Resize a cut-out figure, premultiplied so the edges stay clean.

    The transparent pixels still carry the sheet's painted gradient in RGB —
    alpha is what was cut, not colour — so a straight resample pulls that
    gradient into the anti-aliased outline and leaves a halo the compositor then
    makes visible. Premultiplying makes the transparent pixels contribute
    nothing, which is what they should contribute.
    """
    if abs(scale - 1.0) < 1e-3:
        return frame

    arr = np.asarray(frame).astype(np.float32)
    alpha = arr[..., 3:4] / 255.0
    arr[..., :3] *= alpha
    size = (max(round(frame.width * scale), 1), max(round(frame.height * scale), 1))
    out = np.asarray(
        Image.fromarray(arr.astype(np.uint8), "RGBA").resize(size, Image.LANCZOS)
    ).astype(np.float32)
    alpha = out[..., 3:4] / 255.0
    out[..., :3] = np.where(alpha > 0.0, out[..., :3] / np.maximum(alpha, 1e-6), 0.0)
    return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8), "RGBA")


def main() -> None:
    src = Image.open(SRC).convert("RGBA")
    rgba = np.array(src)
    mask = rgba[..., 3] > ALPHA_CUTOFF
    for x0, x1, y0, y1 in LABELS:
        mask[y0:y1 + 1, x0:x1 + 1] = False

    groups = find_groups(mask)
    scales, report = group_scales(groups, rgba)

    anims = {row: groups[source][start:stop]
             for row, (source, start, stop) in ROW_SOURCE.items()}
    cols = max(len(frames) for frames in anims.values())
    sheet = Image.new("RGBA", (cols * CELL_W, len(ORDER) * CELL_H), (0, 0, 0, 0))

    for row, name in enumerate(ORDER):
        scale = scales[ROW_SOURCE[name][0]]
        for col, frame_mask in enumerate(anims[name]):
            frame = resized(cut_out(rgba, frame_mask), scale)
            fw, fh = frame.size
            scaled_mask = np.asarray(frame)[..., 3] > ALPHA_CUTOFF

            off_x = round(CELL_W / 2 - torso_anchor(scaled_mask))
            off_y = BASELINE - (fh if ALIGN[name] == "bottom" else STAND_H)

            # Composited into its own cell-sized tile first, so an overflowing
            # frame is clipped rather than allowed to corrupt the cell beside
            # it — bleed is silent and looks like a bad crop, not a sizing bug.
            tile = Image.new("RGBA", (CELL_W, CELL_H), (0, 0, 0, 0))
            tile.alpha_composite(frame, (max(off_x, 0), max(off_y, 0)))
            sheet.alpha_composite(tile, (col * CELL_W, row * CELL_H))

            if off_x < 0 or off_y < 0 or off_x + fw > CELL_W or off_y + fh > CELL_H:
                report.append(f"  !! {name}[{col}] clipped — {fw}x{fh} at "
                              f"({off_x},{off_y}) does not fit {CELL_W}x{CELL_H}")

    sheet.save(OUT)
    grid = np.array(sheet)
    report += measure_flashes(grid)
    report += measure_run(grid)
    MANIFEST.write_text(json.dumps({
        "sheet": OUT.name,
        "cell_w": CELL_W,
        "cell_h": CELL_H,
        "baseline": BASELINE,
        "stand_h": STAND_H,
        "rows": {name: len(anims[name]) for name in ORDER},
    }, indent=2) + "\n")

    print(f"{OUT.relative_to(ROOT)}  {sheet.size[0]}x{sheet.size[1]}  "
          f"cell {CELL_W}x{CELL_H}  baseline {BASELINE}")
    print("  " + "  ".join(f"{n}={len(anims[n])}" for n in ORDER))
    print("\n".join(report))


if __name__ == "__main__":
    main()
