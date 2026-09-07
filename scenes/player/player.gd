class_name Player
extends CharacterBody2D

## Run-and-gun player controller.
##
## Jump is specified as a height and two timings rather than a velocity and a
## gravity constant, so the exported values mean something you can see on screen:
## jump_height is how many pixels you actually clear. Rise and fall are timed
## separately because a faster fall than rise is what makes a platformer feel
## snappy rather than floaty.
##
## Distances below are in pixels against a 1920x1080 viewport, where the player
## is roughly 170px tall. Timings are in seconds and are therefore
## resolution-independent — if you rescale the game, change the distances and
## leave the timings alone.

## Crouching and sliding swap to a shorter collision shape, which is what lets
## you duck under enemy fire. The shapes live in the scene; the matching poses
## and muzzle offsets come from the sprite sheet, so changing a shape's height
## no longer moves the art on its own — see MUZZLE, which is keyed on the firing
## pose rather than on the stance.
enum State { NORMAL, CROUCH, SLIDE }

## Emitted on every change to `health`, including the reset on respawn. `total`
## is max_health, so a readout can size itself from the signal alone and never
## has to reach back into the player.
signal health_changed(current: int, total: int)

## Emitted on every change to `weapon`, including the opening one in _ready.
## Same contract as health_changed, for the same reason: a readout that only
## heard about switches would start blank.
signal weapon_changed(weapon: Weapon)

## Emitted on every change to `flask_charges`, including the opening fill in
## _ready. Same contract as health_changed — `total` is flask_charges_max, so the
## readout can size itself from the signal alone.
signal flask_changed(current: int, total: int)

## Where the revolver's muzzle sits in each firing POSE, in Visuals-local pixels
## for a right-facing player. Measured off the muzzle flashes painted into the
## sprite sheet rather than derived from the collision height, because a firing
## pose reaches much further forward than a fraction of the stance height would
## predict. tools/slice_player_sheet.py prints all three on every run.
##
## Per pose and not per stance, which is the change sheet 3 forced: it draws
## three different firing poses where sheet 2 drew one, and their barrels are
## 37px apart in x and 39px in y. Keying this on the stance would have put every
## running shot a body-width behind the gun.
const MUZZLE_STAND := Vector2(72, -136)
const MUZZLE_RUN := Vector2(109, -106)
const MUZZLE_AIR := Vector2(79, -145)
## The one that isn't measured. Sheet 3 dropped the crouched firing pose sheet 2
## had — no crouch frame draws a gun at all, and the kneel's only visible hands
## are the face-height one at (+23, -82) and a trailing one at (-29, -31), so
## there is not even a hand to hang it on. This is the front of the chest at the
## silhouette's leading edge, which reads as firing from the hip.
## See ANIMATION.md > Known gaps.
const MUZZLE_CROUCH := Vector2(30, -62)

## Muzzle offset per firing pose, so bullets leave the barrel the player can
## actually see. `slide` is in here because you can fire mid-slide even though
## the slide poses draw no gun; it borrows the crouch offset, which is the
## closest thing to right for a body that low.
const MUZZLE: Dictionary = {
	&"shoot": MUZZLE_STAND,
	&"run_shoot": MUZZLE_RUN,
	&"jump_shoot": MUZZLE_AIR,
	&"crouch": MUZZLE_CROUCH,
	&"crouch_walk": MUZZLE_CROUCH,
	&"slide": MUZZLE_CROUCH,
}

## How long the firing pose stays up after a shot. Independent of the weapon's
## `muzzle_flash_time`, which is far shorter than a readable pose: the revolver
## flashes for 0.05s. Held fire keeps re-arming this, so the pose persists for as
## long as the trigger is down.
const SHOOT_POSE_TIME := 0.25

## How long the landing clip holds before idle takes over.
const LAND_POSE_TIME := 0.14

## The clips that are a full two-step locomotion cycle: they get time-scaled to
## the speed the body is travelling, they bob, and they fire footsteps. Both are
## authored at the same fps, but each is measured off the resource rather than
## assumed — see _measure_run_cycles().
const RUN_CYCLE_CLIPS: Array[StringName] = [&"run", &"run_shoot"]

## Where in each run cycle the leading boot is flat on the ground, in frames,
## measured off the sheet at the widest point of the boot band and printed by
## tools/slice_player_sheet.py on every run. The second contact is half a cycle
## later — both clips are two steps — so 7 and 3 are the same value here, as are
## 6 and 2.
##
## The two clips do not agree, and that is the art rather than a mistake: the
## slicer scores pairs of frames half a cycle apart and `run`'s best pair is
## (3, 7) while `run_shoot`'s is (2, 6). run_shoot's is also the more symmetric
## of the two — 117 against 117px, versus 101 against 121 for run.
##
## Used by both the run bob (which puts its low points here) and the footstep
## sounds (which fire here). Shared so the sound and the bounce cannot drift
## apart: a step you hear at a different moment from the one you see is worse
## than either being slightly off on its own.
const RUN_CONTACT_PHASE: Dictionary = {&"run": 7.0, &"run_shoot": 6.0}

## The sprite's authored scale — the 168px figure on the sheet against the 170px
## collision box (see ANIMATION.md). Squash and stretch multiply it, so it has
## to be a constant here: reading the node's current scale back would compound
## the squash every frame.
const SPRITE_SCALE := 1.0

## Clips that snap back to frame 0 on every shot, so the painted flash keeps
## step with the bullet leaving the muzzle.
##
## Only the standing pose. `run_shoot` and `jump_shoot` have flashes painted in
## too, but restarting them would pin the legs to the first two frames of the
## cycle at a revolver fire_interval of 0.18s — and those are the two frames of
## the strip with no flash drawn, so it would suppress the very thing the
## restart exists to synchronise. Left free-running, six of run_shoot's eight
## frames and four of jump_shoot's five are flashing anyway.
const SHOT_SYNCED_CLIPS: Array[StringName] = [&"shoot"]

## Clips that can be on screen when a shot goes off but have no flash painted
## in, where a code-drawn one fills the hole. Only that hole: drawing one over a
## painted pose would flash the shot twice.
##
## Sheet 3 covers running and airborne fire, so this is down to the crouch,
## which lost its firing pose in the redraw — no crouch frame draws a gun at
## all. The flash is at an estimated hand rather than a drawn barrel, and it
## stays on because crouching is a sustained combat stance: without it, ducking
## and firing has no feedback beyond the bullet itself.
##
## `slide` is deliberately absent even though you can fire mid-slide. It lasts
## 0.45s and the poses have the character's arms out for balance, so a flash
## there reads as coming from an empty hand; that one stays a job for the art.
const UNPAINTED_FLASH_CLIPS: Array[StringName] = [&"crouch", &"crouch_walk"]

