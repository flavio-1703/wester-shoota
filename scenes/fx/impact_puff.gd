extends Node2D

## Short expand-and-fade burst, spawned where a bullet lands.
## Frees itself when the tween finishes.

@export var duration: float = 0.18
@export var end_scale: float = 2.4


func _ready() -> void:
	var tween := create_tween().set_parallel()
	tween.tween_property(self, "scale", Vector2.ONE * end_scale, duration) \
		.set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "modulate:a", 0.0, duration)
	tween.finished.connect(queue_free)
