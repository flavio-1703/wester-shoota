"""Generate scenes/player/player_frames.tres from the sliced animation grid.

Run after tools/slice_player_sheet.py:  python tools/build_sprite_frames.py

Timings are derived from the movement constants in scenes/player/player.gd
rather than picked by eye — the README is explicit that the feel is locked
first and the art is fitted to it, so a jump animation that outlasts
`jump_time_to_peak` is a bug, not a style choice. Where a clip has no
corresponding constant the fps is a plain guess and is marked as one.
"""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "assets" / "characters" / "player_frames.json"
OUT = ROOT / "scenes" / "player" / "player_frames.tres"
SHEET_RES = "res://assets/characters/player_frames.png"

# From player.gd. Kept here as literals because this script has no way to parse
# GDScript; if you retune the player, retune these too.
JUMP_TIME_TO_PEAK = 0.38
SLIDE_DURATION = 0.45
SHOOT_POSE_TIME = 0.25

# (source row, first frame, count, loop, fps)
#
# The sheet's rows are already the clips — sheet 3 draws a strip per stance,
# including the firing poses for running and jumping that sheet 2 was missing.
# The only rows that get subdivided are done in the slicer, not here.
#
# `crouch` is the settled kneel, played once so it holds on the low pose;
# `crouch_walk` is the shuffle and loops under it.
#
# `run_shoot` is authored at the same fps as `run` on purpose: player.gd
# time-scales both to the speed the body is travelling, and the authored length
# is the reference that scaling is measured against.
#
# `jump_shoot` is the one firing clip that plays ONCE. Its first frame is the
# only one of the five with no flash painted in, so looping it strobes the flash
# on and off every 0.42s for as long as fire is held in the air — a cadence with
# no relation to the weapon's 0.18s fire_interval. Played once it settles on
# frame 4, which is a flashing one, and re-arms whenever the clip changes.
CLIPS = {
    "idle":        ("idle",        0, 7, True,  6.0),   # guess: ~1.2s breath
    "run":         ("run",         0, 8, True,  15.0),
    "jump":        ("jump",        0, 5, False, 5 / JUMP_TIME_TO_PEAK),
    "fall":        ("fall",        0, 2, True,  6.0),   # guess
    "land":        ("land",        0, 2, False, 14.0),  # guess
    "slide":       ("slide",       0, 5, False, 5 / SLIDE_DURATION),
    "shoot":       ("shoot",       0, 6, True,  6 / SHOOT_POSE_TIME),
    "crouch":      ("crouch",      0, 2, False, 12.0),  # guess
    "crouch_walk": ("crouch_walk", 0, 9, True,  12.0),  # guess
    "run_shoot":   ("run_shoot",   0, 8, True,  15.0),
    "jump_shoot":  ("jump_shoot",  0, 5, False, 12.0),  # guess
}


def main() -> None:
    manifest = json.loads(MANIFEST.read_text())
    cell_w, cell_h = manifest["cell_w"], manifest["cell_h"]
    rows = list(manifest["rows"])

    atlases: list[str] = []
    animations: list[str] = []

    for clip, (row_name, start, count, loop, fps) in CLIPS.items():
        available = manifest["rows"][row_name]
        if start + count > available:
            raise SystemExit(
                f"{clip}: wants {row_name}[{start}..{start + count - 1}] but "
                f"the sheet only has {available} frames in that row")

        row = rows.index(row_name)
        frames = []
        for i in range(start, start + count):
            ident = f"AtlasTexture_{row_name}_{i}"
            if not any(ident in a for a in atlases):
                atlases.append(
                    f'[sub_resource type="AtlasTexture" id="{ident}"]\n'
                    f'atlas = ExtResource("1_sheet")\n'
                    f"region = Rect2({i * cell_w}, {row * cell_h}, "
                    f"{cell_w}, {cell_h})\n")
            frames.append(
                f'{{\n"duration": 1.0,\n"texture": SubResource("{ident}")\n}}')

        animations.append(
            '{\n"frames": [' + ", ".join(frames) + "],\n"
            f'"loop": {str(loop).lower()},\n'
            f'"name": &"{clip}",\n'
            f'"speed": {fps:.3f}\n}}')

    body = (
        f"[gd_resource type=\"SpriteFrames\" load_steps={len(atlases) + 2} format=3]\n\n"
        f'[ext_resource type="Texture2D" path="{SHEET_RES}" id="1_sheet"]\n\n'
        + "\n".join(atlases)
        + "\n[resource]\nanimations = [" + ", ".join(animations) + "]\n")

    OUT.write_text(body)
    print(f"{OUT.relative_to(ROOT)}  {len(atlases)} atlas regions, "
          f"{len(CLIPS)} animations")
    for clip, (row_name, start, count, loop, fps) in CLIPS.items():
        span = f"{row_name}[{start}]" if count == 1 \
            else f"{row_name}[{start}..{start + count - 1}]"
        print(f"  {clip:13s} {span:22s} {count} frames  {fps:5.1f}fps  "
              f"{count / fps:.2f}s  {'loop' if loop else 'once'}")


if __name__ == "__main__":
    main()