@export_group("Run")
## ~3 seconds to cross the screen.
@export var run_speed: float = 600.0
## How far the character's feet carry it in ONE step, in screen pixels — the
## horizontal gap between the boots at full extension, times the sprite scale.
##
## This is what stops the run skating. Both RUN_CYCLE_CLIPS are a full cycle of
## two steps, so at speed `v` the cycle has to last `2 * run_stride / v` seconds;
## the clip is then time-scaled to fit. Left at its authored length it covered
## 360px per cycle against a drawn step of ~120px, so the character slid a
## quarter of the way.
##
## Measured off the sheet, so **re-measure it if the run art changes**: the boot
## band of the widest frame is the number, and tools/slice_player_sheet.py
## prints it. Raising it makes the legs turn over slower; lowering it, faster.
@export var run_stride: float = 121.0
## Bounds on the time-scaling, so a crawl doesn't freeze the cycle and a speed
## boost doesn't blur it into a scribble.
@export var run_cycle_scale_range := Vector2(0.45, 2.2)
## Seconds to go from a standstill to full speed.
@export var ground_accel_time: float = 0.06
@export var ground_decel_time: float = 0.08
@export var air_accel_time: float = 0.12
@export var air_decel_time: float = 0.20

@export_group("Jump")
## Peak height in pixels — about 1.5 character heights.
@export var jump_height: float = 250.0
@export var jump_time_to_peak: float = 0.38
@export var jump_time_to_fall: float = 0.30
@export var max_fall_speed: float = 1400.0

@export_group("Feel")
## Grace period after walking off a ledge where a jump still counts.
@export var coyote_time: float = 0.10
## Jump pressed slightly before landing is remembered this long.
@export var jump_buffer_time: float = 0.12
## Upward velocity kept when the jump button is released early.
@export var jump_cut_multiplier: float = 0.45

@export_group("Crouch and slide")
## Shuffle speed while crouched.
@export var crouch_speed: float = 200.0
## Launch speed of a slide.
@export var slide_speed: float = 950.0
## How long a slide lasts before it drops back to a crouch or a stand.
@export var slide_duration: float = 0.45
## Seconds the slide takes to bleed off its speed.
@export var slide_friction_time: float = 0.7
## You must already be running this fast for a crouch press to become a slide.
@export var slide_min_speed: float = 320.0
@export var slide_cooldown: float = 0.25
@export var slide_trauma: float = 0.15

@export_group("Shooting")
## Everything the player can fire, in cycle order; index 0 is what they start
## with. Every number that separates one weapon from another lives in the `.tres`
## — see weapon.gd — so this list is the whole of the player's side of it.
##
## Unlock gating will eventually decide what's in here. For now it's the full
## set, so all of them can be play-tested.
@export var weapons: Array[Weapon] = []

@export_group("Health")
## How far below the level's camera bounds counts as having fallen out of the
## world. See _compute_fall_death_y() for why the bounds are the anchor.
@export var fall_death_margin: float = 400.0
@export var max_health: int = 5
## Grace window after being hit, so a burst of fire can't delete you.
@export var invulnerable_time: float = 0.9
@export var hit_flash_time: float = 0.12
@export var hit_knockback: float = 320.0
@export var hit_trauma: float = 0.5

@export_group("Tequila flask")
## Swigs carried. This is per-player mutable state and deliberately NOT a shared
## Resource, for the same reason `_fire_cooldown` isn't one: a `.tres` is a single
## object, so a flask on one would be everybody's flask. See README > Weapons.
##
## Raising this at runtime is what an `Agave Heart` pickup will do; the HUD
## rebuilds its charge row off it, so nothing else needs editing.
@export var flask_charges_max: int = 3
## Health pips restored per swig. A `Silver Flask Cap` will raise this.
@export var flask_heal_amount: int = 1
## How long the whole swig takes. Deliberate enough that drinking mid-firefight
## is a decision, short enough not to be annoying in a prototype.
@export var drink_duration: float = 0.65
## How far into the drink the healing actually lands, measured from the press.
## Must be less than `drink_duration` — the tail is the recovery, where you have
## already paid the charge and are still committed.
@export var drink_heal_delay: float = 0.45

@export_group("Juice")
## Kicked-up dust: takeoff, landing, running, sliding, skidding, and the smoke
## off the muzzle. One scene for all of them — the spawner varies velocity, size
## and lifetime rather than there being a scene per effect.
@export var dust_scene: PackedScene
## Drawn only over UNPAINTED_FLASH_CLIPS. See that constant.
@export var muzzle_flash_scene: PackedScene
## Peak stretch while airborne, as a fraction of height. Positive is tall and
## thin; the sprite loses in width what it gains in height.
@export var air_stretch: float = 0.15
## Vertical speed at which airborne stretch reaches `air_stretch`.
@export var air_stretch_speed: float = 900.0
## Squash on landing at full `max_fall_speed`. Scaled by actual impact speed, so
## a hop off a ledge barely registers and a long drop really compresses.
@export var land_squash: float = 0.3
## Units of squash/stretch shed per second.
@export var squash_recover_speed: float = 2.6
## Radians the sprite leans back on firing.
@export var recoil_lean: float = 0.08
@export var recoil_lean_time: float = 0.12
## Pixels the body lifts at the passing phase of the run. The art has no vertical
## travel at all — every run frame's feet are on the same line — so this supplies
## it. Set to 0 to go back to the flat cycle; if run_shoot/bob art ever lands,
## turn it off rather than fighting it.
@export var run_bob: float = 7.0
@export var run_dust_interval: float = 0.17
@export var run_dust_min_speed: float = 260.0
@export var slide_dust_interval: float = 0.045
## Impacts softer than this land silently — otherwise every stair-step puffs.
@export var land_dust_min_speed: float = 420.0
@export var skid_min_speed: float = 300.0
@export var skid_dust_interval: float = 0.09

@export_group("Audio")
## Boots on dirt. Picked round-robin so consecutive steps alternate — one sample
## on repeat reads as a machine rather than a person. Two is enough; more is a
## matter of dropping them in the array.
##
## The slide's loop is NOT here: it lives on the SlideSfx node in player.tscn,
## because a loop needs a player of its own to be started and stopped rather than
## a voice borrowed from the Sfx pool.
@export var footstep_sounds: Array[AudioStream] = []
@export_range(-40.0, 12.0) var footstep_volume_db: float = -9.0

