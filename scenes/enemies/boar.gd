class_name Boar
extends CharacterBody2D

## Melee charger: paws the ground, then commits to a straight run.
##
## The counterpart to `Gunslinger`, which punishes standing in its lane at
## range. This one punishes standing still at all — the charge is only escaped
## by leaving the ground line, so it is the first enemy that asks anything of
## the player's jump and slide in a fight rather than in platforming.
##
## Charging is *committed on purpose*: once `State.CHARGE` starts, the boar
## never re-aims at the player. A charger that tracked you would be unreadable
## and impossible to dodge — the whole move is legible because the wind-up tells
## you the lane and the lane never changes. Everything else here exists to make
## that one beat land: the paw is the tell, the recover is the punish window.
##
## Patrol reuses the gunslinger's two-raycast approach — wall ahead, floor ahead
## — rather than hand-placed bounds, so it works on whatever geometry a level
## has.

## Emitted when the wind-up starts, so a grunt or a dust puff can attach without
## this file learning about them. The charge itself is the loud part.
signal charge_started

enum State {
	## Ambling along its patrol, unaware.
	PATROL,
	## Spotted the player, feet planted, telegraphing. Still turnable.
	WINDUP,
	## Committed. Direction is frozen for the whole run.
	CHARGE,
	## Slammed into something. Stopped, vulnerable, briefly harmless.
	RECOVER,
}

@export_group("Movement")
@export var patrol_speed: float = 110.0
@export var charge_speed: float = 780.0
## How hard it gets up to charge speed. Deliberately not instant — the first
## few frames of the run are part of the tell.
@export var charge_accel_time: float = 0.18
@export var gravity: float = 2000.0
@export var max_fall_speed: float = 1400.0

@export_group("Combat")
@export var max_health: int = 4
@export var contact_damage: int = 1
@export var sight_range: float = 620.0
## Vertical tolerance. Short on purpose: a grounded charger that notices you
## from a rooftop would wind up at nothing and read as broken.
@export var sight_height: float = 200.0
## The tell. Long enough to react to, short enough to still feel like a threat.
@export var windup_time: float = 0.55
## Hard cap on a charge that never hits anything, so a boar can't run the length
## of an open level forever.
@export var charge_max_time: float = 2.4
## Grace period before a charge may be ended by a wall or a ledge. See
## `_do_charge()` — it stops a boar from cancelling into scenery it started
## against.
@export var charge_min_time: float = 0.12
## The punish window after it slams into a wall.
@export var recover_time: float = 1.1
## Beat after a recover before it may commit again, so a cornered player isn't
## re-gored the instant they land a hit.
@export var recharge_delay: float = 0.45

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
var _dying: bool = false

@onready var _visuals: Node2D = $Visuals
@onready var _sprite: AnimatedSprite2D = $Visuals/Sprite
@onready var _wall_check: RayCast2D = $WallCheck
@onready var _ledge_check: RayCast2D = $LedgeCheck
@onready var _sight_ray: RayCast2D = $SightRay
@onready var _hitbox: Area2D = $Hitbox
@onready var _health_bar_fill: ColorRect = $HealthBar/Fill


func _ready() -> void:
	health = max_health
	add_to_group("enemies")
	_apply_facing()
	_update_health_bar()
	_sprite.play(&"walk")


func _physics_process(delta: float) -> void:
	# Resolved lazily rather than in _ready, for the same reason the gunslinger
	# does it: node _ready order follows the scene tree, so a boar placed above
	# the Player would look for the group before the Player has joined it.
	if _player == null:
		_player = get_tree().get_first_node_in_group("player")

	_tick_timers(delta)
	_update_feedback()

	if not is_on_floor():
		velocity.y = minf(velocity.y + gravity * delta, max_fall_speed)

	if not _dying:
		match _state:
			State.PATROL:
				_do_patrol(delta)
			State.WINDUP:
				_do_windup(delta)
			State.CHARGE:
				_do_charge(delta)
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
	# Single write point for modulate, matching the gunslinger, so the hit flash
	# can't fight anything else that wants to tint the body.
	_visuals.modulate = Color(3.0, 3.0, 3.0) if _hit_timer > 0.0 else Color.WHITE


func _do_patrol(delta: float) -> void:
	# is_on_floor() gates the turn because a RayCast2D reports no collision on
	# its first physics frame — without it every enemy spins around on spawn.
	var blocked := _wall_check.is_colliding()
	var ledge_ahead := not _ledge_check.is_colliding()
	if is_on_floor() and _turn_cooldown <= 0.0 and (blocked or ledge_ahead):
		_set_facing(-facing)

	velocity.x = move_toward(velocity.x, facing * patrol_speed, patrol_speed * 8.0 * delta)

	if _cooldown <= 0.0 and _can_see_player():
		_enter_windup()


func _do_windup(delta: float) -> void:
	# Planted. The last chance to turn is here, so a player who runs past during
	# the tell gets charged at rather than ignored — but once CHARGE starts the
	# direction is frozen.
	velocity.x = move_toward(velocity.x, 0.0, patrol_speed * 12.0 * delta)
	_face_player()

	if _state_timer <= 0.0:
		_enter_charge()


