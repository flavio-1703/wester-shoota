class_name Gunslinger
extends CharacterBody2D

## Patrolling enemy that stops and shoots when it has line of sight.
##
## Patrol turns are driven by two raycasts — one for a wall ahead, one for floor
## ahead — rather than hand-placed patrol bounds, so this works unchanged on
## whatever geometry a real level ends up having.

@export_group("Movement")
@export var patrol_speed: float = 180.0
@export var gravity: float = 2000.0
@export var max_fall_speed: float = 1400.0

@export_group("Combat")
@export var max_health: int = 3
@export var bullet_scene: PackedScene
@export var sight_range: float = 900.0
## Vertical tolerance — it won't notice you far above or below its own level.
@export var sight_height: float = 240.0
## Beat between spotting you and the first shot, so being seen feels fair.
@export var reaction_time: float = 0.35
@export var fire_interval: float = 0.9
@export var muzzle_flash_time: float = 0.06

@export_group("Feedback")
@export var hit_flash_time: float = 0.09
@export var death_puff_scene: PackedScene

var facing: int = -1
var health: int

var _player: Node2D
var _aim_timer: float = 0.0
var _fire_cooldown: float = 0.0
var _flash_timer: float = 0.0
var _hit_timer: float = 0.0
var _turn_cooldown: float = 0.0
var _saw_player: bool = false

@onready var _visuals: Node2D = $Visuals
@onready var _muzzle: Marker2D = $Visuals/Muzzle
@onready var _muzzle_flash: ColorRect = $Visuals/Muzzle/Flash
@onready var _wall_check: RayCast2D = $WallCheck
@onready var _ledge_check: RayCast2D = $LedgeCheck
@onready var _sight_ray: RayCast2D = $SightRay
@onready var _health_bar_fill: ColorRect = $HealthBar/Fill


func _ready() -> void:
	health = max_health
	add_to_group("enemies")
	_apply_facing()
	_update_health_bar()


func _physics_process(delta: float) -> void:
	# Resolved lazily rather than in _ready: node _ready order follows the scene
	# tree, so an enemy placed above the Player would look for the group before
	# the Player has joined it — and then silently never fire.
	if _player == null:
		_player = get_tree().get_first_node_in_group("player")

	_tick_timers(delta)
	_update_feedback()

	if not is_on_floor():
		velocity.y = minf(velocity.y + gravity * delta, max_fall_speed)

	if _can_see_player():
		_engage(delta)
	else:
		_saw_player = false
		_patrol(delta)

	move_and_slide()


func _tick_timers(delta: float) -> void:
	_aim_timer = maxf(_aim_timer - delta, 0.0)
	_fire_cooldown = maxf(_fire_cooldown - delta, 0.0)
	_flash_timer = maxf(_flash_timer - delta, 0.0)
	_hit_timer = maxf(_hit_timer - delta, 0.0)
	_turn_cooldown = maxf(_turn_cooldown - delta, 0.0)


func _update_feedback() -> void:
	_muzzle_flash.visible = _flash_timer > 0.0
	# Single write point for modulate, so the flash can't fight anything else.
	_visuals.modulate = Color(3.0, 3.0, 3.0) if _hit_timer > 0.0 else Color.WHITE


func _patrol(delta: float) -> void:
	# is_on_floor() gates the turn because a RayCast2D reports no collision on
	# its first physics frame — without it every enemy spins around on spawn —
	# and it also stops mid-fall flips on real geometry.
	var blocked := _wall_check.is_colliding()
	var ledge_ahead := not _ledge_check.is_colliding()
	if is_on_floor() and _turn_cooldown <= 0.0 and (blocked or ledge_ahead):
		_set_facing(-facing)

	velocity.x = move_toward(velocity.x, facing * patrol_speed, patrol_speed * 8.0 * delta)


func _engage(delta: float) -> void:
	if not _saw_player:
		_saw_player = true
		_aim_timer = reaction_time

	var toward := 1 if _player.global_position.x > global_position.x else -1
	if toward != facing:
		_set_facing(toward)

	# Plant its feet to shoot — a moving, firing enemy is much harder to read.
	velocity.x = move_toward(velocity.x, 0.0, patrol_speed * 8.0 * delta)

	if _aim_timer <= 0.0 and _fire_cooldown <= 0.0:
		_fire()


func _fire() -> void:
	if bullet_scene == null:
		return
	_fire_cooldown = fire_interval
	_flash_timer = muzzle_flash_time

	var bullet := bullet_scene.instantiate()
	bullet.direction = facing
	get_parent().add_child(bullet)
	bullet.global_position = _muzzle.global_position


func _can_see_player() -> bool:
	if _player == null or health <= 0:
		return false

	var to_player := _player.global_position - global_position
	if absf(to_player.x) > sight_range or absf(to_player.y) > sight_height:
		return false

	# Raycast is masked to world only, so terrain blocks sight but the player
	# themselves never does.
	_sight_ray.target_position = to_local(_player.global_position + Vector2(0.0, -85.0))
	_sight_ray.force_raycast_update()
	return not _sight_ray.is_colliding()


func _set_facing(dir: int) -> void:
	facing = dir
	_turn_cooldown = 0.25
	_apply_facing()


func _apply_facing() -> void:
	_visuals.scale.x = facing
	# Raycasts live outside Visuals and are aimed explicitly — scaling a
	# RayCast2D by -1 is a good way to get confusing results.
	_wall_check.target_position = Vector2(48.0 * facing, 0.0)
	_ledge_check.position = Vector2(44.0 * facing, -12.0)


func take_damage(amount: int, from_direction: int = 0) -> void:
	if health <= 0:
		return
	health -= amount
	_update_health_bar()
	_hit_timer = hit_flash_time
	velocity.x += from_direction * 60.0
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
		puff.end_scale = 6.0
		puff.duration = 0.3
		get_parent().add_child(puff)
		puff.global_position = global_position + Vector2(0.0, -80.0)
	queue_free()
