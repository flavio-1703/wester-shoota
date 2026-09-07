# Player animation pipeline

`player_spritesheet_3.png` is the authored art. Two scripts turn it into
something Godot can play; both are re-runnable and neither edits the source.

```
player_spritesheet_3.png          hand-authored sheet, 1536x1024
  │  tools/slice_player_sheet.py
  ├─ player_frames.png            uniform 288x240 grid, 11 rows x 9 cols
  └─ player_frames.json           grid geometry + frame counts
       │  tools/build_sprite_frames.py
       └─ scenes/player/player_frames.tres   SpriteFrames, 11 clips
```

Re-run both after editing the sheet:

```
python tools/slice_player_sheet.py && python tools/build_sprite_frames.py
```

`player_spritesheet_2.png` is the previous sheet and is no longer wired to
anything. Sheet 3 added an idle strip, a crouch walk, and firing poses for
running and jumping; it fixed the run cycle (which now has arm swing) and
removed the dust that used to be painted into the slide. It also **dropped the
crouched firing pose**, which is the one place the new sheet is worse than the
old one — see Known gaps.

## Why the source needs slicing at all

It is a presentation sheet, not a production one: captions painted in, frames on
no grid, and neighbouring figures whose limbs overlap in x. What rescues it is
the alpha channel — the art is already cut out, and the painted gradient lives
only in RGB, so no colour keying is needed. It *looks* like it has a background
because viewers composite the RGB over something.

Frames are lifted as connected components rather than cut at x boundaries.
`run[2]` spans x821-944 and `run[3]` spans x930-1057, so any vertical cut between
them severs a boot. Sheet 3 needs no hand-placed cuts at all: the slide no longer
has a dust streak welding three poses into one component, so `SLIDE_BLOB_CUTS`
is gone.

## The strips are not drawn at one scale

This is the thing about sheet 3 that will bite anyone who assumes otherwise.
`run_shoot`'s figures are **111px tall against 160px for `run`** — the same
character doing the same thing — so lifting them as drawn would shrink the
player by a fifth every time they fired on the move. The other strips sit within
8% of each other.

`group_scales()` measures it and the slicer resizes each strip on the way in.
The landmark is the **area of the largest patch of face skin**, which is the only
pose-independent measurement on this sheet:

| Candidate | Why it fails |
|---|---|
| bounding-box height | confuses scale with how far the figure leans |
| silhouette area | confuses scale with how far the limbs are spread |
| hat | every edge in the art is a black outline, so the hat labels as one component with the boots and the belt |
| neckerchief | foreshortens away in the leaning poses |
| **face** | drawn at the same angle in every pose — varies <10% within a strip, against 25% for bbox height |

Scale goes as the square root of area. The factors it currently measures, against
`idle`:

```
idle 1.000   run 0.929   jump_arc 1.044   jump_shoot 1.051
slide 0.936  shoot 1.058  crouch_all 1.044  run_shoot 1.238
```

They are printed on every run. One landing outside `SCALE_SANITY` means the face
detection has broken, not that the artist redrew a strip half-size — check
`FACE_RGB` against the sheet before believing it.

Resizing is done **premultiplied**. The transparent pixels still carry the
sheet's painted gradient in RGB, so a straight resample pulls that gradient into
the anti-aliased outline and leaves a halo.

## Clips, and what drives them

| Clip | Source | Frames | Length | Driven by |
|---|---|---|---|---|
| `idle` | idle[0..6] | 7 | 1.17s | `NORMAL`, grounded, no input |
| `run` | run[0..7] | 8 | 0.53s | `NORMAL` + steering input |
| `jump` | jump_arc[0..4] | 5 | 0.38s | airborne, `velocity.y < 0` |
| `fall` | jump_arc[5..6] | 2 | 0.33s | airborne, falling |
| `land` | jump_arc[7..8] | 2 | 0.14s | the frame `is_on_floor()` goes true |
| `slide` | slide[0..4] | 5 | 0.45s | `State.SLIDE` |
| `shoot` | shoot[0..5] | 6 | 0.25s | standing still, recently fired |
| `crouch` | crouch_all[0..1] | 2 | 0.17s | `State.CROUCH`, not moving |
| `crouch_walk` | crouch_all[2..10] | 9 | 0.75s | `State.CROUCH` + steering input |
| `run_shoot` | run_shoot[0..7] | 8 | 0.53s | grounded, moving, recently fired |
| `jump_shoot` | jump_shoot[0..4] | 5 | 0.42s | airborne, recently fired |

