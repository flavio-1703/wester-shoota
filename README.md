# Wester Shoota

A western run-and-gun sidescroller. Godot 4.7 (Standard / GDScript), targeting a
desktop executable.

**Art direction:** hand-painted / illustrated HD 2D (Ori, Hollow Knight lineage) —
**not** pixel art. Authored at 1920×1080.

The **player is animated** from `assets/characters/player_spritesheet_3.png` —
eleven clips covering idle, run, jump, fall, land, slide, crouch, crouch-walk and
three firing poses (standing, running, airborne). See
[`assets/characters/ANIMATION.md`](assets/characters/ANIMATION.md) for the
slicing pipeline, the clip table and the gaps (no crouched firing pose, no
drinking pose, no hit or death pose). Everything else — level geometry, enemies,
projectiles — is still placeholder rectangles.

## Getting it running

The editor lives at `C:\Users\elezi\Tools\Godot\Godot_v4.7.2-stable_win64.exe`
(portable — no installer, moving it is fine).

1. Run the editor, **Import** this folder, and open the project.
2. Press **F5**. You get the main menu; **Play** drops you into the placeholder
   level. To iterate on the level directly, open `test_level.tscn` and press
   **F6** (run current scene) instead — it runs standalone.

Project settings (viewport 1920×1080, linear texture filtering, Forward+ renderer,
input map, collision layers) are already configured in `project.godot`.

## Controls

| Action | Keyboard | Gamepad |
|---|---|---|
| Move | `A` / `D` or arrows | Left stick, D-pad |
| Jump | `Space` | A |
| Shoot | `J` | X |
| Next weapon | `E` | Right shoulder |
| Previous weapon | `Q` | Left shoulder |
| Crouch | `S` / Down | Down, D-pad down |
| Slide | tap `S` while running | tap Down while running |
| Drink tequila | `F` | Y / top face button |
| Rest at a saloon | `R` | B / right face button |
| Pause | `Esc` | Start |
| Confirm in menus | `Enter` | A |
| Debug overlay | `F3` | — |

