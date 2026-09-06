extends Control

## Main menu. Deliberately thin: the buttons hand off to GameState and this
## script owns nothing but focus.
##
## Focus is grabbed on ready because the project ships full gamepad bindings —
## a menu you can only click would be a regression. The VBoxContainer supplies
## the focus chain, so Godot's built-in ui_up / ui_down / ui_accept navigate it
## without any new input actions.

@onready var _play_button: Button = %PlayButton


func _ready() -> void:
	_play_button.grab_focus()


func _on_play_pressed() -> void:
	GameState.start_new_game()


func _on_quit_pressed() -> void:
	GameState.quit_game()
