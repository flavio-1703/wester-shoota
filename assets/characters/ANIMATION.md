# Player animation pipeline

`player_spritesheet_2.png` is the authored art. Two scripts turn it into
something Godot can play; both are re-runnable and neither edits the source.

```
player_spritesheet_2.png          hand-authored sheet, 1536x1024
  │  tools/slice_player_sheet.py
  ├─ player_frames.png            uniform 288x240 grid, 7 rows x 9 cols
  └─ player_frames.json           grid geometry + frame counts
       │  tools/build_sprite_frames.py
       └─ scenes/player/player_frames.tres   SpriteFrames, 9 clips
```

Re-run both after editing the sheet:

```
python tools/slice_player_sheet.py && python tools/build_sprite_frames.py
```

## Why the source needs slicing at all

It is a presentation sheet, not a production one: captions painted in, frames on
no grid, and neighbouring figures whose limbs overlap in x. What rescues it is
the alpha channel — the art is already cut out, and the painted gradient lives
only in RGB, so no colour keying is needed. It *looks* like it has a background
because viewers composite the RGB over something.

Frames are lifted as connected components rather than cut at x boundaries.
`run[1]` spans x191-347 and `run[2]` spans x338-502, so any vertical cut between
them severs a boot. The one place a cut is unavoidable is the three ground-slide
poses, which the dust streak welds into a single component.

## Clips, and what drives them

| Clip | Source | Frames | Length | Driven by |
|---|---|---|---|---|
| `idle` | shoot[0] | 1 | — | `NORMAL`, grounded, no input |
| `run` | run[0..8] | 9 | 0.60s | `NORMAL` + steering input |
| `jump` | jump[0..3] | 4 | 0.38s | airborne, `velocity.y < 0` |
| `fall` | fall[0..1] | 2 | 0.33s | airborne, falling |
| `land` | land[0..1] | 2 | 0.14s | the frame `is_on_floor()` goes true |
| `slide` | slide[0..4] | 5 | 0.45s | `State.SLIDE` |
| `shoot` | shoot[1..6] | 6 | 0.25s | standing still, recently fired |
| `crouch` | crouch[1..6] | 6 | 0.30s | `State.CROUCH` |
| `crouch_shoot` | crouch[7] | 1 | — | `State.CROUCH`, recently fired |

`jump` is timed to `jump_time_to_peak` and `slide` to `slide_duration`, both read
off `player.gd`. Retune the player and these need retuning with it — they are
literals in `build_sprite_frames.py`, which cannot parse GDScript.

## Decisions worth knowing before you change something

**Airborne frames are anchored by the head, grounded frames by the feet.**
Physics supplies the jump arc; with the legs tucked the feet stop being a
meaningful anchor. Bottom-aligning an airborne pose pins the tucked boot to the
floor and drags the head down, so the character appears to duck at the apex of
every jump.

**Horizontal anchor is the torso, not the bounding box and not the feet.** The
collision box is the body, so the body is what has to sit still. Centring on the
bounding box lurches sideways when an arm extends — the shoot poses reach ~90px
right. Centring on the feet is no better: every leaning pose puts the torso well
forward of the midpoint between the boots, which made the body jump ~30px right
the instant idle became run. The anchor is the centre of mass of a hip-to-chest
band, which sits below the arms and above the legs; it shifts 7px across the
whole shoot row while the frame width nearly doubles.

**`run` beats `land`.** Touching down while still holding a direction picks the
run cycle straight back up; `land` only plays on a standing vertical drop. A
0.14s stumble at the end of every jump reads worse than no landing beat at all.

**The firing clip restarts on each shot.** `shoot` loops in 0.25s and the
revolver fires every 0.18s, so left to free-run the painted flashes drift out of
step with the bullets.

**`crouch` stops at crouch[6].** crouch[7] has a muzzle flash painted into it,
so resting on it would leave the player permanently firing while ducked. It is
split out as `crouch_shoot`.