## 1 for right, -1 for left. Read by the muzzle and by anything that needs to
## know which way the player is pointed.
var facing: int = 1
## Read freely; write only through _set_health(), or the HUD misses the change.
var health: int
## Swigs left. Same contract as `health`: write only through
## _set_flask_charges(), which clamps to 0..flask_charges_max and emits.
var flask_charges: int
## The weapon currently in hand. Read-only — it's a shared Resource, so writing
## to its fields would edit that weapon for everyone holding it. Switch with
## _set_weapon().
var weapon: Weapon
var state: State = State.NORMAL

var _weapon_index: int = 0

var _spawn_point: Vector2
var _fall_death_y: float
var _dead: bool = false
var _invuln_timer: float = 0.0
var _hit_timer: float = 0.0
var _jump_velocity: float
var _jump_gravity: float
var _fall_gravity: float
var _coyote_timer: float = 0.0
var _jump_buffer_timer: float = 0.0
var _fire_cooldown: float = 0.0
var _shoot_pose_timer: float = 0.0
var _land_timer: float = 0.0
var _slide_timer: float = 0.0
var _slide_cooldown_timer: float = 0.0
## Counts down from `drink_duration`. Non-zero means a swig is in progress, which
## is both the "don't drink again" latch and the gate on shooting and sliding.
var _drink_timer: float = 0.0
## Raised on the press and cleared when the heal lands, so the charge is spent up
## front and the health arrives late. Without it a re-press during the recovery
## tail would heal twice off one charge.
var _drink_heal_pending: bool = false
## This frame's steering input, cached by _handle_move() so the animation can
## tell "running" from "sliding to a halt" without polling Input a second time.
var _move_input: float = 0.0
var _was_on_floor: bool = true
## Positive is stretched (tall, thin), negative is squashed. Driven by vertical
## speed while airborne and impulsed on landing; decays back to 0.
var _stretch: float = 0.0
var _recoil_timer: float = 0.0
var _dust_timer: float = 0.0
var _skid_cooldown: float = 0.0
## Authored length of each RUN_CYCLE_CLIPS entry in seconds, read off the
## SpriteFrames rather than hardcoded, so retiming a clip in
## build_sprite_frames.py doesn't silently desync the cadence matching from it.
var _cycle_time: Dictionary = {}
## Raised by _handle_shoot() and cleared by _update_animation(). Without it the
## firing clip free-runs: `shoot` loops in 0.25s and the revolver fires every
## 0.18s, so held fire would drift the painted flashes out of step with the
## bullets actually leaving the muzzle.
var _shot_this_frame: bool = false
## Last `run` frame index seen by _update_footsteps(), so it can spot the moment
## the clip crosses INTO a contact frame rather than firing for every frame the
## sprite happens to be sitting on one.
var _prev_run_frame: int = -1
## Alternates the entries of `footstep_sounds`.
var _footstep_index: int = 0

@onready var _visuals: Node2D = $Visuals
@onready var _sprite: AnimatedSprite2D = $Visuals/Sprite
@onready var _muzzle: Marker2D = $Visuals/Muzzle
@onready var _stand_shape: CollisionShape2D = $StandShape
@onready var _crouch_shape: CollisionShape2D = $CrouchShape
@onready var _ceiling_check: ShapeCast2D = $CeilingCheck
@onready var _camera := $Camera2D as PlayerCamera2D
@onready var _slide_sfx: AudioStreamPlayer2D = $SlideSfx


func _ready() -> void:
	_recalculate_jump()
	_set_health(max_health)
	# Explicitly rather than by initialising the var, so the opening fill goes
	# through the one writer and the HUD hears about it like any other change.
	_set_flask_charges(flask_charges_max)
	_set_weapon(0)
	# Ahead of `_spawn_point`, so a checkpointed retry also moves the fall-death
	# fallback with the player. Returns the position the level authored when
	# there is no checkpoint for this level, so an ordinary launch is unchanged.
	global_position = GameState.get_respawn_position(global_position)
	# The camera's own _ready has already run and smoothing is on, so without
	# this it would sweep in from the authored spawn on the first frame after a
	# checkpoint respawn.
	_camera.reset_smoothing()
	_spawn_point = global_position
	_fall_death_y = _compute_fall_death_y()
	_measure_run_cycles()
	add_to_group("player")


## The authored duration of each locomotion cycle, straight off the resource.
func _measure_run_cycles() -> void:
	var frames := _sprite.sprite_frames
	if frames == null:
		return
	for clip in RUN_CYCLE_CLIPS:
		if not frames.has_animation(clip):
			continue
		var fps := frames.get_animation_speed(clip)
		if fps > 0.0:
			_cycle_time[clip] = frames.get_frame_count(clip) / fps


## The kill plane is derived from the level's CameraBounds rect rather than from
## a node the level has to remember to place. A forgotten kill zone is exactly
## the bug this fixes — you fall forever — so every level gets one for free from
## a rect it already needs. The trade is that moving the bounds moves the kill
## plane; that's what `fall_death_margin` is for.
func _compute_fall_death_y() -> float:
	var node: Node = get_tree().get_first_node_in_group(PlayerCamera2D.BOUNDS_GROUP)
	if node is Control:
		return (node as Control).get_global_rect().end.y + fall_death_margin
	# No bounds in this level: still fatal, just at a fixed drop below spawn,
	# rather than falling for ever.
	return _spawn_point.y + fall_death_margin * 4.0


## Derived from the kinematic equations, so the exported height and timings are
## what you get. Call this again if you ever change them at runtime.
func _recalculate_jump() -> void:
	_jump_velocity = -2.0 * jump_height / jump_time_to_peak
	_jump_gravity = 2.0 * jump_height / (jump_time_to_peak * jump_time_to_peak)
	_fall_gravity = 2.0 * jump_height / (jump_time_to_fall * jump_time_to_fall)


