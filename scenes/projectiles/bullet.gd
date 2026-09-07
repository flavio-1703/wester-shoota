class_name Bullet
extends Area2D

## Straight-line projectile, shared by the player and by enemies. Travels until
## it hits something on its collision mask or its lifetime expires.
##
## Who it can hurt is decided entirely by the layer/mask on the scene, not here:
## see bullet.tscn (player's), pellet.tscn (shotgun) and enemy_bullet.tscn.
##
## Range is `speed * lifetime` and lives on the scene, not on the weapon — it's
## the knob that separates a rifle from a shotgun, so it belongs with the other
## per-variant differences.

@export var speed: float = 1800.0
## Seconds before a stray bullet cleans itself up.
@export var lifetime: float = 1.2
@export var damage: int = 1
@export var puff_scene: PackedScene
## Played when this lands on something that can be hurt — see _on_hit(). Terrain
## is deliberately silent for now; the branch is right there when it wants a
## sound of its own.
##
## Set on bullet.tscn and pellet.tscn, and deliberately LEFT EMPTY on
## enemy_bullet.tscn. Partly scope — the player being hit is a different sound
## and hasn't been made yet — but mostly because Sfx.play_at() dedupes per
## stream: hand the enemies the same sample and one of their bullets reaching
## the player would swallow the sound of your own shot landing, and the other way
## round. A distinct stream for taking damage is safe here; a shared one is not.
@export var impact_sound: AudioStream

## Set by whoever fires it: 1 for right, -1 for left. Stays an int rather than
## folding into the angle below, because it's what gets handed to take_damage()
## as the knockback direction.
var direction: int = 1
## Deviation from horizontal, in radians — how a shotgun gets its spread. Set it
## before add_child, like `direction`: it's read once and baked into the travel
## velocity.
var angle: float = 0.0

var _velocity: Vector2
var _life: float = 0.0
## Both body_entered and area_entered can fire before queue_free takes effect,
## so a spent bullet must refuse to hit twice.
var _spent: bool = false


func _ready() -> void:
	_life = lifetime
	# Travel is a baked vector, not a node rotation applied to horizontal motion
	# — rotating the node alone would tilt the sprite while the bullet carried
	# straight on. `rotation` is then set from the vector so the two can't
	# disagree. At angle 0 this is arithmetically the horizontal travel it always
	# did, which is what leaves enemy fire and the revolver untouched.
	_velocity = Vector2(direction * speed, 0.0).rotated(angle)
	rotation = _velocity.angle()
	body_entered.connect(_on_hit)
	area_entered.connect(_on_hit)


func _physics_process(delta: float) -> void:
	_life -= delta
	if _life <= 0.0:
		queue_free()
		return
	position += _velocity * delta


func _on_hit(node: Node) -> void:
	if _spent:
		return
	_spent = true

	# Pass travel direction so the target knows which way to be knocked back.
	#
	# `has_method("take_damage")` is the only thing separating a body from a wall
	# here — the mask includes the world layer — so this branch is exactly "hit
	# something that bleeds", which is what earns the sound.
	if node.has_method("take_damage"):
		node.take_damage(damage, direction)
		# Through the autoload rather than a player node on this bullet or on the
		# puff. This node is freed two lines below, which would cut a child player
		# off before it made a sound; and the puff can't carry it either, since
		# `puff_scene` is optional and _spawn_puff() may do nothing at all.
		Sfx.play_at(impact_sound, global_position, 0.0, randf_range(0.92, 1.08))

	_spawn_puff()
	queue_free()


func _spawn_puff() -> void:
	if puff_scene == null:
		return
	var puff := puff_scene.instantiate()
	get_parent().add_child(puff)
	puff.global_position = global_position