func _do_charge(delta: float) -> void:
	velocity.x = move_toward(
		velocity.x, facing * charge_speed, charge_speed / maxf(charge_accel_time, 0.01) * delta
	)

	# A ledge ends the charge rather than launching it into the void. A boar
	# that suicides off the first drop turns its own big telegraphed attack into
	# a free kill, which is the opposite of the point.
	var ledge_ahead := is_on_floor() and not _ledge_check.is_colliding()
	# The stop conditions are ignored for the first moments of the run. A boar
	# that turned at a wall and then wound up still standing against it would
	# otherwise register that same wall on frame one and recover having never
	# moved, eating the whole attack.
	var launched := charge_max_time - _state_timer > charge_min_time
	if launched and (is_on_wall() or ledge_ahead or _state_timer <= 0.0):
		_enter_recover()


func _do_recover(delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, charge_speed * 3.0 * delta)
	if _state_timer <= 0.0:
		_set_state(State.PATROL, 0.0)
		_cooldown = recharge_delay
		_sprite.play(&"walk")


func _enter_windup() -> void:
	_set_state(State.WINDUP, windup_time)
	_face_player()
	velocity.x = 0.0
	_sprite.play(&"idle")


func _enter_charge() -> void:
	_set_state(State.CHARGE, charge_max_time)
	_sprite.play(&"run")
	charge_started.emit()


func _enter_recover() -> void:
	_set_state(State.RECOVER, recover_time)
	velocity.x = 0.0
	_sprite.play(&"idle")


func _set_state(next: State, duration: float) -> void:
	_state = next
	_state_timer = duration


## Contact damage is polled rather than driven by `body_entered` because the
## player's own `invulnerable_time` is what rate-limits it: an entered signal
## fires once and would miss a player who stays inside the boar across the
## whole invulnerability window, leaving them safe while visibly standing in it.
func _damage_player_on_contact() -> void:
	if _state == State.RECOVER:
		return
	for body in _hitbox.get_overlapping_bodies():
		if body.has_method("take_damage") and body.is_in_group("player"):
			# Away from the boar, not along its facing — a player clipped by the
			# tail end of a charge should still be thrown clear rather than
			# dragged further through it.
			var away := 1 if body.global_position.x > global_position.x else -1
			body.take_damage(contact_damage, away)


func _can_see_player() -> bool:
	if _player == null or health <= 0:
		return false

	var to_player := _player.global_position - global_position
	if absf(to_player.x) > sight_range or absf(to_player.y) > sight_height:
		return false
	# Only charges at what's in front of it. Being snuck up on from behind is
	# the reward for approaching carefully.
	if signf(to_player.x) != float(facing):
		return false

	# Masked to world only, so terrain blocks sight but the player never does.
	_sight_ray.target_position = to_local(_player.global_position + Vector2(0.0, -40.0))
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
	# Unlike the player, this art pack's frames face left unflipped — so
	# matching `facing` (positive = right) takes the negation, not the
	# identity.
	_visuals.scale.x = -facing
	# Raycasts live outside Visuals and are aimed explicitly — scaling a
	# RayCast2D by -1 is a good way to get confusing results.
	_wall_check.target_position = Vector2(70.0 * facing, 0.0)
	_ledge_check.position = Vector2(66.0 * facing, -12.0)


func take_damage(amount: int, from_direction: int = 0) -> void:
	if health <= 0 or _dying:
		return
	health -= amount
	_update_health_bar()
	_hit_timer = hit_flash_time
	# Barely moved mid-charge. A boar that could be stopped by chip damage would
	# make the wind-up meaningless.
	var resist := 0.15 if _state == State.CHARGE else 1.0
	velocity.x += from_direction * 90.0 * resist

	# Getting shot while ambling makes it notice you, so shooting a boar in the
	# back is an opening move rather than a free kill.
	if health > 0 and _state == State.PATROL and _cooldown <= 0.0:
		_face_player()
		_enter_windup()

	if health <= 0:
		_die()


func _update_health_bar() -> void:
	# The fill has a two-pixel inset within the 50px background.
	var fraction := clampf(float(health) / maxf(float(max_health), 1.0), 0.0, 1.0)
	_health_bar_fill.size.x = 46.0 * fraction


## Death plays out on the Hit-Vanish sheet instead of freeing immediately, so a
## charge that ends in a kill still resolves visually. `_dying` stops every
## behaviour branch and the contact damage while it does — a corpse mid-vanish
## must not still be able to gore the player.
func _die() -> void:
	_dying = true
	velocity.x = 0.0
	_hitbox.set_deferred(&"monitoring", false)
	_sprite.play(&"hit")

	if death_puff_scene != null:
		var puff := death_puff_scene.instantiate()
		# Set before add_child — _ready starts the tween that reads it.
		puff.end_scale = 5.0
		puff.duration = 0.3
		get_parent().add_child(puff)
		puff.global_position = global_position + Vector2(0.0, -40.0)

	await _sprite.animation_finished
	queue_free()
