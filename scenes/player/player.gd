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
## no longer moves the art on its own — see MUZZLE_STAND / MUZZLE_CROUCH.
enum State { NORMAL, CROUCH, SLIDE }

## Emitted on every change to `health`, including the reset on respawn. `total`
## is max_health, so a readout can size itself from the signal alone and never
## has to reach back into the player.
signal health_changed(current: int, total: int)

## Emitted on every change to `weapon`, including the opening one in _ready.
## Same contract as health_changed, for the same reason: a readout that only
## heard about switches would start blank.
signal weapon_changed(weapon: Weapon)

## Where the revolver's muzzle sits in each stance, in Visuals-local pixels for
## a right-facing player. Measured off the muzzle flashes painted into the sprite
## sheet — shoot[3..6] and crouch[7] — rather than derived from the collision
## height, because the crouched firing pose reaches much further forward than a
## fraction of the stance height would predict. See tools/slice_player_sheet.py.
const MUZZLE_STAND := Vector2(62, -130)
const MUZZLE_CROUCH := Vector2(80, -88)

## How long the firing pose stays up after a shot. Independent of the weapon's
## `muzzle_flash_time`, which is far shorter than a readable pose: the revolver
## flashes for 0.05s. Held fire keeps re-arming this, so the pose persists for as
## long as the trigger is down.
const SHOOT_POSE_TIME := 0.25

## How long the landing clip holds before idle takes over.
const LAND_POSE_TIME := 0.14

## The sprite's authored scale — the 187px figure on the sheet fitted to the
## 170px collision box (see ANIMATION.md). Squash and stretch multiply it, so it
## has to be a constant here: reading the node's current scale back would
## compound the squash every frame.
const SPRITE_SCALE := 0.9

## The two clips with a muzzle flash painted into the art — shoot[3..6] and
## crouch[7]. They restart on every shot so the painted flash keeps step with
## the bullet leaving the muzzle.
const PAINTED_FLASH_CLIPS: Array[StringName] = [&"shoot", &"crouch_shoot"]

## Clips that can be on screen when a shot goes off but have no flash painted
## in. ANIMATION.md lists this as a known gap in the sheet: firing on the run or
## in the air spawns a bullet, it just isn't acted out and nothing flashes. A
## code-drawn flash fills exactly that hole — and only that hole, because
## drawing one over a painted pose would flash the shot twice.
##
## `slide` is deliberately absent even though you can fire mid-slide. The slide
## poses have no gun drawn at all, so a flash there reads as coming from an
## empty hand; that one stays a job for the art rather than for this.
const UNPAINTED_FLASH_CLIPS: Array[StringName] = [&"run", &"jump", &"fall"]

@export_group("Run")
## ~3 seconds to cross the screen.
@export var run_speed: float = 600.0
## How far the character's feet carry it in ONE step, in screen pixels — the
## horizontal gap between the boots at full extension, times the sprite scale.
##
## This is what stops the run skating. The `run` clip is a full cycle of two
## steps, so at speed `v` the cycle has to last `2 * run_stride / v` seconds; the
## clip is then time-scaled to fit. Authored at 0.60s it covered 360px per cycle
## against a drawn step of ~142px, so the character slid ~27% of the way.
##
## Measured off the sheet, so **re-measure it if the run art changes**: the boot
## band of the widest frame is the number. Raising it makes the legs turn over
## slower; lowering it, faster.
@export var run_stride: float = 142.0
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

## 1 for right, -1 for left. Read by the muzzle and by anything that needs to
## know which way the player is pointed.
var facing: int = 1
## Read freely; write only through _set_health(), or the HUD misses the change.
var health: int
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
## Authored length of one `run` cycle, read off the SpriteFrames rather than
## hardcoded, so retiming the clip in build_sprite_frames.py doesn't silently
## desync the cadence matching from it.
var _run_cycle_time: float = 0.0
## Raised by _handle_shoot() and cleared by _update_animation(). Without it the
## firing clip free-runs: `shoot` loops in 0.25s and the revolver fires every
## 0.18s, so held fire would drift the painted flashes out of step with the
## bullets actually leaving the muzzle.
var _shot_this_frame: bool = false

@onready var _visuals: Node2D = $Visuals
@onready var _sprite: AnimatedSprite2D = $Visuals/Sprite
@onready var _muzzle: Marker2D = $Visuals/Muzzle
@onready var _stand_shape: CollisionShape2D = $StandShape
@onready var _crouch_shape: CollisionShape2D = $CrouchShape
@onready var _ceiling_check: ShapeCast2D = $CeilingCheck
@onready var _camera := $Camera2D as PlayerCamera2D


