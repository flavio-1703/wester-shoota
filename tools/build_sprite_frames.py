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

# (source row, first frame, count, loop, fps)
#
# `idle` is the standing pose at the head of the shoot row — the sheet has no
# idle strip of its own. `crouch` runs crouch[1..6], skipping the upright first
# frame and settling on the low kneel; it stops short of crouch[7] because that
# one has the revolver drawn *and a muzzle flash painted into it*, so resting on
# it would leave the player permanently firing while ducked. It is split out as
# `crouch_shoot` instead.
CLIPS = {
    "idle":         ("shoot",  0, 1, True,  1.0),
    "run":          ("run",    0, 9, True,  15.0),
    "jump":         ("jump",   0, 4, False, 4 / JUMP_TIME_TO_PEAK),
    "fall":         ("fall",   0, 2, True,  6.0),
    "land":         ("land",   0, 2, False, 14.0),
    "slide":        ("slide",  0, 5, False, 5 / SLIDE_DURATION),
    "shoot":        ("shoot",  1, 6, True,  24.0),
    "crouch":       ("crouch", 1, 6, False, 20.0),
    "crouch_shoot": ("crouch", 7, 1, True,  1.0),
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
        print(f"  {clip:13s} {span:18s} {count} frames  {fps:5.1f}fps  "
              f"{count / fps:.2f}s  {'loop' if loop else 'once'}")


if __name__ == "__main__":
    main()
