class_name GameOverMenu
extends CanvasLayer

## The death overlay. Built the same way as `pause_menu.tscn` and for the same
## reasons — see that file for why `process_mode` is ALWAYS and why the thing
## being toggled is the inner `Overlay` Control rather than this CanvasLayer.
##
## Retry is focused and the destructive buttons come last, so a reflexive
## gamepad A press restarts the level instead of dumping the player to the menu.

@onready var _overlay: Control = %Overlay
@onready var _retry_button: Button = %RetryButton


func _ready() -> void:
	_overlay.visible = false


func open() -> void:
	_overlay.visible = true
	_retry_button.grab_focus()


func close() -> void:
	_overlay.visible = false


func _on_retry_pressed() -> void:
	GameState.retry_level()


func _on_main_menu_pressed() -> void:
	GameState.return_to_menu()


func _on_quit_pressed() -> void:
	GameState.quit_game()
