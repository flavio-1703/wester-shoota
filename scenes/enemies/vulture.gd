class_name Vulture
extends CharacterBody2D

## The first flying enemy: circles at altitude, then folds into a committed
## dive when it spots the player below.
##
## Boar and Gunslinger are both ground-locked, so neither asks anything of the
## player's sense of what's *above* them. A vulture does — it patrols on its
## own line in the sky, well outside a ground fight, and the threat is the
## dive itself: once `State.DIVE` starts it flies dead straight at where the
## player was, exactly like the boar's charge never re-aims mid-run. It just
## does it on a diagonal instead of a lane.
##
## No gravity anywhere in here — every other enemy falls when not on solid
## ground, but a vulture that dropped out of the sky between dives would read
## as broken, not as flight. Every state drives `velocity` directly instead.

enum State {
	## Cruising at `_home_y`, scanning below itself.
	PATROL,
	## Spotted, stalled in the air, telegraphing. Still turnable.
	WINDUP,
	## Committed. The dive vector is frozen for the whole dive.
	DIVE,
	## Crashed near the ground, flapping in place — vulnerable, briefly
	## harmless — before climbing back to its patrol altitude.
	RECOVER,
}

@export_group("Movement")
@export var patrol_speed: float = 130.0
## How far above and below `_home_y` the circling drifts.
@export var bob_amplitude: float = 24.0
## Cycles per second of the bob.
@export var bob_frequency: float = 0.6
## Max vertical speed correcting back toward `_home_y` — the same knob that
## does the climb back up after a dive, since climbing is just "further from
## home than usual," not a separate behaviour.
@export var altitude_speed: float = 220.0
@export var dive_speed: float = 820.0
## How hard it gets up to dive speed — the first moments of the dive are part
## of the tell, same reasoning as the boar's charge_accel_time.
@export var dive_accel_time: float = 0.2

@export_group("Combat")
## Low on purpose — this is a fast, unpredictable threat, not an attrition
## fight. Two clean hits and it's out of the sky.
@export var max_health: int = 2
@export var contact_damage: int = 1
@export var sight_range: float = 700.0
## Generous compared to a ground enemy's — being able to notice you from well
## above is the point of a flier.
@export var sight_height: float = 520.0
@export var windup_time: float = 0.4
## Hard cap on a dive that never lands, so it can't fly off the level chasing
## a stale vector forever.
@export var dive_max_time: float = 1.3
## Grace period before a dive may be ended by the ground or a wall — mirrors
## the boar's charge_min_time, and for the same reason: a vulture that folded
## into recover on the frame it committed would eat the whole attack.
@export var dive_min_time: float = 0.1
@export var recover_time: float = 0.7
## Beat after a recover before it may dive again.
@export var recharge_delay: float = 0.5

@export_group("Feedback")
@export var hit_flash_time: float = 0.09
@export var death_puff_scene: PackedScene

var facing: int = -1
var health: int

var _player: Node2D
var _state: State = State.PATROL
var _state_timer: float = 0.0
var _cooldown: float = 0.0
var _hit_timer: float = 0.0
var _turn_cooldown: float = 0.0
## The altitude patrol circles around — wherever it was placed, rather than a
## hand-tuned constant, so it works on whatever a level's sky line ends up
## being, the same spirit as the ground enemies reading their turns off
## raycasts instead of hand-placed bounds.
var _home_y: float
var _bob_phase: float = 0.0
## Set once, at the moment a dive commits, and never touched again for the
## rest of the dive — see State.DIVE.
var _dive_vector: Vector2 = Vector2.ZERO

@onready var _visuals: Node2D = $Visuals
@onready var _wall_check: RayCast2D = $WallCheck
@onready var _sight_ray: RayCast2D = $SightRay
@onready var _hitbox: Area2D = $Hitbox
@onready var _health_bar_fill: ColorRect = $HealthBar/Fill


func _ready() -> void:
	health = max_health
	add_to_group("enemies")
	_home_y = global_position.y
	_apply_facing()
	_update_health_bar()


func _physics_process(delta: float) -> void:
	# Resolved lazily rather than in _ready, for the same reason the ground
	# enemies do it: node _ready order follows the scene tree, so a vulture
	# placed above the Player would look for the group before the Player has
	# joined it.
	if _player == null:
		_player = get_tree().get_first_node_in_group("player")

	_tick_timers(delta)
	_update_feedback()

	match _state:
		State.PATROL:
			_do_patrol(delta)
		State.WINDUP:
			_do_windup(delta)
		State.DIVE:
			_do_dive(delta)
		State.RECOVER:
			_do_recover(delta)

	_damage_player_on_contact()

	move_and_slide()


func _tick_timers(delta: float) -> void:
	_state_timer = maxf(_state_timer - delta, 0.0)
	_cooldown = maxf(_cooldown - delta, 0.0)
	_hit_timer = maxf(_hit_timer - delta, 0.0)
	_turn_cooldown = maxf(_turn_cooldown - delta, 0.0)


func _update_feedback() -> void:
	# Single write point for modulate, matching the other enemies, so the hit
	# flash can't fight anything else that wants to tint the body.
	_visuals.modulate = Color(3.0, 3.0, 3.0) if _hit_timer > 0.0 else Color.WHITE


