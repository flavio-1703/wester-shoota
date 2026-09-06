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
## you duck under enemy fire. The heights come from the shapes in the scene, so
## the visuals and the muzzle follow whatever you set there.
enum State { NORMAL, CROUCH, SLIDE }

## Emitted on every change to `health`, including the reset on respawn. `total`
## is max_health, so a readout can size itself from the signal alone and never
## has to reach back into the player.
signal health_changed(current: int, total: int)

## Emitted on every change to `weapon`, including the opening one in _ready.
## Same contract as health_changed, for the same reason: a readout that only
## heard about switches would start blank.
signal weapon_changed(weapon: Weapon)

## Muzzle sits at this fraction of the current stance height.
const MUZZLE_HEIGHT_RATIO := 0.66

@export_group("Run")
## ~3 seconds to cross the screen.
@export var run_speed: float = 600.0
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
var _stand_height: float
var _crouch_height: float
var _invuln_timer: float = 0.0
var _hit_timer: float = 0.0
var _jump_velocity: float
var _jump_gravity: float
var _fall_gravity: float
var _coyote_timer: float = 0.0
var _jump_buffer_timer: float = 0.0
var _fire_cooldown: float = 0.0
var _flash_timer: float = 0.0
var _slide_timer: float = 0.0
var _slide_cooldown_timer: float = 0.0

@onready var _visuals: Node2D = $Visuals
@onready var _placeholder: ColorRect = $Visuals/Placeholder
@onready var _muzzle: Marker2D = $Visuals/Muzzle
@onready var _muzzle_flash: ColorRect = $Visuals/Muzzle/Flash
@onready var _stand_shape: CollisionShape2D = $StandShape
@onready var _crouch_shape: CollisionShape2D = $CrouchShape
@onready var _ceiling_check: ShapeCast2D = $CeilingCheck
@onready var _camera := $Camera2D as PlayerCamera2D


func _ready() -> void:
	_recalculate_jump()
	_stand_height = _stand_shape.shape.size.y
	_crouch_height = _crouch_shape.shape.size.y
	_set_health(max_health)
	_set_weapon(0)
	_spawn_point = global_position
	_fall_death_y = _compute_fall_death_y()
	add_to_group("player")


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

	move_and_slide()

	if is_on_floor():
		_coyote_timer = coyote_time


func _tick_timers(delta: float) -> void:
	_coyote_timer = maxf(_coyote_timer - delta, 0.0)
	_jump_buffer_timer = maxf(_jump_buffer_timer - delta, 0.0)
	_fire_cooldown = maxf(_fire_cooldown - delta, 0.0)
	_flash_timer = maxf(_flash_timer - delta, 0.0)
	_invuln_timer = maxf(_invuln_timer - delta, 0.0)
	_hit_timer = maxf(_hit_timer - delta, 0.0)
	_slide_timer = maxf(_slide_timer - delta, 0.0)
	_slide_cooldown_timer = maxf(_slide_cooldown_timer - delta, 0.0)
	_muzzle_flash.visible = _flash_timer > 0.0
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

	var height := _crouch_height if low else _stand_height
	_placeholder.offset_top = -height
	_muzzle.position.y = -height * MUZZLE_HEIGHT_RATIO


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
		var decay := slide_speed / maxf(slide_friction_time, 0.001)
		velocity.x = move_toward(velocity.x, 0.0, decay * delta)
		return

	var input_dir := Input.get_axis("move_left", "move_right")

	if not is_zero_approx(input_dir):
		facing = 1 if input_dir > 0.0 else -1
		_visuals.scale.x = facing
		_camera.set_look_direction(facing)

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
	_flash_timer = weapon.muzzle_flash_time


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
