extends Sprite2D

## A short muzzle burst, drawn only for the poses that have no flash painted in.
##
## The sheet paints its own flash into shoot[3..6] and crouch[7], so this must
## never play over those or the shot flashes twice. player.gd owns that gate —
## see UNPAINTED_FLASH_CLIPS — and this scene just draws what it is told to.
##
## Parented to the player's Visuals rather than to the level: it lasts a couple
## of frames, so it should travel with a running player, and being under Visuals
## means it mirrors with the facing flip for free.

@export var duration: float = 0.07
@export var start_scale: float = 0.72
@export var end_scale: float = 1.05


func _ready() -> void:
	rotation = randf_range(-0.25, 0.25)
	scale = Vector2.ONE * start_scale
	var tween := create_tween().set_parallel()
	tween.tween_property(self, "scale", Vector2.ONE * end_scale, duration) \
		.set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "modulate:a", 0.0, duration) \
		.set_ease(Tween.EASE_IN)
	tween.finished.connect(queue_free)