func _physics_process(delta: float) -> void:
	# Before anything else, so a corpse doesn't get another frame of gravity,
	# steering and move_and_slide() after the death has already fired.
	if global_position.y > _fall_death_y:
		die()
		return

	_tick_timers(delta)
	# Ahead of the stance, which refuses to start a slide mid-swig, and well
	# ahead of _handle_shoot(), which refuses to fire.
	_handle_drink()
	_update_stance()
	_apply_gravity(delta)
	_handle_jump()
	_handle_move(delta)
	# Before the shot, so a switch and a fire on the same frame use the weapon
	# you just switched to rather than the one you left.
	_handle_weapon_switch()
	# Also before the shot: bullets spawn at the muzzle, and where the muzzle is
	# depends on which firing pose is about to be drawn.
	_place_muzzle()
	# After the move curve so the recoil kick survives into this frame's motion.
	_handle_shoot()

	# Captured before move_and_slide(), which zeroes it against the floor on the
	# very frame the landing happens — so reading it afterwards would score every
	# impact as zero and the landing squash would never fire.
	var impact_speed := velocity.y

	move_and_slide()

	# After move_and_slide(), so is_on_floor() reflects this frame's collisions
	# and the landing is detected on the frame it actually happens.
	if is_on_floor() and not _was_on_floor:
		_on_land(impact_speed)
	_was_on_floor = is_on_floor()

	# The flash has to agree with the clip that was just chosen, so it reads the
	# return value rather than working the state out a second time. `_shot_this_frame`
	# is therefore cleared here, after both have seen it, rather than inside
	# _update_animation().
	var clip := _update_animation()
	_update_shot_fx(clip)
	_shot_this_frame = false

	_update_dust(delta)
	# Reads the clip and the sprite's current frame, so it has to follow
	# _update_animation() rather than sit beside the dust it accompanies.
	_update_footsteps(clip)
	_update_sprite_transform(delta, clip)

	if is_on_floor():
		_coyote_timer = coyote_time


func _tick_timers(delta: float) -> void:
	_coyote_timer = maxf(_coyote_timer - delta, 0.0)
	_jump_buffer_timer = maxf(_jump_buffer_timer - delta, 0.0)
	_fire_cooldown = maxf(_fire_cooldown - delta, 0.0)
	_shoot_pose_timer = maxf(_shoot_pose_timer - delta, 0.0)
	_land_timer = maxf(_land_timer - delta, 0.0)
	_invuln_timer = maxf(_invuln_timer - delta, 0.0)
	_hit_timer = maxf(_hit_timer - delta, 0.0)
	_slide_timer = maxf(_slide_timer - delta, 0.0)
	_slide_cooldown_timer = maxf(_slide_cooldown_timer - delta, 0.0)
	_recoil_timer = maxf(_recoil_timer - delta, 0.0)
	_skid_cooldown = maxf(_skid_cooldown - delta, 0.0)
	_drink_timer = maxf(_drink_timer - delta, 0.0)
	_update_damage_feedback()


# --- Stance ------------------------------------------------------------------

func _update_stance() -> void:
	var wants_crouch := Input.is_action_pressed("crouch")

	match state:
		State.SLIDE:
			if _slide_timer <= 0.0 or not is_on_floor():
				_end_slide(wants_crouch)
		State.CROUCH:
			# Never stand up into a ceiling — you'd be pushed through geometry.
			if (not wants_crouch or not is_on_floor()) and _can_stand():
				_set_state(State.NORMAL)
		State.NORMAL:
			if wants_crouch and is_on_floor():
				var fast_enough := absf(velocity.x) >= slide_min_speed
				# No slide launch mid-swig. Crouching itself is still allowed:
				# it costs nothing, and ducking enemy fire while committed to a
				# drink is exactly the play worth leaving open.
				if Input.is_action_just_pressed("crouch") and fast_enough \
						and _slide_cooldown_timer <= 0.0 and not is_drinking():
					_start_slide()
				else:
					_set_state(State.CROUCH)


func _start_slide() -> void:
	velocity.x = facing * slide_speed
	_slide_timer = slide_duration
	_set_state(State.SLIDE)
	_camera.add_trauma(slide_trauma)
	for i in 4:
		_spawn_dust(global_position + Vector2(-facing * randf_range(0.0, 40.0), -8.0),
			Vector2(-facing * randf_range(120.0, 340.0), randf_range(-110.0, -20.0)), 0.8)


func _end_slide(still_holding_crouch: bool) -> void:
	_slide_cooldown_timer = slide_cooldown
	_slide_timer = 0.0
	# Sliding into a low gap leaves you crouched rather than clipping upright.
	if still_holding_crouch or not _can_stand():
		_set_state(State.CROUCH)
	else:
		_set_state(State.NORMAL)


## Assigned directly rather than via set_deferred: deferred calls land after
## this frame's physics, which would leave a sliding player standing-height for
## the frame they enter a low gap and bounce them off the ceiling.
##
## The slide's scrape loop is started and stopped HERE rather than in
## _start_slide()/_end_slide(), and that is not a stylistic choice.
## _stand_up_to_jump() cancels a slide by clearing `_slide_timer` and calling
## this function directly — it never goes through _end_slide() — so a loop
## bracketed on that pair would keep hissing forever after the first slide you
## jump out of. This is the one choke point every stance change passes through.
func _set_state(new_state: State) -> void:
	if state == new_state:
		return
	var was_sliding := state == State.SLIDE
	state = new_state

	if state == State.SLIDE:
		_slide_sfx.play()
	elif was_sliding:
		_slide_sfx.stop()

	var low := state != State.NORMAL
	_stand_shape.disabled = low
	_crouch_shape.disabled = not low


## Is there room for the standing collision shape where we are now?
func _can_stand() -> bool:
	_ceiling_check.force_shapecast_update()
	return not _ceiling_check.is_colliding()


# --- Movement ----------------------------------------------------------------

func _apply_gravity(delta: float) -> void:
	if is_on_floor():
		return
	var gravity := _jump_gravity if velocity.y < 0.0 else _fall_gravity
	velocity.y = minf(velocity.y + gravity * delta, max_fall_speed)


func _handle_jump() -> void:
	if Input.is_action_just_pressed("jump"):
		_jump_buffer_timer = jump_buffer_time

	if _jump_buffer_timer > 0.0 and _coyote_timer > 0.0 and _stand_up_to_jump():
		velocity.y = _jump_velocity
		_jump_buffer_timer = 0.0
		_coyote_timer = 0.0
		for i in 3:
			_spawn_dust(global_position + Vector2(randf_range(-26.0, 26.0), 0.0),
				Vector2(randf_range(-150.0, 150.0), randf_range(20.0, 90.0)), 0.55)

	# Deliberately outside the branch above: releasing jump must still cut the
	# arc on a frame where the jump itself was refused for lack of headroom.
	if Input.is_action_just_released("jump") and velocity.y < 0.0:
		velocity.y *= jump_cut_multiplier


