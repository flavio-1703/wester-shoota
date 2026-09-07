class_name Weapon
extends Resource

## One weapon's stat block. A `.tres` per weapon lives beside this file; the
## player carries a list of them and fires whichever is current.
##
## Why a Resource rather than a scene or a subclass of the player: a weapon is
## data, not behaviour. The firing code is identical for all of them — spawn n
## projectiles in a fan, kick the player back, shake the camera — so what
## separates a revolver from a shotgun is a row of numbers. Adding a weapon then
## means adding a `.tres` in the inspector and dropping it in the player's list,
## with no code at all, which is what makes drip-feeding them later cheap.
##
## **A `.tres` is one shared object**, not a copy per holder. Nothing here may
## ever be written to at runtime — two players, or a player and a pickup, would
## be looking at the same instance. Per-holder state (the fire cooldown, and
## ammo if it's ever added) belongs on whoever is holding the weapon; the player
## already keeps `_fire_cooldown` for exactly this reason.
##
## Damage, speed and range are deliberately *not* here. They belong to the
## projectile scene — see the pellet/bullet split in `scenes/projectiles/`,
## which already works this way for the player/enemy variants.

## Shown by the HUD.
@export var display_name: String = "Weapon"
## Colour of this weapon's slot swatch in the HUD — a placeholder standing in for
## an icon, in the same spirit as the rectangles everything else is prototyped
## with. It lives here rather than in the HUD so that adding a weapon stays a
## one-file job: a new `.tres` brings its own swatch and the HUD needs no edit.
@export var ui_color: Color = Color(0.8, 0.8, 0.8)
## What one trigger pull spawns, `pellets` times over.
@export var projectile_scene: PackedScene

@export_group("Fire")
## Seconds between shots. With `automatic` off this is the floor on how fast you
## can tap, not a rate.
@export var fire_interval: float = 0.18
## True holds down to keep firing (run-and-gun convention), false is one shot per
## press — the single-action feel, and what a shotgun wants.
@export var automatic: bool = true
## Projectiles per shot. Above 1 they come out in an even fan across
## `spread_degrees`.
@export_range(1, 24) var pellets: int = 1
## Total cone width in degrees, from the topmost pellet to the bottom one.
@export_range(0.0, 90.0) var spread_degrees: float = 0.0

@export_group("Feedback")
## Backward velocity kick per shot. Has to clear ~167 px/s (one frame of the
## player's run accel curve) or it reads as nothing at all.
@export var recoil_impulse: float = 350.0
## Screen shake per shot.
@export var trauma: float = 0.35
@export var muzzle_flash_time: float = 0.05
## Fired once per trigger pull, not once per pellet — see Player._handle_shoot().
##
## A stream is data, so it belongs here with the rest of what separates one
## weapon from another; it is also read-only, which is what keeps this inside the
## rule above about never writing to a shared `.tres`. The playback itself is the
## Sfx autoload's, and no state for it lives on this resource.
@export var fire_sound: AudioStream
@export_range(-40.0, 12.0) var fire_volume_db: float = 0.0


## Deviation from horizontal for pellet `index`, in radians.
##
## An even fan rather than a random scatter: predictable pellet placement is far
## easier to tune, and in a sidescroller you want the player to learn where the
## spread lands rather than re-roll it every shot.
func pellet_angle(index: int) -> float:
	if pellets <= 1 or is_zero_approx(spread_degrees):
		return 0.0
	var half := deg_to_rad(spread_degrees) * 0.5
	return lerpf(-half, half, float(index) / float(pellets - 1))