func _do_patrol(delta: float) -> void:
	var blocked := _wall_check.is_colliding()
	if _turn_cooldown <= 0.0 and blocked:
		_set_facing(-facing)

	velocity.x = move_toward(velocity.x, facing * patrol_speed, patrol_speed * 8.0 * delta)

	_bob_phase += delta
	var target_y := _home_y + sin(_bob_phase * TAU * bob_frequency) * bob_amplitude
	var to_target := target_y - global_position.y
	# Deadband rather than a proportional chase — right at the target it should
	# settle, not hunt back and forth across it every frame.
	var vertical_dir := signf(to_target) if absf(to_target) > 4.0 else 0.0
	velocity.y = move_toward(velocity.y, vertical_dir * altitude_speed, altitude_speed * 6.0 * delta)

	if _cooldown <= 0.0 and _can_see_player():
		_enter_windup()


func _do_windup(delta: float) -> void:
	velocity = velocity.move_toward(Vector2.ZERO, patrol_speed * 12.0 * delta)
	_face_player()

	if _state_timer <= 0.0:
		_enter_dive()


func _do_dive(delta: float) -> void:
	velocity = velocity.move_toward(_dive_vector * dive_speed, dive_speed / maxf(dive_accel_time, 0.01) * delta)

	# Stop conditions ignored for the first moments, same reasoning as the
	# boar: a vulture that wound up already brushing a wall would otherwise
	# register that wall on frame one and recover having never dived at all.
	var launched := dive_max_time - _state_timer > dive_min_time
	if launched and (is_on_wall() or is_on_floor() or _state_timer <= 0.0):
		_enter_recover()


func _do_recover(delta: float) -> void:
	velocity = velocity.move_toward(Vector2.ZERO, dive_speed * 3.0 * delta)
	if _state_timer <= 0.0:
		_set_state(State.PATROL, 0.0)
		_cooldown = recharge_delay


func _enter_windup() -> void:
	_set_state(State.WINDUP, windup_time)
	_face_player()
	velocity = Vector2.ZERO


func _enter_dive() -> void:
	_set_state(State.DIVE, dive_max_time)
	_dive_vector = (_player.global_position - global_position).normalized() \
		if _player != null else Vector2(facing, 0.0)


func _enter_recover() -> void:
	_set_state(State.RECOVER, recover_time)
	velocity = Vector2.ZERO


func _set_state(next: State, duration: float) -> void:
	_state = next
	_state_timer = duration


## Contact damage is polled rather than driven by `body_entered`, same
## reasoning as the boar: the player's own invulnerability window is what
## rate-limits it, and a signal that fires once would miss a player who stays
## inside the hitbox across the whole window.
func _damage_player_on_contact() -> void:
	if _state == State.RECOVER:
		return
	for body in _hitbox.get_overlapping_bodies():
		if body.has_method("take_damage") and body.is_in_group("player"):
			var away := 1 if body.global_position.x > global_position.x else -1
			body.take_damage(contact_damage, away)


## No facing gate, unlike the boar's version — a boar only ever charges
## forward, but a vulture is airborne and free to turn onto anything it
## spots, in front of it or not.
func _can_see_player() -> bool:
	if _player == null or health <= 0:
		return false

	var to_player := _player.global_position - global_position
	if absf(to_player.x) > sight_range or absf(to_player.y) > sight_height:
		return false

	_sight_ray.target_position = to_local(_player.global_position)
	_sight_ray.force_raycast_update()
	return not _sight_ray.is_colliding()


func _face_player() -> void:
	if _player == null:
		return
	var toward := 1 if _player.global_position.x > global_position.x else -1
	if toward != facing:
		_set_facing(toward)


func _set_facing(dir: int) -> void:
	facing = dir
	_turn_cooldown = 0.25
	_apply_facing()


func _apply_facing() -> void:
	_visuals.scale.x = facing
	_wall_check.target_position = Vector2(60.0 * facing, 0.0)


func take_damage(amount: int, from_direction: int = 0) -> void:
	if health <= 0:
		return
	health -= amount
	_update_health_bar()
	_hit_timer = hit_flash_time
	velocity.x += from_direction * 60.0

	# Getting shot while patrolling makes it notice you, same as the boar —
	# plinking one from directly underneath is an opening move, not a freebie.
	if health > 0 and _state == State.PATROL and _cooldown <= 0.0:
		_face_player()
		_enter_windup()

	if health <= 0:
		_die()


func _update_health_bar() -> void:
	# The fill has a two-pixel inset within the 50px background.
	var fraction := clampf(float(health) / maxf(float(max_health), 1.0), 0.0, 1.0)
	_health_bar_fill.size.x = 46.0 * fraction


func _die() -> void:
	if death_puff_scene != null:
		var puff := death_puff_scene.instantiate()
		# Set before add_child — _ready starts the tween that reads it.
		puff.end_scale = 5.0
		puff.duration = 0.3
		get_parent().add_child(puff)
		puff.global_position = global_position
	queue_free()