## Jumping out of a crouch or a slide needs somewhere to stand up into.
func _stand_up_to_jump() -> bool:
	if state == State.NORMAL:
		return true
	if not _can_stand():
		return false
	if state == State.SLIDE:
		_slide_cooldown_timer = slide_cooldown
		_slide_timer = 0.0
	_set_state(State.NORMAL)
	return true


func _handle_move(delta: float) -> void:
	if state == State.SLIDE:
		# No steering mid-slide; it bleeds off to a stop on its own.
		_move_input = 0.0
		var decay := slide_speed / maxf(slide_friction_time, 0.001)
		velocity.x = move_toward(velocity.x, 0.0, decay * delta)
		return

	var input_dir := Input.get_axis("move_left", "move_right")
	_move_input = input_dir

	if not is_zero_approx(input_dir):
		facing = 1 if input_dir > 0.0 else -1
		_visuals.scale.x = facing
		_camera.set_look_direction(facing)

	# Steering hard against the way you are still travelling. Detected here
	# because this is the only place both the input and the pre-turn velocity
	# are in scope; a frame later the accel curve has already eaten the sign.
	if is_on_floor() and _skid_cooldown <= 0.0 and not is_zero_approx(input_dir) 			and absf(velocity.x) > skid_min_speed 			and signf(input_dir) != signf(velocity.x):
		_skid_cooldown = skid_dust_interval
		var away := -signf(velocity.x)
		_spawn_dust(global_position + Vector2(away * 18.0, 0.0),
			Vector2(away * randf_range(180.0, 320.0), randf_range(-80.0, -20.0)), 0.6)

	var speed := crouch_speed if state == State.CROUCH else run_speed
	var moving := not is_zero_approx(input_dir)
	var ramp_time: float
	if is_on_floor():
		ramp_time = ground_accel_time if moving else ground_decel_time
	else:
		ramp_time = air_accel_time if moving else air_decel_time

	var rate := speed / maxf(ramp_time, 0.001)
	velocity.x = move_toward(velocity.x, input_dir * speed, rate * delta)


# --- Shooting ----------------------------------------------------------------

## Whether fire is held or tapped is the weapon's call — `automatic` on the
## `.tres`. Held is the run-and-gun default; the shotgun is one shot per press.
func _handle_shoot() -> void:
	if weapon == null or weapon.projectile_scene == null:
		return
	# Both hands are busy. This is the cost that makes the flask a decision
	# rather than a free button, and it's checked here rather than by clearing
	# `_fire_cooldown` so a held trigger resumes the instant the swig ends.
	if is_drinking():
		return

	var pulled := Input.is_action_pressed("shoot") if weapon.automatic \
			else Input.is_action_just_pressed("shoot")
	if not pulled or _fire_cooldown > 0.0:
		return

	_fire_cooldown = weapon.fire_interval

	for i in weapon.pellets:
		var bullet := weapon.projectile_scene.instantiate()
		bullet.direction = facing
		bullet.angle = weapon.pellet_angle(i)
		# Spawn as a sibling rather than into get_tree().current_scene: that
		# global is null whenever this scene isn't the root one, which breaks the
		# moment a level gets nested under a game-manager scene.
		get_parent().add_child(bullet)
		# Position after reparenting, so global_position isn't reinterpreted.
		bullet.global_position = _muzzle.global_position

	# Outside the pellet loop above, with the recoil and the shake: one trigger
	# pull is one report, however much lead it puts in the air. Inside it, a
	# shotgun would fire six overlapping copies of its own blast.
	Sfx.play_at(weapon.fire_sound, _muzzle.global_position, weapon.fire_volume_db,
		randf_range(0.96, 1.04))

	# Recoil would only fight the slide's own decay curve, so skip it there.
	if state != State.SLIDE:
		velocity.x -= facing * weapon.recoil_impulse
	_camera.add_trauma(weapon.trauma)
	_shoot_pose_timer = SHOOT_POSE_TIME
	_shot_this_frame = true
	_recoil_timer = recoil_lean_time
	# Smoke needs only the muzzle, so it is spawned here at the event. The flash
	# additionally needs to know which clip is playing, so it waits for
	# _update_shot_fx() once the animation has been chosen.
	_spawn_dust(_muzzle.global_position,
		Vector2(facing * 170.0, -80.0), 0.34, 0.45, 0.5)


func _handle_weapon_switch() -> void:
	if weapons.size() < 2:
		return

	var step := 0
	if Input.is_action_just_pressed("weapon_next"):
		step = 1
	elif Input.is_action_just_pressed("weapon_prev"):
		step = -1
	if step == 0:
		return

	_set_weapon(wrapi(_weapon_index + step, 0, weapons.size()))


## The one place `weapon` is written, so the HUD can't be looking at a stale
## name — the same contract `_set_health()` holds for the pip row.
##
## It deliberately leaves `_fire_cooldown` alone. Clearing it on a switch would
## make cycling weapons a way to fire as fast as you can press the switch key,
## which beats every fire_interval in the game.
func _set_weapon(index: int) -> void:
	if weapons.is_empty():
		return
	_weapon_index = clampi(index, 0, weapons.size() - 1)
	weapon = weapons[_weapon_index]
	weapon_changed.emit(weapon)


# --- Tequila flask -----------------------------------------------------------

## A swig is in progress. Read by the shooting and slide gates, and by anything
## that wants to know the player is committed.
func is_drinking() -> bool:
	return _drink_timer > 0.0


## Every reason a swig can be refused, in one place so the HUD, the pickup and
## the input handler all agree on it.
##
## Pause deliberately isn't in the list: this is only ever reached from
## `_physics_process`, which `get_tree().paused` already stops. Adding a check
## here would imply the flask can be drunk from somewhere else, and it can't.
func can_drink() -> bool:
	return not _dead \
		and not is_drinking() \
		and flask_charges > 0 \
		and health < max_health