`jump_shoot` is the one firing clip that plays **once**. Its first frame is the
only one of the five with no flash painted in, so looping it strobes the flash on
and off every 0.42s for as long as fire is held in the air — a cadence with no
relation to the weapon's 0.18s `fire_interval`. Played once it settles on frame
4, which is a flashing one.

`jump` is timed to `jump_time_to_peak`, `slide` to `slide_duration` and `shoot`
to `SHOOT_POSE_TIME`, all read off `player.gd`. Retune the player and these need
retuning with it — they are literals in `build_sprite_frames.py`, which cannot
parse GDScript. The four marked `# guess` in that file have no constant behind
them.

## How the sheet's strips map to rows

Five vertical bands, four of which hold two strips side by side and split on x at
a gap wider than any figure. Two of the splits are not where the captions are:

**`crouch_all` splits at figure 2, not at the CROUCH WALKING caption over figure
5.** Figures 0 and 1 are measurably a different pose — 79 and 75px wide against
88-98 for every other figure in the row, and a silhouette difference of 911
between the two of them against 1394 to the nearest of the rest. They are the
settled kneel; 2..10 are the walk. The caption is where it fitted.

**Row 3's orphan at x666 is `slide[4]`, and that is inferred.** Every other
caption sits within 13px of its strip's first figure; SHOOTING's sits 1px from
the standing figure at x822 and 157px from this one, so it is not a shoot frame.
It reads as getting up out of the slide, and `slide` plays once and settles on
its last frame, so a wrong guess costs one frame at the tail of a 0.45s clip.

**`jump_shoot[5]` is deliberately unused.** It is a grounded landing pose and the
clip loops while airborne, so including it would plant the feet in mid-air.

`GROUP_COUNTS` asserts the figure count of every strip. A re-cut sheet that
quietly loses a frame would otherwise shift every clip after it by one, which
reads as the animation being subtly wrong rather than as a pipeline failure.

## Decisions worth knowing before you change something

**Airborne frames are anchored by the head, grounded frames by the feet.**
Physics supplies the jump arc; with the legs tucked the feet stop being a
meaningful anchor. Bottom-aligning an airborne pose pins the tucked boot to the
floor and drags the head down, so the character appears to duck at the apex of
every jump.

**Horizontal anchor is the torso, not the bounding box and not the feet.** The
collision box is the body, so the body is what has to sit still. Centring on the
bounding box lurches sideways when an arm extends — the firing poses reach ~90px
right. Centring on the feet is no better: every leaning pose puts the torso well
forward of the midpoint between the boots, which made the body jump ~30px right
the instant idle became run. The anchor is the centre of mass of a hip-to-chest
band, which sits below the arms and above the legs.

**Detached muzzle flashes are folded back in by nearest opaque pixel.** Ten of
the flashes are drawn clear of the barrel and label as their own components.
Neither obvious rule works on this sheet: nearest bounding-box *centre* picks the
following figure, because the flash sits 3-6px off its own barrel but often
inside the next figure's box; and "the figure to the left" fails on
`jump_shoot`'s last flash, which starts one pixel right of the following figure's
left edge. `measure_flashes()` asserts the outcome against `FLASH_FRAMES`, so a
mis-assignment is a loud failure rather than a bullet spawning off the barrel.

**`run` beats `land`.** Touching down while still holding a direction picks the
run cycle straight back up; `land` only plays on a standing vertical drop. A
0.14s stumble at the end of every jump reads worse than no landing beat at all.

**Only `shoot` restarts on a shot.** `run_shoot` and `jump_shoot` have flashes
painted in too, but restarting them would pin the legs to the first two frames of
the cycle at a revolver `fire_interval` of 0.18s — and those are exactly the two
frames of the strip with no flash drawn, so the restart would suppress the thing
it exists to synchronise. Left free-running, six of run_shoot's eight frames and
four of jump_shoot's five are flashing anyway. The list is `SHOT_SYNCED_CLIPS`.

**The muzzle is keyed on the firing POSE, not on the stance.** Sheet 2 drew one
firing pose per stance and `_set_state()` could place the muzzle. Sheet 3 draws
three standing-height ones whose barrels are 37px apart in x and 39px in y, so
`player.gd` places it from `_firing_pose()` instead — one function that the clip
choice, the muzzle and the flash gate all read, so they cannot disagree.

`MUZZLE_STAND`, `MUZZLE_RUN` and `MUZZLE_AIR` are measured off the painted
flashes and **printed on every slicer run**. If what it prints stops matching
`player.gd`, a firing pose moved and bullets are now spawning off the barrel.

## The run cycle

