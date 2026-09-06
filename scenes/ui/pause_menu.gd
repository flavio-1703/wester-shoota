class_name PauseMenu
extends CanvasLayer

## The pause overlay. GameState instantiates this once at startup and shows or
## hides it; it is never created per pause, so there's no allocation on the
## pause keypress and no instance-validity dance on the way out.
##
## Two structural details that are easy to get wrong:
##
## `process_mode` is ALWAYS (set on the scene root) because this is the one
## thing that has to keep running while `get_tree().paused` is true — freezing
## the pause menu along with the game is an unrecoverable soft-lock.
##
## What gets toggled is the `Overlay` **Control**, not this CanvasLayer.
## CanvasLayer isn't a CanvasItem, so hiding it doesn't feed into
## `Control.is_visible_in_tree()` — the buttons underneath would still hold
## focus and still answer input while apparently hidden. Toggling the Control
## gets Godot's ordinary visibility semantics instead.

@onready var _overlay: Control = %Overlay
@onready var _resume_button: Button = %ResumeButton


func _ready() -> void:
	_overlay.visible = false


## Focus is grabbed here rather than in _ready() because this node lives in the
## tree from startup — there is no ready moment that coincides with the menu
## actually appearing.
func open() -> void:
	_overlay.visible = true
	_resume_button.grab_focus()


func close() -> void:
	_overlay.visible = false


func _on_resume_pressed() -> void:
	GameState.resume_game()


func _on_main_menu_pressed() -> void:
	GameState.return_to_menu()


func _on_quit_pressed() -> void:
	GameState.quit_game()