**The old `Visuals/Muzzle/Flash` ColorRect is gone.** Both firing poses have
flashes painted in, and it would have doubled up on them. `MUZZLE_STAND` and
`MUZZLE_CROUCH` in `player.gd` are measured from those painted flashes — and
because they are hand-copied constants, `slice_player_sheet.py` prints the
measured values on every run. If what it prints stops matching `player.gd`, a
firing pose moved and bullets are now spawning off the barrel.

## What the run cycle is missing

Two things, both measured, and worth knowing before commissioning a replacement:

- **The arms don't swing.** Align each frame to run[0] and diff: the head and hat
  come out at 3–10 mean absolute difference, the legs at 9–20. The upper body is
  very nearly the same drawing throughout, so the cycle reads as scissoring legs
  under a static torso.
- **There is no vertical travel.** `feet_y` is 207 in all nine sliced frames. In
  the source the bottoms drift 255 → 276 monotonically across the row, which is
  sheet layout drift rather than a bounce — a real bounce would oscillate twice
  over a full cycle — so `ALIGN["run"] = "bottom"` is correct and restoring the
  source spacing would add a downward drift, not life. `player.gd` supplies a
  bob procedurally instead (`run_bob`).

A redrawn cycle wants: arm swing opposing the legs, shoulder and hip rotation,
and the head rising at the passing phase. If it arrives with a real bounce drawn
in, set `run_bob` to 0.

**Also re-measure `run_stride`** in `player.gd` against new art — the widest boot
band times the sprite scale. It is what stops the run skating, and it is a
hand-copied number. `tools/check_player_fx.gd` asserts it.

## Known gaps

- **No firing pose for a moving or airborne character.** Shooting on the run
  keeps the run cycle — the shot fires, it just isn't acted out. Substituting the
  standing shoot clip would stop the legs dead mid-stride at `run_speed` 600,
  which reads worse. Needs `run_shoot` / `air_shoot` strips in the art.

  **The missing muzzle flash part of this is now filled in code.** `player.gd`
  draws `scenes/fx/muzzle_flash.tscn` when a shot goes off over a clip that has
  no flash painted in — the list is `UNPAINTED_FLASH_CLIPS`, currently `run`,
  `jump` and `fall`. The pose is still wrong; the shot at least reads as a shot.

  **If `run_shoot` or `air_shoot` art ever lands, take those clips out of
  `UNPAINTED_FLASH_CLIPS`** or the painted flash and the code one will both play.
  `tools/check_player_fx.gd` asserts the gate in all four stances and is what
  catches this.
- **No crouch-walk.** Crouching while moving holds the settled crouch pose and
  slides along at `crouch_speed`.
- **No hit or death pose.** Damage is still the `modulate` flash in
  `_update_damage_feedback()`, and death is terminal via `GameState.game_over()`.
- **Sliding while firing** puts the muzzle at the crouch offset, but the slide
  poses have no gun drawn. `slide` is therefore deliberately left out of
  `UNPAINTED_FLASH_CLIPS` too: a flash from a visibly empty hand reads worse than
  no flash at all.

## Scale

Standing figures are 187px tall in the sheet against a 170px collision box, so
`Visuals/Sprite` is scaled 0.9 rather than the collision being resized — the
README is explicit that the movement feel is locked before art is fitted to it.

That 0.9 is mirrored as `SPRITE_SCALE` in `player.gd`, because squash and stretch
multiply it. **If you rescale the sprite in the scene, change the constant too** —
`_update_sprite_transform()` writes an absolute scale every frame and would
otherwise overwrite whatever you set.

## Effects the sheet doesn't cover

Squash and stretch, the recoil lean, and every dust puff are code, not art, and
they are applied to **`Visuals/Sprite` — never to `Visuals`**. `Visuals/Muzzle` is
a sibling of the sprite, and bullets spawn at its global position; scaling or
rotating the parent would drag the muzzle off the offsets measured off the
painted flashes and quietly break `MUZZLE_STAND` / `MUZZLE_CROUCH`. The check in
`tools/check_player_fx.gd` asserts the muzzle hasn't moved.
