class_name TequilaStash
extends Area2D

## A bottle left in the world: restores flask charges, never past the maximum.
##
## The whole of the "is there room for it" decision lives in
## `Player.add_flask_charges()`, which returns whether it actually took any. That
## is what lets this stay in the level when the player walks past with a full
## flask instead of being consumed for nothing — the same courtesy a health
## pickup owes you, and the reason the check isn't duplicated here.
##
## This is the smallest useful shape for the collectibles still to come. An
## `Agave Heart` (raise `flask_charges_max`), a `Silver Flask Cap` (raise
## `flask_heal_amount`) and a `Gold Nugget` are the same six lines with a
## different call in `_try_collect()`. Deliberately not generalised into a base
## class yet: with one implementation there is nothing to factor out, and
## guessing at the shared part now is how you get a base class that fits none of
## them. See README > The tequila flask.

## How many swigs the bottle is worth.
@export var charges: int = 1
@export var pickup_puff_scene: PackedScene
@export_group("Presentation")
## Pixels the bottle rises and falls, so it reads as a collectible rather than as
## another piece of level geometry.
@export var bob_height: float = 10.0
@export var bob_period: float = 1.8

var _player_inside: Player = null
var _t: float = 0.0

@onready var _bottle: Node2D = $Bottle
@onready var _rest_y: float = _bottle.position.y


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


## Collection is retried every frame the player overlaps, not only on the entry
## signal. Walking in with a full flask would otherwise arm the bottle and never
## fire it again — `body_entered` doesn't repeat for a body that never left.
func _physics_process(delta: float) -> void:
	if bob_period > 0.0:
		_t = fmod(_t + delta, bob_period)
		_bottle.position.y = _rest_y - bob_height * sin(TAU * _t / bob_period)

	if _player_inside != null:
		_try_collect(_player_inside)


func _try_collect(player: Player) -> void:
	if not player.add_flask_charges(charges):
		return

	if pickup_puff_scene != null:
		var puff := pickup_puff_scene.instantiate()
		# Set before add_child — the puff reads its tunables in its own _ready.
		puff.end_scale = 1.4
		puff.duration = 0.35
		get_parent().add_child(puff)
		puff.global_position = global_position
		puff.self_modulate = Color(1.0, 0.78, 0.34)

	queue_free()


func _on_body_entered(body: Node2D) -> void:
	if body is Player:
		_player_inside = body as Player


func _on_body_exited(body: Node2D) -> void:
	if body == _player_inside:
		_player_inside = null
