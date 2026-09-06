class_name PlayerCamera2D
extends Camera2D

## The player's camera: look-ahead in the facing direction, trauma-based shake,
## and level bounds pulled from the level instead of hardcoded on the player.
##
## Look-ahead follows *facing* rather than velocity: in a shooter you want to
## see what you're aimed at, including while standing still.

## Group name of a Control in the level whose rect defines the camera limits.
const BOUNDS_GROUP := "camera_bounds"

@export_group("Look-ahead")
## How far ahead of the player the view leads, in pixels.
@export var lookahead_distance: float = 260.0
## Pixels per second the look-ahead slides. Too fast and turning reads as a lurch.
@export var lookahead_speed: float = 500.0

@export_group("Shake")
@export var max_offset: Vector2 = Vector2(24.0, 16.0)
## Radians. Requires ignore_rotation = false on this camera to have any effect.
@export var max_roll: float = 0.03
## Trauma lost per second.
@export var decay: float = 4.0
@export var noise_speed: float = 40.0

var _trauma: float = 0.0
var _noise := FastNoiseLite.new()
var _noise_t: float = 0.0
var _look: float = 0.0
var _look_target: float = 0.0


func _ready() -> void:
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 0.5
	_apply_level_bounds()


## Limits are a property of the level, so they're read from a CameraBounds node
## there rather than baked into the player scene. Group membership is declared
## in the .tscn, which means it exists at instantiation and doesn't depend on
## _ready order. Falls back to whatever limits the scene already carries.
func _apply_level_bounds() -> void:
	var node: Node = get_tree().get_first_node_in_group(BOUNDS_GROUP)
	if node == null or not (node is Control):
		return

	var rect: Rect2 = (node as Control).get_global_rect()
	limit_left = int(rect.position.x)
	limit_top = int(rect.position.y)
	limit_right = int(rect.end.x)
	limit_bottom = int(rect.end.y)


func add_trauma(amount: float) -> void:
	_trauma = minf(_trauma + amount, 1.0)


## dir is -1, 0 or 1 — which way the view should lead.
func set_look_direction(dir: float) -> void:
	_look_target = lookahead_distance * clampf(dir, -1.0, 1.0)


func _process(delta: float) -> void:
	_look = move_toward(_look, _look_target, lookahead_speed * delta)

	if _trauma > 0.0:
		_trauma = maxf(_trauma - decay * delta, 0.0)
		_noise_t += delta * noise_speed

	# Squared so a light tap barely registers and a big hit really moves.
	var amount := _trauma * _trauma
	var shake := Vector2(
		max_offset.x * amount * _noise.get_noise_2d(_noise_t, 0.0),
		max_offset.y * amount * _noise.get_noise_2d(0.0, _noise_t)
	)

	# Look-ahead and shake both want `offset`, so they're summed and written
	# once — two separate assignments would silently clobber each other.
	offset = Vector2(_look, 0.0) + shake
	rotation = max_roll * amount * _noise.get_noise_2d(_noise_t, _noise_t)
