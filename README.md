# Wester Shoota

A western run-and-gun sidescroller. Godot 4.7 (Standard / GDScript), targeting a
desktop executable.

**Art direction:** hand-painted / illustrated HD 2D (Ori, Hollow Knight lineage) —
**not** pixel art. Authored at 1920×1080. Prototyping with placeholder rectangles
now; real art to be commissioned once the game proves out.

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
| Pause | `Esc` | Start |
| Confirm in menus | `Enter` | A |
| Debug overlay | `F3` | — |

Whether shooting is auto-fire while held or one shot per press is **per weapon**
— the `automatic` flag on its `.tres`, not a code change. The revolver holds,
the shotgun taps. See [Weapons](#weapons).

Note that crouch shares the down binding, so a gamepad player pushing the stick
down to aim will crouch. Fine for now; worth revisiting if aiming down is added.

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
scenes/player/     player.tscn, player_camera_2d.gd
scenes/enemies/    gunslinger.tscn
scenes/projectiles/  bullet.gd is shared — bullet.tscn, pellet.tscn and
                     enemy_bullet.tscn differ only in numbers, colour and layers
scenes/fx/         impact_puff.tscn
scenes/levels/     test_level.tscn
scenes/ui/         main_menu.tscn, pause_menu.tscn, game_over_menu.tscn
                   hud.tscn — health readout, owned by GameState
                   debug_overlay.tscn — autoloaded as DebugOverlay
scripts/globals/   game_state.gd — autoloaded as GameState
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
the **top-left** corner — `hud.tscn`, with the weapon slots directly underneath.
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

## Death and game over

**Death is terminal.** `Player.die()` hands off to `GameState.game_over()`,
which freezes the tree and puts up `game_over_menu.tscn` — Retry / Main Menu /
Quit. Retry reloads the level from the top. The player no longer respawns in
place; that quietly undid the death and made it easy to miss that you'd lost.

Two ways in: health reaching zero, and falling out of the level.

`Esc` is deliberately inert on the death screen. Death isn't something you
un-pause your way out of, so `_unhandled_input` ignores `pause` in `GAME_OVER`.

### The kill plane comes from CameraBounds

Falling used to be survivable-by-accident — nothing detected it, so you dropped
for ever. The fix reuses the rect the level already has: the kill plane sits
`fall_death_margin` (default 400px) below the bottom of the level's
`CameraBounds`. In `test_level` that puts it at y=1580, 560px below where the
player stands.

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

## Where things stand

Verified by a headless import + instantiation pass: the project imports with no
errors, all eight input actions are registered, `test_level.tscn` instantiates,
and `player.gd` compiles and attaches. The weapon list survives the `.tscn` round
trip (both weapons load with their numbers), one shotgun press spawns six pellets
on six evenly-spaced symmetric trajectories, held fire doesn't repeat a
semi-automatic while the revolver auto-fires on schedule, and a revolver bullet's
travel vector is numerically unchanged by the angle support added for spread. The
HUD weapon row was checked against a **rendered frame**, not just the node tree:
the slots sit clear of the health pips, the lit slot follows the switch, and
appending to `weapons` at runtime grows the row on the next frame. The pause lifecycle is covered by a
headless run too — pause freezes the player but not the menu, resume restores,
and "Main Menu" from the pause screen leaves the tree unpaused. **Gameplay feel
is still unplayed** — that needs a human on F5.

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
- [x] Debug overlay — F3, frame timings + 1% low, render/memory/physics counters
- [ ] Level built from real geometry rather than placeholder boxes
- [ ] Commissioned art
- [ ] Lighting / parallax / particles polish pass
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