Sheet 2's run had no arm swing and no vertical travel at all. Sheet 3 fixes the
first: the arms now oppose the legs. It still has effectively no vertical travel
— `feet_y` moves by 5px across the eight frames, one frame of it — and
bottom-alignment flattens that anyway, so `run_bob` in `player.gd` still supplies
the bounce procedurally. If a redrawn cycle ever arrives with a real bounce drawn
in, set `run_bob` to 0.

`run_stride` is the widest boot band times the sprite scale, and it is what stops
the run skating. `RUN_CONTACT_PHASE` is where in the cycle the boots are at full
extension. Both are hand-copied into `player.gd` and both are printed on every
slicer run:

```
run        [85, 83, 88, 101, 90, 89, 80, 121]   stride 121, contacts 3 and 7 (101 vs 121, asym 20)
run_shoot  [109, 93, 117, 100, 106, 122, 117, 109]         contacts 2 and 6 (117 vs 117, asym  0)
```

Two things about that measurement, both learned by getting them wrong:

- **The band is sampled at a fixed depth above the baseline, not at a fraction of
  the figure's height.** Every grounded frame is bottom-aligned, so a fixed depth
  is the same slice of the world in each; a proportional one is not. On
  `run_shoot[0]`, where the trailing boot rides high, the proportional slice
  caught one boot and reported a 31px spread against a real 109px.
- **The phase is the widest PAIR of frames half a cycle apart, not the single
  widest frame.** Both clips are two steps, so the contacts must be four frames
  apart by construction. Taking the argmax alone let `run_shoot`'s noisy frame 5
  nominate a phase whose partner (frame 1) is the row's global *minimum*. Scoring
  pairs also reports the asymmetry, which is the honest signal about how clean a
  two-step cycle the strip really is — and by that measure `run_shoot` is the
  tidier of the two.

The two clips genuinely disagree, which is why the phase is a per-clip dictionary
rather than one number. Because the cosine has a period of half the cycle, 7 and
3 are the same value there, as are 6 and 2. `tools/check_player_fx.gd` asserts
`run_stride` against actual world travel.

## Scale

Standing figures are 168px tall in the sheet after normalisation, against a 170px
collision box, so `Visuals/Sprite` is scaled 1.0. That 1.0 is mirrored as
`SPRITE_SCALE` in `player.gd`, because squash and stretch multiply it. **If you
rescale the sprite in the scene, change the constant too** —
`_update_sprite_transform()` writes an absolute scale every frame and would
otherwise overwrite whatever you set.

## Known gaps

- **No crouched firing pose.** This is a regression from sheet 2, which drew one
  in `crouch[7]`. No crouch frame in sheet 3 draws a gun at all, so:
  - `crouch_shoot` no longer exists as a clip. Firing while ducked keeps
    `crouch` or `crouch_walk`.
  - `crouch` and `crouch_walk` are the whole of `UNPAINTED_FLASH_CLIPS` — the
    code-drawn flash from `scenes/fx/muzzle_flash.tscn` covers them. It stays on
    despite the empty hand because crouching is a sustained combat stance and
    without it, ducking and firing has no feedback beyond the bullet itself.
  - `MUZZLE_CROUCH` is **the one muzzle offset that is not measured**. It is the
    leading hand of the settled kneel, picked by hand. Redrawing the crouch with
    a gun in it should replace that estimate with a measurement, add the row to
    `FLASH_FRAMES` in the slicer, and take the crouch clips back out of
    `UNPAINTED_FLASH_CLIPS` — or the painted flash and the code one will both
    play. `tools/check_player_fx.gd` asserts the gate in all five stances and is
    what catches this.
- **Sliding while firing** puts the muzzle at the crouch offset, but the slide
  poses have no gun drawn. `slide` is therefore deliberately left out of
  `UNPAINTED_FLASH_CLIPS`: it lasts 0.45s and the poses have the arms out for
  balance, so a flash there reads as coming from an empty hand.
- **No drinking pose.** `_handle_drink()` leaves the clip alone and the swig is
  sold by a tint and an amber puff.
- **No hit or death pose.** Damage is still the `modulate` flash in
  `_update_damage_feedback()`, and death is terminal via `GameState.game_over()`.

## Effects the sheet doesn't cover

Squash and stretch, the recoil lean, and every dust puff are code, not art, and
they are applied to **`Visuals/Sprite` — never to `Visuals`**. `Visuals/Muzzle` is
a sibling of the sprite, and bullets spawn at its global position; scaling or
rotating the parent would drag the muzzle off the offsets measured off the
painted flashes and quietly break them. The check in `tools/check_player_fx.gd`
asserts the muzzle hasn't moved.
