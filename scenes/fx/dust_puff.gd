extends Sprite2D

## A kicked-up dust cloud: drifts, swells, fades, frees itself.
##
## Used for every ground effect the player makes — takeoff, landing, running,
## sliding, skidding — with the spawner varying `velocity`, `spin` and the
## initial scale rather than there being a scene per effect.
##
## Spawned into the LEVEL, not onto the player, so the dust stays where it was
## kicked up instead of travelling along at run_speed.
##
## Drift is integrated in _process rather than tweened. A position tween has to
## capture its target when it starts, which is _ready — before the spawner has
## had a chance to place the puff — so it would drag every puff back toward the
## origin. Scale and alpha have no such dependency and are tweened.

## Pixels per second, set by the spawner. Read from _process, so unlike
## Bullet.direction it is safe to set either side of add_child().
var velocity: Vector2 = Vector2.ZERO
## Radians turned over the puff's life.
var spin: float = 0.0

@export var duration: float = 0.36
@export var start_scale: float = 0.45
@export var end_scale: float = 1.0
## Fraction of speed shed per second — dust stalls rather than flying straight.
@export var drag: float = 6.0
## Opacity at spawn. Set below 1 so dust reads as suspended grit rather than as
## a solid object; the fade tween starts from here.
@export var start_alpha: float = 0.85


func _ready() -> void:
	# Randomised per puff so a run cycle doesn't stamp the same cloud repeatedly.
	rotation = randf() * TAU
	flip_h = randf() < 0.5
	scale = Vector2.ONE * start_scale
	# Before the tween is built: it captures its start value when created.
	modulate.a = start_alpha

	var tween := create_tween().set_parallel()
	tween.tween_property(self, "scale", Vector2.ONE * end_scale, duration) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(self, "modulate:a", 0.0, duration) \
		.set_ease(Tween.EASE_IN)
	tween.tween_property(self, "rotation", rotation + spin, duration)
	tween.finished.connect(queue_free)


func _process(delta: float) -> void:
	position += velocity * delta
	velocity = velocity.lerp(Vector2.ZERO, minf(drag * delta, 1.0))