## The charge is spent on the press and the health arrives `drink_heal_delay`
## later — that split is the whole feel of the thing. Drinking a frame before a
## bullet lands costs you the swig and doesn't save you, which is what makes
## reaching for the flask a read of the fight rather than a reflex.
func _handle_drink() -> void:
	# The heal lands first, so a swig started on the very frame the last one
	# finishes still pays out. `_drink_timer` was already decremented this frame
	# by _tick_timers(), so this compares against the elapsed time.
	if _drink_heal_pending and _drink_timer <= drink_duration - drink_heal_delay:
		_drink_heal_pending = false
		_set_health(health + flask_heal_amount)
		_spawn_drink_puff(0.9)

	if not Input.is_action_just_pressed("heal") or not can_drink():
		return

	_set_flask_charges(flask_charges - 1)
	_drink_timer = drink_duration
	_drink_heal_pending = true
	# Feedback on the press, before anything has been healed, so the swig reads
	# as having started. The warm tint over the same window is applied by
	# _update_damage_feedback(), the sole writer of `modulate`.
	#
	# The sheet has no drinking pose (see ANIMATION.md), so the clip is left
	# alone: the player keeps whatever they were doing rather than snapping to a
	# substitute that would read worse than none. Faking one is a job for the art.
	_spawn_drink_puff(0.55)


## The amber puff off the bottle. Reuses `dust_scene` rather than adding an
## effect scene, tinted through `self_modulate` — `modulate` is the channel
## dust_puff.gd fades on, so writing rgb there would clobber its own alpha tween.
func _spawn_drink_puff(size: float) -> void:
	var puff := _spawn_dust(
		global_position + Vector2(facing * 14.0, -120.0),
		Vector2(facing * 40.0, -90.0), size, 0.45, 0.7)
	if puff != null:
		puff.self_modulate = Color(1.0, 0.78, 0.34)


## The one place `flask_charges` is written — same contract `_set_health()` holds
## for the pip row. Clamped rather than trusted, so no caller can drive it
## negative or past the maximum however it does its arithmetic.
func _set_flask_charges(value: int) -> void:
	var next := clampi(value, 0, maxi(flask_charges_max, 0))
	if next == flask_charges:
		return
	flask_charges = next
	flask_changed.emit(flask_charges, flask_charges_max)


## Restores charges from the world — a `Tequila Stash`. Returns whether any were
## actually taken, so the pickup can leave itself in the level when the flask is
## already full instead of vanishing for nothing.
func add_flask_charges(amount: int = 1) -> bool:
	if amount <= 0 or flask_charges >= flask_charges_max:
		return false
	_set_flask_charges(flask_charges + amount)
	return true


## What resting at a saloon does to the player: health and flask both back to
## full. A dead player is refused — death routes through GameState, and quietly
## reviving one here would undo it.
func rest_refill() -> void:
	if _dead:
		return
	_drink_timer = 0.0
	_drink_heal_pending = false
	_set_health(max_health)
	_set_flask_charges(flask_charges_max)


# --- Animation ---------------------------------------------------------------

## The pose the player would be in if they fired right now.
##
## One function, because three separate things need the answer and they must not
## disagree: the clip that gets played, the muzzle the bullet leaves from, and
## the gate on the code-drawn flash. Sheet 2 had a single firing pose and the
## muzzle could be keyed on the stance; sheet 3 draws standing, running and
## airborne versions with barrels 37px apart, so a stance-keyed muzzle would
## spawn running shots a body-width behind the gun.
func _firing_pose() -> StringName:
	match state:
		State.SLIDE:
			# No firing pose at all — the slide poses draw no gun. The clip is
			# the slide either way; this exists so the muzzle has somewhere to be.
			return &"slide"
		State.CROUCH:
			# Sheet 3 dropped the crouched firing pose, so these are the plain
			# crouch clips and UNPAINTED_FLASH_CLIPS draws the flash instead.
			return &"crouch_walk" if not is_zero_approx(_move_input) else &"crouch"
		_:
			if not is_on_floor():
				return &"jump_shoot"
			if not is_zero_approx(_move_input):
				return &"run_shoot"
			return &"shoot"


## Puts the muzzle where the pose about to be drawn holds the gun.
##
## Called before _handle_shoot() rather than after _update_animation(), because
## the bullet has to spawn on the frame the trigger is pulled and the animation
## is not chosen until after move_and_slide(). The one frame that can disagree
## is a shot fired on the very frame of a landing, where the muzzle is still the
## airborne one — 30px, for one frame, on a pose that was airborne when the
## trigger went down.
func _place_muzzle() -> void:
	_muzzle.position = MUZZLE.get(_firing_pose(), MUZZLE_STAND)


## Picks a clip from the state the movement code has already settled on, so this
## is a readout and never a decision — nothing here may write to `state`,
## `velocity` or `facing`.
##
## Returns the clip it settled on, so the shot effects can be gated on the same
## decision instead of working the state out a second time and drifting from it.
func _update_animation() -> StringName:
	var shooting := _shoot_pose_timer > 0.0
	var clip := &"idle"

	match state:
		State.SLIDE, State.CROUCH:
			# Neither stance has a firing pose of its own, so _firing_pose()
			# returns the ordinary clip and the branch collapses to one call.
			clip = _firing_pose()
		State.NORMAL:
			if shooting:
				# Ahead of everything else: sheet 3 draws the running and
				# airborne firing poses that sheet 2 was missing, so a shot no
				# longer has to be left unacted-out to keep the legs turning.
				clip = _firing_pose()
			elif not is_on_floor():
				clip = &"jump" if velocity.y < 0.0 else &"fall"
			elif not is_zero_approx(_move_input):
				# Deliberately ahead of `land`: touching down while still holding
				# a direction is how most jumps in a run-and-gun end, and picking
				# the run cycle back up beats a 0.14s stumble. `land` is
				# therefore only reached on a standing vertical drop.
				clip = &"run"
			elif _land_timer > 0.0:
				clip = &"land"

	# Only the standing firing pose restarts on a shot — see SHOT_SYNCED_CLIPS
	# for why the two moving ones are left to free-run.
	_play(clip, _shot_this_frame and clip in SHOT_SYNCED_CLIPS)
	_match_run_cadence(clip)
	return clip


## Time-scales the run cycle to the speed the body is actually travelling, so
## the feet stay planted instead of skating.
##
## The clip is a full cycle of two steps covering `2 * run_stride` on screen, so
## it has to last that divided by the current speed. At the authored 0.60s and
## run_speed 600 the cycle covered 360px against a drawn step of ~142px — the
## character slid roughly 27% of the way, which is what made the run read badly.
##
## Driving it off the live velocity rather than off run_speed also covers the
## accel and decel ramps, where a fixed rate has the legs turning over at full
## sprint cadence while the body is barely moving.
func _match_run_cadence(clip: StringName) -> void:
	var authored: float = _cycle_time.get(clip, 0.0)
	if authored <= 0.0 or run_stride <= 0.0:
		_sprite.speed_scale = 1.0
		return

	var wanted := 2.0 * run_stride / maxf(absf(velocity.x), 1.0)
	_sprite.speed_scale = clampf(
		authored / wanted,
		run_cycle_scale_range.x,
		run_cycle_scale_range.y
	)


