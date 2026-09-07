class_name SaloonCheckpoint
extends Area2D

## A saloon: bonfire, in a hat.
##
## Resting refills health and the tequila flask, records this saloon as where the
## player comes back to, and **reloads the level** — which is what puts the
## enemies back. That last part is the bonfire bargain, and it's deliberately a
## plain level swap through `GameState` rather than an enemy-reset manager:
## nothing in the level holds progression state yet, so a reload *is* the reset
## and costs no new code to keep correct. When something one-off does land — a
## boss, an opened shortcut — this is the line that has to change.
##
## It carries no blocking collision at all. The building is ColorRects for
## readability; the only physics here is this Area2D, on the pickups layer and
## masked to the player, so nothing about it can stall a run.
##
## Interaction is polled from `_physics_process` rather than handled from
## `_input`, matching the player: everything in this game reads input on the
## physics tick, and `Input.action_press()` faked from a `_process` frame never
## produces a `just_pressed` edge for a physics-frame reader.

## Emitted after a successful rest, before the level reload is asked for. Nothing
## listens yet; it's here so audio, a fade or a "you rested" line can attach
## without this file learning about them.
signal rested

## Unique per placed saloon. The active one is stored in `GameState` by id, so
## two saloons sharing an id would both light up and the wrong one could claim
## the respawn. Levels are responsible for keeping these distinct.
@export var checkpoint_id: StringName = &"saloon"

## Off for the headless checks in tools/, which drive `rest()` directly and would
## otherwise have the scene swapped out from under them mid-assert. Leave it on
## in the game — without the reload, resting refills you but leaves every enemy
## exactly where the last attempt left them.
@export var reload_on_rest: bool = true

@export_group("Presentation")
## Windows and lantern lit vs. shuttered. The whole active/inactive read is
## carried by these two, applied to the same nodes, so there is no second set of
## art to keep in sync.
@export var lit_color: Color = Color(1.0, 0.78, 0.35)
@export var unlit_color: Color = Color(0.36, 0.3, 0.26)
## Multiplied over the whole building. An unrested saloon sits in shadow.
@export var lit_tint: Color = Color(1.0, 0.96, 0.88)
@export var unlit_tint: Color = Color(0.72, 0.68, 0.66)
## Seconds per breath of the lantern glow. Motion is what makes the lit state
## read at a glance on a still frame full of static rectangles.
@export var glow_period: float = 2.2
@export var glow_amount: float = 0.26
## Opacity of the light pool with the lantern at its dimmest.
@export var glow_floor: float = 0.24

## True while the player's body overlaps the interaction area. The prompt follows
## it, and it is the gate on the interact press.
var _player_in_range: Player = null
## Cleared on exit rather than on rest, so holding the key inside the area can't
## re-trigger, but stepping out and back in can rest again.
var _rested_this_visit: bool = false
var _active: bool = false
var _glow_t: float = 0.0

@onready var _prompt: Label = $Prompt
@onready var _spawn_point: Marker2D = $SpawnPoint
@onready var _building: Node2D = $Building
@onready var _windows: Array[Node] = [
	$Building/WindowLeft, $Building/WindowRight, $Building/Doorway
]
@onready var _lantern: ColorRect = $Building/Lantern
@onready var _glow: ColorRect = $Building/Glow


func _ready() -> void:
	_prompt.visible = false
	# A saloon rested at before a reload has to come back lit, or the level looks
	# like it forgot. `GameState` is the only thing that survives the swap, so it
	# is what gets asked.
	_set_active(GameState.is_active_checkpoint(checkpoint_id))
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _physics_process(delta: float) -> void:
	_update_glow(delta)

	if _player_in_range == null or _rested_this_visit:
		return
	if Input.is_action_just_pressed("interact"):
		rest()


## Public and separate from the input read so the headless check can drive the
## same code path the player does. Safe to call twice — the visit latch and the
## dead-player guard are both in here rather than at the call site.
func rest() -> void:
	if _rested_this_visit or _player_in_range == null:
		return
	_rested_this_visit = true

	# Recorded BEFORE the refill and the reload. `Player._ready()` asks
	# `GameState` where to stand, so on the reload below the checkpoint has to
	# already be the answer or the player lands back at the level's opening spawn.
	GameState.set_checkpoint(checkpoint_id, _spawn_point.global_position)
	_player_in_range.rest_refill()
	_set_active(true)
	_prompt.visible = false
	rested.emit()

	if reload_on_rest:
		GameState.rest_at_checkpoint()


func _on_body_entered(body: Node2D) -> void:
	if body is not Player:
		return
	_player_in_range = body as Player
	_rested_this_visit = false
	_prompt.visible = true


func _on_body_exited(body: Node2D) -> void:
	if body != _player_in_range:
		return
	_player_in_range = null
	_rested_this_visit = false
	_prompt.visible = false


## The one writer of everything that differs between a rested and an unrested
## saloon, so the two states can't drift apart across nodes.
func _set_active(value: bool) -> void:
	_active = value
	_building.modulate = lit_tint if _active else unlit_tint
	_lantern.color = lit_color if _active else unlit_color
	for window in _windows:
		(window as ColorRect).color = lit_color if _active else unlit_color
	_glow.color = lit_color
	_glow.visible = _active


func _update_glow(delta: float) -> void:
	if not _active or glow_period <= 0.0:
		return
	_glow_t = fmod(_glow_t + delta, glow_period)
	var breath := 0.5 - 0.5 * cos(TAU * _glow_t / glow_period)
	# Alpha only. Scaling the rect would make the pool's edges crawl against the
	# hard-edged porch next to it, which reads as a rendering fault.
	_glow.modulate.a = glow_floor + glow_amount * breath