func _ready() -> void:
	_recalculate_jump()
	_set_health(max_health)
	_set_weapon(0)
	_spawn_point = global_position
	_fall_death_y = _compute_fall_death_y()
	_measure_run_cycle()
	add_to_group("player")


## The authored duration of the run cycle, straight off the resource.
func _measure_run_cycle() -> void:
	var frames := _sprite.sprite_frames
	if frames == null or not frames.has_animation(&"run"):
		return
	var fps := frames.get_animation_speed(&"run")
	if fps > 0.0:
		_run_cycle_time = frames.get_frame_count(&"run") / fps


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
	_update_stance()
	_apply_gravity(delta)
	_handle_jump()
	_handle_move(delta)
	# Before the shot, so a switch and a fire on the same frame use the weapon
	# you just switched to rather than the one you left.
	_handle_weapon_switch()
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
				if Input.is_action_just_pressed("crouch") and fast_enough \
						and _slide_cooldown_timer <= 0.0:
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
func _set_state(new_state: State) -> void:
	if state == new_state:
		return
	state = new_state

	var low := state != State.NORMAL
	_stand_shape.disabled = low
	_crouch_shape.disabled = not low
	_muzzle.position = MUZZLE_CROUCH if low else MUZZLE_STAND


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


# --- Animation ---------------------------------------------------------------

## Picks a clip from the state the movement code has already settled on, so this
## is a readout and never a decision — nothing here may write to `state`,
## `velocity` or `facing`.
##
## The sheet has no firing pose for a moving or airborne character, so shooting
## on the run keeps the run cycle: the shot still fires, it just isn't acted
## out. Substituting the standing shoot clip would stop the legs dead mid-stride
## at a `run_speed` of 600, which reads far worse than no firing pose at all.
## Faking one is a job for the art, not for this function.
## Returns the clip it settled on, so the shot effects can be gated on the same
## decision instead of working the state out a second time and drifting from it.
func _update_animation() -> StringName:
	var shooting := _shoot_pose_timer > 0.0
	var clip := &"idle"

	match state:
		State.SLIDE:
			clip = &"slide"
		State.CROUCH:
			# The one stance where firing on the move *is* drawn — crouch[7] has
			# the revolver out — so it doesn't need the exception above.
			clip = &"crouch_shoot" if shooting else &"crouch"
		State.NORMAL:
			if not is_on_floor():
				clip = &"jump" if velocity.y < 0.0 else &"fall"
			elif not is_zero_approx(_move_input):
				# Deliberately ahead of `land`: touching down while still holding
				# a direction is how most jumps in a run-and-gun end, and picking
				# the run cycle back up beats a 0.14s stumble. `land` is
				# therefore only reached on a standing vertical drop.
				clip = &"run"
			elif shooting:
				clip = &"shoot"
			elif _land_timer > 0.0:
				clip = &"land"

	# Only the painted-flash clips restart on a shot. Restarting `run` every
	# trigger pull would stutter the legs at a run_speed of 600.
	_play(clip, _shot_this_frame and clip in PAINTED_FLASH_CLIPS)
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
	if clip != &"run" or _run_cycle_time <= 0.0 or run_stride <= 0.0:
		_sprite.speed_scale = 1.0
		return

	var wanted := 2.0 * run_stride / maxf(absf(velocity.x), 1.0)
	_sprite.speed_scale = clampf(
		_run_cycle_time / wanted,
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
	if clip != &"run" or run_bob <= 0.0:
		_visuals.position.y = 0.0
		return

	var frames := _sprite.sprite_frames
	var count := frames.get_frame_count(&"run") if frames != null else 0
	if count <= 0:
		_visuals.position.y = 0.0
		return

	# Two bounces per cycle — the clip is two steps. The 2.75 puts the low
	# points on the contact frames, which measure widest at the boot band.
	var f := float(_sprite.frame) + _sprite.get_frame_progress()
	var phase := TAU * 2.0 * (f - 2.75) / float(count)
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
func _spawn_dust(at: Vector2, vel: Vector2, size: float, life: float = 0.36,
		alpha: float = 0.8) -> void:
	if dust_scene == null:
		return

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
	# Zeroed for the benefit of the HUD: falling out of the level kills you
	# without ever touching health, and a full bar behind the death screen reads
	# as a bug. Redundant on the damage route, where it's already 0.
	_set_health(0)
	velocity = Vector2.ZERO
	GameState.game_over()