## Restarts only on a genuine change of clip. Calling play() every frame would
## pin every animation to frame 0, and re-triggering a finished non-looping clip
## — `crouch`, `land`, `slide` — would loop it by hand instead of letting it
## settle on its last frame, which is what holds the crouched pose.
##
## `restart` is the one exception: a shot fired while the firing clip is already
## running has to snap it back to frame 0, or the flash the artist drew stops
## coinciding with the bullet.
func _play(clip: StringName, restart: bool = false) -> void:
	if _sprite.animation != clip:
		_sprite.play(clip)
		# play() on an already-playing sprite does NOT rewind, so the frame
		# index carries across a clip change — and `run` and `run_shoot` put
		# their contacts on different frames. Without this, opening fire on the
		# run can land straight on the new clip's contact frame and crack off a
		# footstep with the boot visibly mid-air.
		_prev_run_frame = -1
	elif restart:
		_sprite.play(clip)
		_sprite.frame = 0


# --- Juice -------------------------------------------------------------------

## The one writer of the sprite's scale and rotation, so squash, stretch and
## recoil lean can't clobber each other — the same contract `_update_damage_
## feedback()` holds for `modulate` and the camera holds for `offset`.
##
## Deliberately on the SPRITE, not on Visuals. `_muzzle` is a sibling under
## Visuals, so scaling there would drag the muzzle with it and bullets would
## start leaving from somewhere other than MUZZLE_STAND / MUZZLE_CROUCH — the
## constants measured off the painted flashes. Scaling the sprite alone leaves
## the muzzle exactly where the sheet says it is.
##
## The sprite's origin sits at the player's feet, which is the pivot squash and
## stretch want anyway: the boots stay planted and the head does the moving.
func _update_sprite_transform(delta: float, clip: StringName) -> void:
	_update_run_bob(clip)

	var target := 0.0
	if not is_on_floor():
		target = clampf(absf(velocity.y) / maxf(air_stretch_speed, 1.0), 0.0, 1.0) \
			* air_stretch
	_stretch = move_toward(_stretch, target, squash_recover_speed * delta)

	# What it gains in height it loses in width, so the figure keeps its bulk.
	_sprite.scale = Vector2(
		SPRITE_SCALE * (1.0 - _stretch * 0.55),
		SPRITE_SCALE * (1.0 + _stretch)
	)

	# Negative leans the top back for a right-facing player. Visuals is mirrored
	# by the facing flip, which turns this the correct way round when facing
	# left — so one signed value covers both directions.
	var lean := 0.0
	if _recoil_timer > 0.0:
		lean = -recoil_lean * (_recoil_timer / maxf(recoil_lean_time, 0.001))
	_sprite.rotation = lean


## The vertical bounce the run art doesn't have.
##
## Every run frame was drawn with its feet on the same line — `feet_y` is
## identical across all nine — so the body never rises, and a run with no
## vertical travel reads as a paper doll being slid along. This puts it back.
##
## It only ever lifts, never sinks: the offset runs from 0 at the contact frames
## to -amplitude at the passing frames. Pushing *down* from a drawn baseline
## would drive the planted boot through the floor, whereas lifting during the
## passing phase is right precisely because that is when the feet are off the
## ground in a real stride.
##
## Written to VISUALS, not the sprite, unlike squash and stretch. The gun is in
## the character's hand, so the muzzle should rise and fall with the body — and
## because this moves the whole node, `_muzzle.position` stays exactly
## MUZZLE_STAND and the code-drawn flash stays attached to the hand.
func _update_run_bob(clip: StringName) -> void:
	if not clip in RUN_CYCLE_CLIPS or run_bob <= 0.0:
		_visuals.position.y = 0.0
		return

	var frames := _sprite.sprite_frames
	var count := frames.get_frame_count(clip) if frames != null else 0
	if count <= 0:
		_visuals.position.y = 0.0
		return

	# Two bounces per cycle — the clip is two steps. RUN_CONTACT_PHASE puts the
	# low points on the contact frames, which measure widest at the boot band.
	var f := float(_sprite.frame) + _sprite.get_frame_progress()
	var phase := TAU * 2.0 * (f - float(RUN_CONTACT_PHASE[clip])) / float(count)
	_visuals.position.y = -run_bob * 0.5 * (1.0 - cos(phase))


## Landing: hold the pose, compress, and throw dust in proportion to the drop.
func _on_land(impact_speed: float) -> void:
	_land_timer = LAND_POSE_TIME

	var ratio := clampf(impact_speed / max_fall_speed, 0.0, 1.0)
	_stretch = -land_squash * ratio

	if impact_speed < land_dust_min_speed:
		return
	for i in 2 + int(ratio * 3.0):
		_spawn_dust(global_position + Vector2(randf_range(-42.0, 42.0), 0.0),
			Vector2(randf_range(-200.0, 200.0), randf_range(-130.0, -30.0)),
			lerpf(0.45, 0.95, ratio))


## Continuous ground dust — running and sliding. Event-driven puffs (takeoff,
## landing, skid) are spawned where their event is detected instead.
func _update_dust(delta: float) -> void:
	var interval := 0.0
	if state == State.SLIDE:
		interval = slide_dust_interval
	elif is_on_floor() and not is_zero_approx(_move_input) \
			and absf(velocity.x) > run_dust_min_speed:
		interval = run_dust_interval

	if interval <= 0.0:
		# Reset rather than let it run down, so the first stride after a stop
		# puffs immediately instead of on whatever was left of the last timer.
		_dust_timer = 0.0
		return

	_dust_timer -= delta
	if _dust_timer > 0.0:
		return
	_dust_timer = interval

	var away := -signf(velocity.x) if not is_zero_approx(velocity.x) else float(-facing)
	if state == State.SLIDE:
		_spawn_dust(global_position + Vector2(away * 28.0, -6.0),
			Vector2(away * randf_range(150.0, 320.0), randf_range(-100.0, -20.0)), 0.75)
	else:
		_spawn_dust(global_position + Vector2(away * 16.0, 0.0),
			Vector2(away * randf_range(70.0, 160.0), randf_range(-70.0, -15.0)), 0.42)