Whether shooting is auto-fire while held or one shot per press is **per weapon**
— the `automatic` flag on its `.tres`, not a code change. The revolver holds,
the shotgun taps. See [Weapons](#weapons).

Note that crouch shares the down binding, so a gamepad player pushing the stick
down to aim will crouch. Fine for now; worth revisiting if aiming down is added.

Rest is `R` rather than the conventional `E` because **`E` is already next
weapon**. Cycling weapons is used constantly and resting is used a handful of
times per level, so the established binding keeps the good key.

### Space confirms nothing

Godot's built-in `ui_accept` ships bound to Enter, KP-Enter, **Space** and
gamepad A. Space is also `jump`, so out of the box a player tapping jump on the
pause screen presses whatever button happens to be focused — including a
destructive one.

`ui_accept` is therefore **overridden in `project.godot` to drop Space**. On the
keyboard, Space is jump and only jump; menus confirm with Enter. If you re-add
Space to `ui_accept` in the Input Map, you re-open this.

Gamepad A is deliberately left on both `jump` and `ui_accept` — A-to-confirm is
universal and the two contexts don't overlap in practice. What keeps that safe
is menu layout, not bindings: **Resume is focused by default and the
destructive buttons go last**, so a reflexive A press resumes rather than
quitting. Keep that ordering if you add buttons.

## Weapons

**A weapon is a `.tres`, not a script.** `scripts/weapons/weapon.gd` is a
`Resource` holding the row of numbers that separates one gun from another — fire
interval, held-vs-tapped, pellet count, spread, recoil, shake — and each weapon
is a saved instance of it: `revolver.tres`, `shotgun.tres`. The player carries
`@export var weapons: Array[Weapon]` and fires whichever is current.

Adding a weapon is therefore **a new `.tres` and a new projectile scene, with no
code**. That is the whole point: weapons are meant to be drip-fed to the player
over the game, and the cheaper each one is to add, the more of them there can be.
Right now the player starts with all of them so they can be play-tested; the list
is what an unlock system will eventually populate.

Three things there are load-bearing:

- **A `.tres` is one shared object, not a copy per holder.** Nothing may write to
  a `Weapon` at runtime. Per-holder state goes on the holder — that's why
  `_fire_cooldown` lives on the player, and where ammo would go if it's ever
  added.
- **Damage, speed and range live on the projectile scene, not the weapon.**
  `bullet.gd` is shared; `bullet.tscn`, `pellet.tscn` and `enemy_bullet.tscn`
  differ only in numbers, colour and collision layers. Range is `speed × lifetime`
  — the revolver reaches 2160px (the whole screen), a pellet 490px. **Lifetime is
  the range knob** and it's what makes a shotgun a shotgun.
- **Switching does not reset `_fire_cooldown`.** If it did, cycling weapons would
  let you fire as fast as you can press `E`, beating every fire interval in the
  game.

`Player.weapon` is written only through `_set_weapon()`, which emits
`weapon_changed` — the same contract `_set_health()` holds for the pip row, so
the HUD readout can't go stale.

### The slot row

Under the health pips, the HUD shows **one slot per weapon carried**, not just
the one in hand: the equipped slot gets a lit frame and full brightness, the rest
are dimmed to 45%, and the name of the equipped weapon sits below the row. Two
reasons it's the whole list rather than a single icon — with `Q`/`E` cycling you
want to see what you're about to switch to, and once weapons are drip-fed, the
row appearing a slot longer is what tells you you've gained one.

The swatch colour is `ui_color` on the weapon's `.tres`, a placeholder standing
in for an icon in the same spirit as every other rectangle in the prototype. It
lives on the weapon so that **adding one stays a one-file job** — a new `.tres`
brings its own swatch and `hud.gd` needs no edit, exactly as the pip row needs no
edit when `max_health` changes.

The row is rebuilt when the list length changes, checked from `_process`.
`weapon_changed` deliberately isn't the hook for that: it fires on a *switch*,
and gaining a weapon isn't one, so an unlock would otherwise never show up.

### The shotgun

Six pellets in an **even fan** across 26°, one shot per press, 0.62s between
shots, and a 900 px/s backward kick — nearly triple the revolver's, against a
600 px/s run speed, so it visibly shoves you.

The fan is even rather than random (`Weapon.pellet_angle()` lerps across the
cone) because predictable pellet placement is much easier to tune and lets the
player learn the spread instead of re-rolling it every shot.

Two numbers set the balance, and neither is hand-tuned: a `Gunslinger` has 3 hit
points and each pellet does 1, so a point-blank hit with the whole fan is a
one-shot kill — and past 490px nothing arrives at all, because that's where the
pellets expire. **How much of the fan connects in between is unmeasured**; it
needs F5, along with everything else about the feel.

## Character effects

Squash, stretch, a recoil lean and dust — all code, no new art. Tunable in the
inspector under **Juice** on the Player, alongside everything else about the feel.

### The run was skating, and that was most of what looked wrong

The `run` clip is a full cycle of two steps. Authored at a flat length it covered
**360px of world travel per cycle** while the drawn step is only about **120px**
on screen — so the character slid roughly a quarter of the way, feet scrubbing
the ground. That reads as badly as it sounds and no amount of effects hides it.

`run_stride` (under **Run**) is now the distance one drawn step actually carries
the body, and the clip is time-scaled to fit: at speed `v` the cycle is made to
last `2 * run_stride / v`. It is driven off the **live velocity**, not off
`run_speed`, so it also covers the accel and decel ramps — where a fixed rate has
the legs turning over at full sprint cadence while the body is barely moving.

`run_stride` is measured off the sheet by hand, so **re-measure it if the run art
changes** — `tools/slice_player_sheet.py` prints the number on every run.
`tools/check_player_fx.gd` asserts the ratio and fails below 0.88 or above 1.12.

Both firing-on-the-move clips go through the same machinery: `RUN_CYCLE_CLIPS`
is `run` and `run_shoot`, and each one's authored length is read off the
SpriteFrames rather than assumed, so retiming one in `build_sprite_frames.py`
cannot silently desync the cadence matching from it.

### The run bob is code because the art has none

Every run frame is drawn with its feet on the same line, so the body never rises
and the cycle reads as a paper doll being slid along. `run_bob` supplies it.

It only ever **lifts, never sinks**: the offset runs from 0 at the contact frames
to `-run_bob` at the passing frames. Pushing down from a drawn baseline would
drive the planted boot through the floor, whereas lifting during the passing
phase is right precisely because that's when the feet are off the ground in a
real stride.

Unlike squash and stretch it's written to **Visuals**, not the sprite: the gun is
in the character's hand, so the muzzle should rise and fall with the body. Moving
the whole node leaves `_muzzle.position` at `MUZZLE_STAND` and keeps the
code-drawn flash attached to the hand.

Sheet 2's run had a static upper body over scissoring legs; sheet 3's arms swing
against the legs, which is the half of this that only a redraw could fix. The
vertical travel is still not in the art — `feet_y` moves 5px across the eight
frames, and bottom-alignment flattens even that — so the bob stays.

- **Squash and stretch.** The sprite stretches with vertical speed while airborne
  and compresses on landing *in proportion to the impact*, so a hop off a ledge
  barely registers and a long drop really lands. The impact speed is sampled
  before `move_and_slide()`, which zeroes it against the floor on the very frame
  the landing happens.
- **Dust** on takeoff, landing, running, sliding and skidding, plus smoke off the
  muzzle. One `dust_puff.tscn` for all of it — the spawner varies velocity, size,
  lifetime and opacity rather than there being a scene per effect. Dust is
  spawned into the **level**, not onto the player, so it stays where it was
  kicked up instead of travelling along at `run_speed`.
- **A recoil lean** on firing, and a **muzzle flash** — see below.

### The muzzle flash fills a gap in the sheet

Sheet 3 draws firing poses for standing, running and airborne, all with the flash
**painted into the art**. What it doesn't draw is a crouched one — sheet 2 had it
and the redraw lost it — so `crouch` and `crouch_walk` are the whole of
`UNPAINTED_FLASH_CLIPS` in `player.gd`, and the code-drawn flash from
`muzzle_flash.tscn` covers exactly them.

The gate is load-bearing and it cuts both ways: draw one over a painted pose and
every shot flashes twice, take a clip out of the list without art behind it and
the shot stops reading as a shot. It is a hand-maintained mirror of what the
artist has drawn, so **move clips between the lists whenever the sheet changes**
— `tools/check_player_fx.gd` drives all five stances and is what catches it.

`slide` is deliberately in neither: you can fire mid-slide, but the slide poses
have no gun drawn at all, so a flash from a visibly empty hand reads worse than
no flash. That one stays a job for the art.

Only `shoot` restarts on a trigger pull. `run_shoot` and `jump_shoot` are painted
too, but snapping them back to frame 0 every 0.18s would pin the legs to the two
frames of the strip that have *no* flash drawn — suppressing the very thing the
restart exists to synchronise. That list is `SHOT_SYNCED_CLIPS`.

### The muzzle is placed per firing pose, not per stance

Sheet 2 drew one firing pose per stance, so `_set_state()` could put
`Visuals/Muzzle` where the barrel was. Sheet 3's three standing-height firing
poses have barrels **37px apart in x and 39px in y**, so a stance-keyed muzzle
would spawn every running shot a body-width behind the gun.

`_firing_pose()` is now the single source for which pose is on screen, and the
clip choice, the muzzle offset and the flash gate all read it — three
reconstructions of the same branch would drift the first time someone reordered
one. The offsets in `MUZZLE` are measured off the painted flashes by
`tools/slice_player_sheet.py`, which prints them on every run; `MUZZLE_CROUCH` is
the only estimated one, because there is no crouched flash left to measure.

`_update_animation()` returns the clip it picked and the flash is gated on that
return value, rather than working the state out a second time — two copies of
that decision would drift the first time someone reordered a branch.

### Everything visual goes on the Sprite, not on Visuals

`Visuals/Muzzle` is a **sibling** of `Visuals/Sprite`, and bullets spawn at its
global position. Squash, stretch and the recoil lean are therefore written to the
sprite alone: scaling or rotating `Visuals` would drag the muzzle with it and
quietly move the spawn point off the `MUZZLE` offsets measured off the painted
flashes. The sprite's origin sits at the player's feet,
which is the pivot squash wants anyway — the boots stay planted.

`_update_sprite_transform()` is the single writer of the sprite's scale and
rotation, the same contract `_update_damage_feedback()` holds for `modulate` and
the camera holds for `offset`. It writes an **absolute** scale off the
`SPRITE_SCALE` constant rather than multiplying what's already there, which would
compound the squash every frame.

### Checking it

```
Godot_v4.7.2-stable_win64.exe --path . --script res://tools/check_player_fx.gd
```

Drives the real player through standing, running, airborne and sliding fire and
asserts the flash appears in exactly two of them; then jumps and asserts the
sprite stretched, squashed on landing, and that **the muzzle did not move**.
Non-zero exit on failure. Run it after touching the clip lists or the sheet.

## Sound

Four events make noise: **footsteps, the slide scrape, gunfire, and a bullet
landing on something that bleeds.** Everything else is still silent.

The samples are **placeholders, synthesised by a script**, in the same spirit as
the coloured rectangles the rest of the game is prototyped with:

```
Godot_v4.7.2-stable_win64.exe --headless --path . --script res://tools/gen_sfx.gd
```

That writes six `AudioStreamWAV` resources into `assets/audio/`. Re-running is
safe — every generator is seeded, so the output is byte-identical.

They are saved as **`.tres`, not `.wav`**, and that matters: a `.wav` written by
a script has no `.import` sibling, so `load()` returns null until somebody has
opened the editor and let the import pipeline run — which breaks a fresh clone
and every headless check. Saving the resource itself skips the importer.

Swapping in real recordings needs **no code**: drop a file in and assign it to
the same slot. `fire_sound` is on the weapon `.tres` (so a new weapon still ships
as one file with no code at all), `impact_sound` is on the projectile scene,
`footstep_sounds` is an array on the player, and the slide loop is the stream on
the player's `SlideSfx` node.

`impact_sound` is set on `bullet.tscn` and `pellet.tscn` and left **empty on
`enemy_bullet.tscn`** — the player being hit wants its own sound, and handing the
enemies this one would have the dedupe below swallow your shot landing to pay for
theirs.

Design decisions worth not re-deriving:

- **One-shots go through the `Sfx` autoload, not through a player node on
  whatever made the noise.** A bullet calls `queue_free()` on the line after its
  hit and a dying gunslinger frees itself immediately, so a child
  `AudioStreamPlayer2D` on either would be cut off before a single sample was
  heard. `Sfx.play_at(stream, position)` borrows one of 16 pooled voices that
  outlive the caller, stealing the longest-running one if all are busy.
- **`Sfx` pauses with the game**, unlike `GameState` — these are gameplay
  sounds, and a slide hissing under the pause menu is the wrong behaviour.
- **The same stream is played once per 90ms.** A shotgun puts six pellets into
  one target across about three physics ticks; without that window they stack
  into a clipped blast. The value sits between the pellet spread below it and
  the revolver's 0.18s `fire_interval` above it.
- **The slide loop starts and stops in `_set_state()`, not in
  `_start_slide()`/`_end_slide()`.** `_stand_up_to_jump()` cancels a slide
  without ever calling `_end_slide()`, so the obvious bracketing leaves the
  scrape hissing forever after the first slide you jump out of. `_set_state()`
  is the one choke point every stance change passes through.
- **Footsteps fire off the run clip's contact frames, not off a timer.**
  `_match_run_cadence()` already time-scales the clip to the speed the body is
  actually travelling, so reading the frame index inherits that for free; a
  fixed interval drifts out of the stride on the accel and decel ramps. They
  share `RUN_CONTACT_PHASE` with the run bob, so the step you hear and the step
  you see cannot come apart, and they reuse `run_dust_min_speed` so a player
  leaning into a wall doesn't jog on the spot.

No audio bus layout and no volume sliders: everything goes to Master at
per-stream volumes. Adding an SFX bus later is a `default_bus_layout.tres` plus
setting `bus` on the pool, and nothing that calls in has to change.

```
Godot_v4.7.2-stable_win64.exe --headless --path . --script res://tools/check_sfx.gd
```

Asserts the pool exists and every stream loads with audio in it, that one
trigger pull is one report, that **six pellets into one gunslinger make one
impact and not six** (corroborated by the target actually losing health), that
the scrape loop stops both when a slide runs out *and* when it is jump-cancelled,
that footsteps fire while running and not while standing or airborne, that the
pool doesn't grow, and that **pausing silences everything**. Non-zero exit on
failure.

The samples themselves are not checked by any of that — a `.tres` full of the
wrong noise passes every assertion above. **Listen to them.**

## Crouch and slide

Crouching swaps to a 90px collision shape instead of the 170px standing one,
which is the point: **enemy fire passes over a crouched player** (their muzzle
sits at 110px). You can still return fire — the muzzle drops with the stance.

Tapping crouch while running above `slide_min_speed` starts a slide instead: a
speed burst that bleeds off over `slide_friction_time`, with no steering while
it lasts. Jump cancels it. Sliding into a gap too low to stand in leaves you
crouched rather than clipping upright — `_can_stand()` shape-casts the standing
volume before any stand-up is allowed.

There's a tunnel in the test level around x=750 with 110px of clearance to try
this on.

## Layout

```
assets/            art + audio, plus CREDITS.md (fill it in per source)
assets/backgrounds/  background_reference.png + generated/ (built, not hand-edited)
assets/fx/         generated/ — dust puff + muzzle flash (built, not hand-edited)
assets/characters/ player sheet + the sliced grid; ANIMATION.md documents both
assets/audio/      AudioStreamWAV .tres files (built, not hand-edited) — see Sound
tools/             sheet slicer + SpriteFrames generator (Python, run by hand)
                   check_bg_coverage.gd — parallax coverage guard (Godot, headed)
                   gen_background.py — builds the parallax layer PNGs
                   gen_fx.py — builds the dust/muzzle-flash sprites
                   gen_sfx.gd — synthesises the placeholder sound effects
                   check_player_fx.gd — muzzle-flash gate + squash guard
                   check_flask.gd — flask clamps, saloon rest, HUD row overlap
                   check_sfx.gd — pool, impact dedupe, slide loop, footsteps
scenes/player/     player.tscn, player_camera_2d.gd
scenes/enemies/    gunslinger.tscn
scenes/checkpoints/  saloon_checkpoint.tscn — rest point, respawn anchor
scenes/pickups/    tequila_stash.tscn — one flask charge, left in the world
scenes/projectiles/  bullet.gd is shared — bullet.tscn, pellet.tscn and
                     enemy_bullet.tscn differ only in numbers, colour and layers
scenes/fx/         impact_puff.tscn, dust_puff.tscn, muzzle_flash.tscn
scenes/levels/     test_level.tscn
scenes/levels/backgrounds/  desert_bg.tscn — parallax layers, instanced per level
scenes/ui/         main_menu.tscn, pause_menu.tscn, game_over_menu.tscn
                   hud.tscn — health + flask + weapon readout, owned by GameState
                   debug_overlay.tscn — autoloaded as DebugOverlay
scripts/globals/   game_state.gd — autoloaded as GameState
                   sfx.gd — autoloaded as Sfx, pooled one-shot sound effects
scripts/weapons/   weapon.gd (Resource) + one .tres per weapon
```

The game boots to the **main menu**, not straight into the level: `run/main_scene`
is `scenes/ui/main_menu.tscn`. Press Play to reach gameplay.

`GameState` owns every scene swap **and the pause** — nothing else should call
`change_scene_to_file` or touch `get_tree().paused`, so a fade or a save-on-exit
can be added in one place later.

## Pausing

`GameState` instantiates `pause_menu.tscn` once at startup as a child of itself
and shows or hides it. Levels don't carry a pause menu and don't need to know
one exists — a new level gets pausing for free.

Three things there are load-bearing:

- **`GameState.process_mode` is `ALWAYS`.** It owns the un-pause input; if it
  froze with the tree, pausing would be a one-way trip. Same for the pause menu
  scene root.
- **Every scene transition clears the pause.** `_go_to()` calls `_clear_pause()`
  on success. Without it, "Main Menu" from the pause screen lands you on a menu
  whose buttons are frozen, with nothing left running to unfreeze them.
- **What gets shown and hidden is the `Overlay` Control, not the CanvasLayer.**
  `CanvasLayer` isn't a `CanvasItem`, so hiding it doesn't feed into
  `Control.is_visible_in_tree()` — the buttons would keep focus and keep
  answering input while invisible.

The player and enemies need no pause handling: their default `process_mode`
inherits, so `get_tree().paused` freezes them.

## Health and the HUD

The player has `max_health` (default 5) hit points and a row of pips for them in
the **top-left** corner — `hud.tscn`, with the [flask
readout](#the-tequila-flask) under the pips and the weapon slots under that.
Top-left because `DebugOverlay` owns the top-right. The pips are built at runtime from `max_health`, so raising it in the
inspector widens the row without touching the HUD.

`GameState` owns the HUD the same way it owns the menus: instantiated once at
startup, never placed in a level. Levels don't carry a HUD and don't need to
know one exists, so a new level gets the readout for free and Retry can't leave
a second one behind.

Three things there are load-bearing:

- **`Player.health` is only ever written through `_set_health()`**, which emits
  `health_changed(current, total)`. Death by falling is why: it never goes
  through `take_damage`, so a signal emitted only on damage would leave a full
  bar showing behind the death screen.
- **The HUD finds the player; nothing hands it one.** `state_changed` is the
  wrong hook — `change_scene_to_file` is deferred to the end of the frame, so on
  a swap it fires while the *outgoing* scene is still current and a lookup from
  there finds the old level's player or nothing at all (the `state_changed` doc
  comment in `game_state.gd` spells out all three transitions). It polls the
  `player` group instead, exactly as `gunslinger.gd` does,
  and that doubles as the visibility rule: a scene with a player is gameplay and
  shows the HUD, one without is a menu and doesn't.
- **`process_mode` is `PAUSABLE`, set explicitly** — the opposite of the two
  menus. The HUD hangs off `GameState`, which is `ALWAYS`, so leaving it to
  inherit would quietly keep it polling behind the pause screen.

`layer = 50` puts it under the pause overlay (100) and the debug overlay (200),
so the pause dim covers it rather than the other way round.

Balance is untuned — 5 hit points and a 0.9s i-frame window are placeholders.

## The tequila flask

**`F` drinks. Refills only at a saloon.** The flask is the healing loop — there
are no health pickups lying around, and there is not going to be a corridor you
can walk back down to farm one. You carry `flask_charges_max` swigs (default 3),
each worth `flask_heal_amount` pips (default 1), and what you have when you leave
a saloon is what you have until you reach the next one.

Three things about it are load-bearing:

- **The charge is spent on the press; the health arrives `drink_heal_delay`
  later** (0.45s into a 0.65s swig). Those being two separate events *is* the
  feel of the thing: drinking a frame before a bullet lands costs you the swig
  and doesn't save you, so reaching for the flask is a read of the fight rather
  than a reflex. Collapse them together and the flask becomes a free button.
- **Shooting is refused for the whole swig**, and a slide can't be launched out
  of one. Crouching still can — ducking while committed to a drink is exactly
  the play worth leaving open. Movement is deliberately untouched: gating it too
  would have meant a state-machine rewrite for a 0.65s window.
- **`flask_charges` is per-player mutable state, never a `Resource`.** Same rule
  as `_fire_cooldown` — see [Weapons](#weapons). A `.tres` is one shared object,
  so a flask on one would be everybody's flask.

`flask_charges` is written only through `_set_flask_charges()`, which clamps to
`0..flask_charges_max` and emits `flask_changed(current, total)` — the same
contract `_set_health()` holds for the pip row, and the reason the HUD readout
can't go stale. Dying cancels a swig in flight, or the pending heal would put a
pip back on the bar behind the death screen.

The readout sits under the health pips: one amber swatch per charge, lit or
spent, and `TEQUILA 3 / 3` beside it. The swatch row is built from
`flask_charges_max` at runtime exactly as the pips are built from `max_health`,
so **nothing assumes there are three**. The HUD also re-checks the row length
from `_process`, because raising the maximum isn't a change to the charges and
so doesn't emit `flask_changed` — the same self-heal the weapon slot row has, for
the same reason.

### Collectibles

`scenes/pickups/tequila_stash.tscn` is the one that exists: a bottle worth one
charge, never past the maximum. The whole "is there room for it" decision lives
in `Player.add_flask_charges()`, which returns whether it actually took any —
that's what lets the bottle stay in the level when you walk past with a full
flask instead of being consumed for nothing. Collection is retried every frame
you overlap it, not only on `body_entered`, because that signal doesn't repeat
for a body that never left.

There is deliberately **no pickup base class yet**. `Agave Heart` (raise
`flask_charges_max`), `Silver Flask Cap` (raise `flask_heal_amount`) and
`Gold Nugget` are the same six lines with a different call in `_try_collect()`;
with one implementation there is nothing to factor out, and guessing at the
shared part now is how you get a base class that fits none of them.

Not built: inventory, shops, currency, permanent upgrade menus.

## Saloon checkpoints

`scenes/checkpoints/saloon_checkpoint.tscn` is a bonfire in a hat. Walk up, get
`Press R to rest`, and resting **refills your health, refills your flask, makes
this saloon where you come back to, and reloads the level** — which puts the
enemies back. That last clause is the bargain, and it's the Dark Souls one.

One is placed in `test_level` at the ground line around x=2200, on the flat
between the first gunslinger and `LedgeFar`: past the opening tunnel-and-ledge
stretch and the first fight, which is where a breather belongs. Its
`checkpoint_id` is `test_level_saloon`. **Ids must be unique per level** — the
active one is stored by id, so two saloons sharing one would both light up.

Four things there are load-bearing:

- **The reload is a plain `GameState` level swap, not an enemy-reset manager.**
  Nothing in a level holds progression state yet, so a reload *is* the reset and
  costs no new code to keep correct. When something one-off lands — a boss, an
  opened shortcut — `rest_at_checkpoint()` is the line that has to change.
  `reload_on_rest` is exported so `tools/check_flask.gd` can drive a rest without
  having the scene swapped out from under it mid-assertion.
- **The checkpoint is recorded before the refill and before the reload.**
  `Player._ready()` asks `GameState.get_respawn_position()` where to stand, so on
  the reload the checkpoint has to already be the answer.
- **The saloon carries no blocking collision at all** — it's an `Area2D` on the
  pickups layer masked to the player, with `ColorRect`s for readability. A
  `StaticBody2D` silhouette there would stall a run, and
  `tools/check_player_fx.gd` measures run cadence across that stretch of ground.
- **`Building` sits at `z_index = -1`.** Everything in a level is at z 0 and a
  saloon is placed after the Player in the tree, so without it the facade draws
  over you and walking to the door hides you behind the building. −1 is still
  ahead of every parallax layer (sky −100 up to the play plane) and behind the
  foreground dust at +40.

Lit versus shuttered is the whole active/inactive read, applied to the same
nodes so there is no second set of art to keep in sync: warm windows, a lit
lantern, and a breathing pool of light spilling out of the doorway onto the
dirt. A big soft halo *around* the building was the first attempt and it read as
a rendering fault — a translucent rectangle with hard edges, in a scene made of
hard-edged rectangles, has nothing to distinguish it from a bug. A pool on the
ground has a physical reading, which is what survives into painted art.

### Where the checkpoint lives, and what it costs

`GameState` holds it — scene path, id, respawn position — rather than a
competing singleton, for the same reason it owns every scene swap. Retry is
therefore **unchanged**: it still reloads the level, and where you land inside it
is decided by the checkpoint. **A level with no saloon in it retries from the top
exactly as it did before**, and so does a level whose only checkpoint belongs to
a different level.

Two limitations, both deliberate for a first pass:

- **Progress is session-only.** There is no disk save; quitting the executable
  loses the checkpoint. `start_new_game()` clears it too, so Play from the menu
  is always a fresh run.
- **Level identity is `GameState._current_level`, not
  `get_tree().current_scene`.** Every level change already goes through the
  autoload, so that field is authoritative and needs no assumption about engine
  ordering during a swap — and `current_scene` is null when a level is added to
  the root by hand, which is exactly what the headless checks in `tools/` do. The
  cost is that a *second* level launched directly with F6 would still report as
  `FIRST_LEVEL_SCENE`. `set_checkpoint()` therefore also writes
  `_current_level`, which keeps Retry honest for whichever level actually rested.

### Checking it

```
Godot_v4.7.2-stable_win64.exe --path . --script res://tools/check_flask.gd
```

Drives the real player in the real level with faked input. Asserts the charge
clamps hold at both ends, that a swig spends on the press and heals late, that
it doesn't overheal, that firing is refused mid-swig, that resting refills both
bars and records the checkpoint, and that Retry resolves to the checkpoint —
**and falls back to the level spawn when there isn't one**, which is the case
that must keep working for every level with no saloon. The last phase does a
**real level reload** and asks where `Player._ready()` actually put the player,
rather than trusting `get_respawn_position()` in isolation: everything upstream
of that call can be right and still land you at the opening spawn. Non-zero exit
on failure.

It also asserts the flask row's rect doesn't intersect the health pips or the
weapon slots. That one is a rect test rather than a count, because the HUD row
positions are hand-placed numbers and a charge-count assertion cannot see a row
land on top of another. Run headed and it saves `user://flask_hud.png` and
`user://flask_saloon_unrested.png` — the before and after of the saloon's lit
state, which is a judgement no assertion makes.

## Death and game over

**Death is terminal.** `Player.die()` hands off to `GameState.game_over()`,
which freezes the tree and puts up `game_over_menu.tscn` — Retry / Main Menu /
Quit. Retry reloads the level; you come back at the last
[saloon](#saloon-checkpoints) you rested at, or from the top if you haven't
rested at one. The player no longer respawns in place; that quietly undid the
death and made it easy to miss that you'd lost.

Two ways in: health reaching zero, and falling out of the level.

`Esc` is deliberately inert on the death screen. Death isn't something you
un-pause your way out of, so `_unhandled_input` ignores `pause` in `GAME_OVER`.

### The kill plane comes from CameraBounds

Falling used to be survivable-by-accident — nothing detected it, so you dropped
for ever. The fix reuses the rect the level already has: the kill plane sits
`fall_death_margin` (default 400px) below the bottom of the level's
`CameraBounds`. In `test_level` that puts it at y=1619, about 660px below where
the player stands.

This is deliberately **not** a `KillZone` node the level has to place. A
forgotten kill zone reproduces exactly the bug this fixes. Deriving it from a
rect every level needs anyway means a new level can't be shipped without one.

The trade: moving the camera bounds moves the kill plane. That's what
`fall_death_margin` is for, and it's why the bounds bottom should sit below your
lowest standable surface. A level with no `CameraBounds` at all falls back to a
fixed drop below the spawn point, so falling is still fatal.

### There is a freeze-frame before the overlay

`GameState.game_over()` pauses immediately but waits `GAME_OVER_DELAY` (0.7s)
before showing the menu, so the death reads on screen instead of being covered
by it. The state is already `GAME_OVER` for that whole window — if you connect
to `state_changed`, don't assume the overlay is up when it fires.

## Debug overlay

`debug_overlay.tscn` is autoloaded as `DebugOverlay` and draws a performance
readout in the top-right corner. **F3** toggles it. It's on by default —
**turn it off before the Windows export**, either by flipping `visible` in the
scene or by dropping the autoload from `project.godot`.

Structured like the pause menu for the same reasons: `process_mode` is `ALWAYS`,
so the numbers keep moving while paused instead of freezing on whatever the
`Esc` press happened to catch, and `layer = 200` puts it above the pause overlay
so it's never covered. Unlike the pause menu it toggles the **CanvasLayer**, not
an inner Control — that file's workaround exists because its buttons would keep
focus while invisible, and nothing here is focusable.

**"Latency" here is frame latency, not network.** The game is single-player, so
the delay you feel is how long a frame takes. Three numbers cover it: the
current frame, the average over a ~8.5s window, and the **1% low** — the
99th-percentile frame time as a framerate. Watch the last one. A hitch in a
run-and-gun reads as input lag, and it barely moves the average or the headline
FPS. Audio output latency is the only other real latency in the build, so it's
on the same block.

Physics time is shown next to `Engine.physics_ticks_per_second` because every
moving thing in this game runs from `_physics_process` — that tick budget
(16.6ms at 60Hz) is the one that matters. The `2D bodies` / `pairs` line climbs
with bullets on screen; the pair count is what gets expensive first.

F3 is deliberately **not** an input action. The input map holds player-facing,
rebindable gameplay actions; a debug toggle is neither, and keeping it out means
it can't collide with a remapping screen later.

## Collision layers

Who can hit whom is decided by layers, not by code. Set on the scene root:

| Layer | Name | Used by |
|---|---|---|
| 1 | world | ground, ledges |
| 2 | player | Player |
| 3 | enemies | Gunslinger |
| 4 | player_bullets | `bullet.tscn`, `pellet.tscn` — mask hits world + enemies |
| 5 | enemy_bullets | `enemy_bullet.tscn` — mask hits world + player |
| 6 | pickups | `saloon_checkpoint.tscn`, `tequila_stash.tscn` — `Area2D`s that mask the player only, so nothing they contain can block a body |

Because enemy bullets don't mask enemies, a gunslinger can't shoot its own kind.
Anything with a `take_damage(amount, from_direction)` method takes hits.

## Camera bounds are per level, not per player

Each level holds a `CameraBounds` node — a `ReferenceRect` in the
`camera_bounds` group — and `player_camera_2d.gd` reads its rect on ready to set
its limits. To change how far the camera may travel in a level, **drag that
rectangle in the 2D editor**; don't touch the player scene. It's `editor_only`,
so it draws in the editor and is invisible at runtime.

Group membership is declared in the `.tscn` rather than added in `_ready()`,
which means it exists at instantiation and doesn't depend on node ready order.
A level with no `CameraBounds` just keeps whatever limits the camera already has.

## Backgrounds

Seven `Parallax2D` layers in `scenes/levels/backgrounds/desert_bg.tscn`, each a
`Sprite2D` on a generated texture (see [below](#the-layer-art-is-generated-not-painted)
— a comic-book greybox, not final art, in the same spirit as the level's
placeholder boxes). It's instanced
by the level, **not owned by `GameState`** — that's the same line the rest of the
project draws: `GameState` owns what every level needs identically (HUD, pause
menu), the level owns what differs (`CameraBounds`, and now the background).

`Parallax2D` rather than the older `ParallaxBackground`, because
`ParallaxBackground` is a `CanvasLayer` and the player camera runs with
`ignore_rotation = false` — under shake roll the world would tilt and the sky
would sit still. `Parallax2D` is a `Node2D`, so it rolls with everything else,
and it brings `scroll_scale`, `repeat_size` and `autoscroll` as properties rather
than as script.

Layers are ordered by explicit `z_index` (sky −100 up to the play plane at 0,
with the dust overlay at +40 — the one layer that draws over the player), and
`scroll_scale` runs 0 → 1.2. Anything above 1.0 reads as foreground.

### How wide a layer has to be

A layer's local origin is drawn at world `(1 − scroll_scale) × camera_top_left`,
so a child at local `x` lands at screen `x − scroll_scale × T.x`. Covering the
camera's whole travel therefore needs

```
width = V + scroll_scale × (B − V)
```

Two things about those terms are easy to get wrong, and both were measured rather
than assumed:

- **`V` is the viewport width at your widest aspect, not 1920.**
  `stretch/aspect` is `keep_height`, so an ultrawide monitor genuinely reveals
  more world — 2560 at 21:9. Budget against that.
- **`B` is not the `CameraBounds` width.** `Camera2D` applies `offset` *after* its
  limits, and the camera puts up to `lookahead_distance` (260px) into `offset`, so
  the view escapes the bounds by that much on each side. `B = CameraBounds.width
  + 2 × lookahead_distance` — 4560 in `test_level`, not 4040. The visible world
  rect really does reach x −360 against a bounds edge of −100. **Raise
  `lookahead_distance` and every fixed-width layer has to widen with it.**

The useful ceiling: no layer ever needs to be wider than `B`, since at
`scroll_scale = 1` the formula collapses to it.

### The layer art is generated, not painted

```
python tools/gen_background.py
```

Rebuilds all seven PNGs into `assets/backgrounds/generated/`. **Don't hand-edit
them — edit the generator.** The look and the entire palette come from
`assets/backgrounds/background_reference.png`: a western comic panel of flat
fills, heavy black ink outlines, hard-edged lit facets, print halftone and paper
grain. That style is reproducible procedurally in a way a painted background is
not, which is the only reason this exists. It is a good greybox standing in for
real art, in the same spirit as the level's placeholder boxes — **not** the
hand-painted direction at the top of this file.

### Three shape rules, and why

The first version of this generator built its terrain from a height field of
integer-frequency sines. It tiled perfectly and it looked like nothing on earth:
rolling lumps at every scale, an "uneven" horizon, and column-derived highlights
that came out as vertical stripes. What replaced it:

- **The desert floor is flat.** Horizons are level to within a few pixels. A
  visibly undulating ground line is the loudest possible tell that terrain was
  generated rather than drawn, and the reference has none.
- **Relief is explicit faceted forms, not a height field** — `cone_points` and
  `butte_points` return polygons with a named peak, so the lit face and the
  erosion strokes can be drawn *from* that peak. A height field has no peak to
  draw from. Two numbers decide whether a cone reads as a mountain or as a
  circus tent: a base:height ratio near **4:1**, and `flare` near **1.5** (past
  ~1.7 the summit flattens into a dome, at 1.0 it's a road sign). The sub-peak
  `cone_points` inserts on one flank is doing more work than either.
- **Depth is value, not detail.** Each layer blends its fills toward paper by a
  fixed `haze` fraction, so the range steps pale-far to saturated-near. Layers
  sitting at the same lightness cannot be separated by adding linework; that
  just adds noise.

Three things in it are load-bearing:

- **Tiling is no longer free.** The old sine profiles closed on themselves by
  construction; discrete faceted shapes do not. Every shape on a tiling layer
  must be drawn through `wrap_x(pitch)` at `-pitch`, `0` and `+pitch`, and no
  shape may be wider than the pitch — PIL clips at the canvas edge, so a cloud
  straddling the boundary is otherwise cut in half with the neighbouring copy
  starting fresh.
- **Facets and linework are clipped to the shape they belong to**, by building
  each landform as its own tile (`relief`) or local stamp (`boulder`) and
  masking with `clip_to`. Deriving a lit face from the *finished layer's* alpha
  instead — which the old `lit_faces` did, via `argmax` down each column —
  reads row 0 for every transparent column, so each silhouette edge became a
  phantom slope with a wedge hanging off it.
- **The generator asserts its canvas sizes against its own `LAYERS` table and
  prints them on every run**, including each layer's bottom edge. That table is
  the same geometry as `desert_bg.tscn`, kept in sync by hand — if what it
  prints stops matching the scene, a layer has been resized and the coverage
  budget is stale. Note the assert can only catch the *generator* drifting;
  editing `LAYERS` without editing the matching `Sprite2D` position in the
  `.tscn` passes it and silently misplaces the layer.

### Layer heights grow upward

Saguaros and buttes stand up from their ground line, so each canvas needs
headroom above it. **No layer's `local y + h` may move** — it is 1600 for the
four terrain layers, 800 for the clouds, 1400 for the sky and 1420 for the
foreground — and heights were grown by moving the origin up. That invariant
is what makes the headroom free: `check_bg_coverage.gd` measures the *bottom*
edge, so growing a layer upward cannot invalidate the width budget, and widths
were not touched at all.

`HORIZON` in the generator holds each layer's ground line in world y. Those
values are tuned against each other rather than derived: the layers scroll
vertically at different rates, so what stacks on screen is a product of those
rates. The gap between `buttes` (820) and `near_rocks` (956) is the one to
watch — they carry the two inked horizons the player actually sees, and closer
together they land ~30px apart on screen and read as railway track.

**After regenerating, re-import before checking coverage:**

```
Godot_v4.7.2-stable_win64.exe --headless --path . --import
```

`--script` does not reimport changed textures. Skip it after a size change and
the check measures the *old* texture — which shows up as a bottom-margin
shortfall exactly equal to how far the origin moved.

The sun is painted into the sky layer, which has `scroll_scale.x = 0`. That's
deliberate: a sun at infinity shouldn't slide as the player runs, and the
screen-lock also means the sky covers any viewport width for free.

Camera **shake** escapes the limits the same way — it writes `offset` and
`rotation` on top of the look-ahead — but it is deliberately *not* in the
formula. Shake moves the parallax layers and the viewport together, so only
`scroll_scale × shake` shows up as a differential, and that's easier to measure
than to derive. The authored widths are the formula plus ~170px of slack.

### Checking it

```
Godot_v4.7.2-stable_win64.exe --path . --script res://tools/check_bg_coverage.gd
Godot_v4.7.2-stable_win64.exe --path . --script res://tools/check_bg_coverage.gd --resolution 2560x1080
```

Parks the camera at both ends of the level and at the top of the climb, extends
look-ahead fully, pins trauma at maximum for 40 frames, and prints **how many
pixels of margin each layer has left** at its worst — plus a PNG per position so
the composition can be looked at. Non-zero exit if anything has run out.

**Re-run it after moving a `CameraBounds` rect or retuning the camera.** The
per-layer widths in `desert_bg.tscn` are hand-copied numbers derived from
`CameraBounds`, `lookahead_distance` and `max_offset`, and nothing else catches
them going stale — the same reason `slice_player_sheet.py` prints the muzzle
constants on every run.

This is not a formality. The `Camera2D.offset`-escapes-the-limits overrun above
was found by this check and not by the screenshots: the layers were short by
98–188px on one side and it wasn't visible in a rendered frame, because nearer
geometry happened to cover the gap at the camera positions that were looked at.

### Tiling vs. fixed width is an art-brief decision

Sky, clouds, ridge, mesas and dust set `repeat_size` and opt out of the width
budget entirely; buttes and near rocks are fixed-width. That's the fork, and it
lands in the commission spec rather than in code:

- **Fixed width** is cheaper to paint, but the layer's width becomes a dependency
  of `CameraBounds`. Drag that rect wider in the 2D editor and the layer's edge
  slides into frame — the same trade the kill plane makes with
  `fall_death_margin`.
- **`repeat_size`** makes width stop mattering, at the cost of art that must tile
  seamlessly on x.

"≥3700px wide" and "seamlessly tileable horizontally" are different deliverables
and, per `CREDITS.md`, expensive to retrofit after delivery. Decide per layer
before commissioning.

The sky is a `GradientTexture2D`, not a painted texture. Two flat rects put a hard
line across the frame with no silhouette to hide the seam, and a sky is the case a
texture handles worst — VRAM compression bands smooth gradients badly. The real
art may well keep the gradient and only paint the clouds.

Drift on the clouds and the dust is `autoscroll`: one property, no code.

## Where things stand

Verified by a headless import + instantiation pass: the project imports with no
errors, all ten input actions are registered, `test_level.tscn` instantiates,
and `player.gd` compiles and attaches. The weapon list survives the `.tscn` round
trip (both weapons load with their numbers), one shotgun press spawns six pellets
on six evenly-spaced symmetric trajectories, held fire doesn't repeat a
semi-automatic while the revolver auto-fires on schedule, and a revolver bullet's
travel vector is numerically unchanged by the angle support added for spread. The
HUD weapon row was checked against a **rendered frame**, not just the node tree:
the slots sit clear of the health pips, the lit slot follows the switch, and
appending to `weapons` at runtime grows the row on the next frame. Every parallax
layer covers the frame with at least **163px** to spare at both ends of the level
and up on the Perch, at 16:9 and 21:9, with look-ahead extended and shake at peak
— re-checkable with `tools/check_bg_coverage.gd`. (That was ~170px before the
`CameraBounds` rect was nudged ~15px left in the editor; the rect's *width* is
unchanged at 4040, so the budget formula still holds, but the slack on the left
edge is now the number to watch.) The pause lifecycle is covered by a
headless run too — pause freezes the player but not the menu, resume restores,
and "Main Menu" from the pause screen leaves the tree unpaused. The flask and the
saloon are covered by `tools/check_flask.gd`: the charge clamps hold at both
ends, a swig spends on the press and heals late without overhealing, firing is
refused mid-swig, resting refills both bars and records the checkpoint, Retry
resolves to it and falls back to the level spawn when there is none — and the new
flask row's rect clears both the health pips and the weapon slots, checked
against a rendered frame as well as by intersection. **Gameplay feel is still
unplayed** — that needs a human on F5, and the flask timings
(`drink_duration` 0.65s, `drink_heal_delay` 0.45s) are a first guess.

Note that `--headless --path . --quit` now boots the *menu*, since that's
`main_scene`. To headlessly smoke-test the level, name it explicitly:

```
Godot_v4.7.2-stable_win64.exe --headless --path . res://scenes/levels/test_level.tscn --quit
```

- [x] Project config, input map, collision layers
- [x] Player movement — run, jump, coyote time, jump buffering, variable jump height (play-tested, feels good)
- [x] Shooting — bullets, muzzle flash, recoil, screen shake, impact puffs
- [x] Weapon system — Resource per weapon, Q/E cycling, HUD slot row; revolver + shotgun (**feel unplayed**, numbers are a first pass)
- [x] Enemy — patrol, line of sight, returns fire, dies; player takes damage and can be killed
- [x] Camera — look-ahead, per-level bounds, vertical drag deadzone, shake
- [x] Crouch and slide — shorter hitbox ducks enemy fire, headroom-checked stand-up
- [x] Main menu + GameState scene routing
- [x] Pause menu — Esc/Start toggle, resume / main menu / quit, Space-vs-jump collision resolved
- [x] Game over — death by damage or by falling out of the level, retry / main menu / quit
- [x] Health HUD — pip row top-left, survives scene swaps; values still unbalanced
- [x] Tequila flask — `F` to drink, charge spent on the press and health late,
      no firing mid-swig, HUD charge row built from the maximum; guarded by
      `tools/check_flask.gd`
- [x] Saloon checkpoints — rest to refill health + flask, record the respawn and
      reload the level; death and Retry come back there. **Session-only, no disk
      save.**
- [x] Tequila Stash pickup — one charge, never past the maximum
- [ ] Agave Heart / Silver Flask Cap / Gold Nugget — the shape is there
      (`tequila_stash.gd`), the items aren't
- [ ] A drinking pose — the sheet has none, so the swig is carried by a warm
      tint and a puff and the player keeps whatever clip they were on
- [ ] Saving checkpoints to disk
- [x] Debug overlay — F3, frame timings + 1% low, render/memory/physics counters
- [x] Player animation — sheet sliced to a 9-clip SpriteFrames, driven off the existing movement states
- [x] Character effects — squash/stretch, recoil lean, dust on takeoff/land/run/
      slide/skid, muzzle smoke, and a code-drawn flash for the poses the sheet
      doesn't paint one for; guarded by `tools/check_player_fx.gd`
- [x] Sound — footsteps off the run clip's contact frames, a slide scrape loop,
      per-weapon gunfire and bullet impacts on anything that bleeds; pooled
      through the `Sfx` autoload and guarded by `tools/check_sfx.gd`.
      **Samples are generated placeholders** (`tools/gen_sfx.gd`), swappable for
      real recordings with no code change
- [ ] The rest of the sounds — jump, landing, weapon switch, drinking, taking
      damage, enemy death, bullets on terrain. All one-liners now that the
      autoload and the `AudioStream` slots exist
- [ ] Music, an SFX bus and a volume slider in the options the game doesn't have
- [ ] Player firing *poses* for run / jump / crouch-walk — the sheet has none, so
      shooting on the move still isn't acted out (the flash is now drawn, the
      pose isn't)
- [x] Parallax background — 7 `Parallax2D` layers, per-level scene, coverage
      guarded by `tools/check_bg_coverage.gd`; layer art generated by
      `tools/gen_background.py` from the reference (greybox, not final art)
- [ ] Level built from real geometry rather than placeholder boxes
- [ ] Enemy and projectile art
- [ ] Lighting / particles polish pass
- [ ] Windows export

## Tuning the movement

Everything in `scenes/player/player.gd` is `@export`ed, so select the Player node
and adjust it in the inspector while the game runs.

**Do this before commissioning any animation.** An artist animates a run cycle and
a jump arc against your actual numbers — if you change `jump_time_to_peak` after
the art is delivered, you pay for reanimation. Lock the feel first, then hand the
final values to the artist as a spec.

Distances (`run_speed`, `jump_height`, `max_fall_speed`) are pixels against a
1920×1080 viewport where the player is ~170px tall. Timings (`jump_time_to_peak`,
`coyote_time`, the accel/decel times) are in seconds and don't change if you
rescale. `jump_height` is the literal peak height in pixels — the default 250 is
about 1.5 character heights. Rise and fall are timed separately on purpose; a fall
faster than the rise is what stops a jump feeling floaty.