## Footsteps, fired off the run clip's contact frames rather than off a timer.
##
## The obvious implementation is to hang them on _update_dust()'s
## `run_dust_interval`, and it is wrong: that interval is a fixed 0.17s, while
## _match_run_cadence() time-scales the clip to the speed the body is actually
## travelling. On the accel and decel ramps the two disagree, and a step heard
## while the boot is visibly mid-air is exactly the artefact the cadence matching
## was written to remove. Driving off the frame index inherits that time-scaling
## for free and needs no interval of its own.
##
## Crossings are detected by frame index alone. That is safe because a frame is
## never shorter than one physics tick here: the clip is authored at 15fps and
## `run_cycle_scale_range` caps the speed-up at 2.2, so the briefest frame is
## ~30ms against a 60Hz tick. Raise that cap far enough and this would start
## missing steps.
func _update_footsteps(clip: StringName) -> void:
	# The speed floor is not redundant with the clip check. `run` is chosen off
	# the steering input, not off the velocity, so a player leaning into a wall —
	# the tunnel mouth, most obviously — keeps the run cycle turning over on the
	# spot. Reusing _update_dust()'s threshold rather than adding one of its own
	# keeps the boots and the puffs agreeing about what counts as a stride.
	if not clip in RUN_CYCLE_CLIPS or not is_on_floor() \
			or footstep_sounds.is_empty() \
			or absf(velocity.x) <= run_dust_min_speed:
		_prev_run_frame = -1
		return

	var frames := _sprite.sprite_frames
	var count := frames.get_frame_count(clip) if frames != null else 0
	if count <= 0:
		_prev_run_frame = -1
		return

	var frame := _sprite.frame
	if frame == _prev_run_frame:
		return
	_prev_run_frame = frame

	# Rounded, not floored: a contact phase measured between two frames reads as
	# landing on the nearer of them.
	var phase: float = RUN_CONTACT_PHASE[clip]
	var contact_a := int(round(phase)) % count
	var contact_b := int(round(phase + count * 0.5)) % count
	if frame != contact_a and frame != contact_b:
		return

	var sound := footstep_sounds[_footstep_index % footstep_sounds.size()]
	_footstep_index += 1
	Sfx.play_at(sound, global_position, footstep_volume_db, randf_range(0.92, 1.08))


## Fills the flash the sheet doesn't paint. Takes the clip rather than deciding
## for itself — see UNPAINTED_FLASH_CLIPS for which poses need it and why slide
## is excluded.
func _update_shot_fx(clip: StringName) -> void:
	if not _shot_this_frame or muzzle_flash_scene == null:
		return
	if not clip in UNPAINTED_FLASH_CLIPS:
		return

	var flash := muzzle_flash_scene.instantiate()
	# Onto Visuals, not the level: it lasts a couple of frames, so it should
	# travel with a running player, and being under Visuals mirrors it with the
	# facing flip for free.
	_visuals.add_child(flash)
	flash.position = _muzzle.position


## `at` is a global position. Every tunable is read in the puff's _ready, so
## they are all set before add_child(); the position has to be written after it,
## or reparenting reinterprets it.
##
## Returns the puff so a caller that wants to tint it can — see
## _spawn_drink_puff(). Every other call site ignores it.
func _spawn_dust(at: Vector2, vel: Vector2, size: float, life: float = 0.36,
		alpha: float = 0.8) -> Node2D:
	if dust_scene == null:
		return null

	var puff := dust_scene.instantiate()
	puff.velocity = vel
	puff.spin = randf_range(-2.2, 2.2)
	puff.start_scale = size * 0.35
	puff.end_scale = size
	puff.duration = life
	puff.start_alpha = alpha
	# A sibling of the player, like bullets: dust belongs to the ground it came
	# off, not to the body that kicked it, so it must not travel at run_speed.
	get_parent().add_child(puff)
	puff.global_position = at
	return puff


# --- Damage ------------------------------------------------------------------

## Flash and i-frame blink share `modulate`, so they're written in one place and
## sequenced — flash first, then blink for the rest of the window. Two separate
## writers would clobber each other's alpha.
func _update_damage_feedback() -> void:
	if _hit_timer > 0.0:
		_visuals.modulate = Color(3.0, 3.0, 3.0)
	elif _invuln_timer > 0.0:
		var dim := int(_invuln_timer * 12.0) % 2 == 0
		_visuals.modulate = Color(1.0, 1.0, 1.0, 0.35 if dim else 1.0)
	elif is_drinking():
		# Ranked below the i-frame blink deliberately. You can be drinking and
		# invulnerable at once, and how long the i-frames have left is the more
		# urgent of the two things to be able to read.
		_visuals.modulate = Color(1.35, 1.05, 0.62)
	else:
		_visuals.modulate = Color.WHITE


## The one place `health` is written. Every route in goes through it — the
## opening value, damage, and the zeroing on death — so a readout that listens
## for the signal can't ever be looking at a stale number. Clamped rather than
## left to run negative, because the HUD would otherwise have to clamp it again
## at the other end.
func _set_health(value: int) -> void:
	var next := clampi(value, 0, max_health)
	if next == health:
		return
	health = next
	health_changed.emit(health, max_health)


func take_damage(amount: int, from_direction: int = 0) -> void:
	if _dead or _invuln_timer > 0.0:
		return

	_set_health(health - amount)
	_invuln_timer = invulnerable_time
	_hit_timer = hit_flash_time
	velocity.x = from_direction * hit_knockback
	_camera.add_trauma(hit_trauma)

	if health <= 0:
		die()


## Death is terminal: GameState freezes the tree and puts up the game over
## screen, and Retry reloads the level from the top. There is no respawning in
## place any more — that hid the fact that you'd died at all.
##
## The `_dead` latch matters because both routes in can fire repeatedly: enemy
## bullets already in flight keep calling take_damage, and the fall check runs
## every physics frame while the body is still below the kill plane.
func die() -> void:
	if _dead:
		return
	_dead = true
	# A swig in flight must not pay out into a corpse: `_handle_drink()` runs
	# every physics frame and would otherwise put a pip back on the bar behind
	# the death screen, which reads as a bug.
	_drink_timer = 0.0
	_drink_heal_pending = false
	# Zeroed for the benefit of the HUD: falling out of the level kills you
	# without ever touching health, and a full bar behind the death screen reads
	# as a bug. Redundant on the damage route, where it's already 0.
	_set_health(0)
	velocity = Vector2.ZERO
	GameState.game_over()
