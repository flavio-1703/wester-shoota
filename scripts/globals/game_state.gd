extends Node

## Autoload. Owns which screen the game is on, every scene swap, the pause, and
## death.
##
## Nothing else calls change_scene_to_file or touches get_tree().paused.
## Routing swaps through here means a fade, a loading screen or a save-on-exit
## can be added in one place later without hunting down call sites — a menu
## button says "start a new game", not "load res://scenes/levels/test_level.tscn".

## Emitted after `state` changes. The three transitions don't look alike, so a
## listener has to know which it's handling:
##
## - Scene swaps (MENU / PLAYING): the new scene isn't in the tree yet, because
##   change_scene_to_file is deferred to the end of the frame, so a listener
##   runs while the *old* scene is still current.
## - Pause and resume: nothing is swapped and the tree is untouched.
## - GAME_OVER: the tree pauses immediately, but the death overlay stays hidden
##   for GAME_OVER_DELAY seconds so the death reads on screen first. The state
##   is already GAME_OVER for that whole window.
signal state_changed(new_state: State)

enum State {
	MENU,
	PLAYING,
	## Gameplay is still in the tree, frozen, with the pause overlay on top.
	PAUSED,
	## The player is dead. Same freeze as PAUSED, but the only ways out are
	## Retry, the main menu, or quitting — `pause` input is ignored.
	GAME_OVER,
}

const MAIN_MENU_SCENE := "res://scenes/ui/main_menu.tscn"
## The level the Play button starts. Becomes a level table once there's more
## than one.
const FIRST_LEVEL_SCENE := "res://scenes/levels/test_level.tscn"
const PAUSE_MENU_SCENE := "res://scenes/ui/pause_menu.tscn"
const GAME_OVER_MENU_SCENE := "res://scenes/ui/game_over_menu.tscn"
const HUD_SCENE := "res://scenes/ui/hud.tscn"

## Freeze-frame on death before the overlay lands. Without it the menu covers
## the moment the player is trying to read.
const GAME_OVER_DELAY := 0.7

var state: State = State.MENU

## What Retry reloads. Defaults to the first level so that dying still works
## when a level scene was launched directly with F6, where nothing ever called
## start_new_game().
var _current_level: String = FIRST_LEVEL_SCENE

## The saloon last rested at, if any — a Dark Souls bonfire in three fields.
## Session-only: there is no disk save yet, so quitting the executable loses it.
##
## Level identity is the scene path recorded when the checkpoint was set, and it
## is compared against `_current_level` rather than against
## `get_tree().current_scene`. Two reasons: every level change already goes
## through this autoload, so `_current_level` is authoritative and needs no
## engine-ordering assumption during a swap; and `current_scene` is null when a
## level is added to the root by hand, which is exactly what the headless check
## scripts in tools/ do.
##
## The trade-off is that a *second* level launched directly with F6 would still
## report as FIRST_LEVEL_SCENE, so a checkpoint from the first level would be
## offered to it. `set_checkpoint()` therefore also writes `_current_level`,
## which keeps Retry honest for whichever level actually rested.
var _checkpoint_level: String = ""
var _checkpoint_id: StringName = &""
var _checkpoint_position: Vector2 = Vector2.ZERO

var _pause_menu: PauseMenu
var _game_over_menu: GameOverMenu
var _hud: Hud


func _ready() -> void:
	# This autoload owns the un-pause input and every overlay, so it is the one
	# thing that must keep running while the tree is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS

	# Parented to this autoload rather than to the root: adding to the root from
	# an autoload's _ready() runs while the root is still assembling itself.
	# CanvasLayer draw order comes from `layer`, not from tree position, so
	# sitting off to the side of the scene tree costs nothing.
	_pause_menu = load(PAUSE_MENU_SCENE).instantiate() as PauseMenu
	add_child(_pause_menu)
	_game_over_menu = load(GAME_OVER_MENU_SCENE).instantiate() as GameOverMenu
	add_child(_game_over_menu)
	# Nothing calls into the HUD — it follows whichever player is in the tree and
	# shows itself accordingly, so it needs no handling in the routing below.
	_hud = load(HUD_SCENE).instantiate() as Hud
	add_child(_hud)


## The toggle lives here, not on the pause menu, because the menu can't be
## reached to unpause it while it's hidden — one owner for both directions.
## Deliberately does nothing in GAME_OVER: death is not something you un-pause
## your way out of.
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("pause"):
		return

	if state == State.PLAYING:
		pause_game()
	elif state == State.PAUSED:
		resume_game()
	else:
		return

	get_viewport().set_input_as_handled()


func pause_game() -> void:
	if state != State.PLAYING:
		return
	get_tree().paused = true
	_pause_menu.open()
	_set_state(State.PAUSED)


func resume_game() -> void:
	if state != State.PAUSED:
		return
	_pause_menu.close()
	get_tree().paused = false
	_set_state(State.PLAYING)


## Called by the player when it dies — health gone, or fallen out of the level.
## Guarded on GAME_OVER rather than on PLAYING so that a level launched directly
## with F6 (where the state is still MENU) can still kill you.
func game_over() -> void:
	if state == State.GAME_OVER:
		return

	get_tree().paused = true
	_set_state(State.GAME_OVER)

	# process_always is passed explicitly, not left to the default: the tree was
	# paused on the line above, and a timer that froze with it would hang here
	# with no overlay and no way out.
	await get_tree().create_timer(GAME_OVER_DELAY, true).timeout

	# Re-checked because anything could have routed away during the delay.
	if state == State.GAME_OVER:
		_game_over_menu.open()


func start_new_game() -> void:
	# A new game starts at the level's own spawn, not at wherever the last run
	# happened to rest.
	clear_checkpoint()
	_current_level = FIRST_LEVEL_SCENE
	_go_to(State.PLAYING, _current_level)


## Retry reloads the level; where the player lands inside it is decided by the
## checkpoint, which `Player._ready()` asks for. That indirection is why this
## function is unchanged — a level with no checkpoint retries from the top
## exactly as it did before.
func retry_level() -> void:
	_go_to(State.PLAYING, _current_level)


# --- Checkpoints -------------------------------------------------------------

## Called by a saloon when the player rests at it. `position` is where the player
## should stand on the next respawn — the saloon's own spawn marker, not the
## player's position at the moment of resting, so the respawn is repeatable.
func set_checkpoint(id: StringName, position: Vector2, level_path: String = "") -> void:
	_checkpoint_level = level_path if not level_path.is_empty() else _current_level
	_checkpoint_id = id
	_checkpoint_position = position
	# So Retry reloads the level the checkpoint is actually in, including a level
	# launched directly with F6 that never went through start_new_game().
	_current_level = _checkpoint_level


func clear_checkpoint() -> void:
	_checkpoint_level = ""
	_checkpoint_id = &""
	_checkpoint_position = Vector2.ZERO


## True only for the saloon that is currently lit, and only in its own level, so
## two levels can each hold a checkpoint with the same id without either one
## lighting up in the other.
func is_active_checkpoint(id: StringName, level_path: String = "") -> bool:
	if _checkpoint_id.is_empty() or id != _checkpoint_id:
		return false
	var level := level_path if not level_path.is_empty() else _current_level
	return level == _checkpoint_level


## Where the player should stand. `fallback` is the position the level authored,
## returned unchanged when there is no checkpoint for this level — so an ordinary
## launch, a level with no saloon in it, and a saloon rested at in a *different*
## level all behave exactly as they did before checkpoints existed.
func get_respawn_position(fallback: Vector2) -> Vector2:
	if _checkpoint_level.is_empty() or _checkpoint_level != _current_level:
		return fallback
	return _checkpoint_position


## Resting reloads the level, which is what puts the enemies back — the bonfire
## half of the bonfire. Deliberately reuses the ordinary level swap rather than
## adding a reset manager: nothing in the level holds progression state yet, so
## a reload *is* the reset, and it costs no new code to keep correct.
##
## The checkpoint must already be recorded when this is called, or the reload
## lands the player back at the level's opening spawn.
func rest_at_checkpoint() -> void:
	_go_to(State.PLAYING, _current_level)


func return_to_menu() -> void:
	_go_to(State.MENU, MAIN_MENU_SCENE)


## Ends the main loop. Nodes still get NOTIFICATION_EXIT_TREE on the way out,
## but this does *not* fire NOTIFICATION_WM_CLOSE_REQUEST — that one only comes
## from the window manager when the user clicks the X. Save-on-exit therefore
## belongs here (or on exit_tree), not on a WM_CLOSE_REQUEST handler, or the
## Quit button would skip it.
func quit_game() -> void:
	get_tree().quit()


func _go_to(next: State, scene_path: String) -> void:
	var error := get_tree().change_scene_to_file(scene_path)
	if error != OK:
		# Nothing has been touched yet, so a failed load leaves the game exactly
		# where it was — including still paused, if that's where it was.
		push_error("GameState: could not load %s (error %d)" % [scene_path, error])
		return

	# Every transition clears both overlays and the pause. "Main Menu" from the
	# pause or death screen is the case that bites: leave the tree paused and
	# the menu arrives frozen, with nothing left running to unfreeze it.
	_clear_overlays()
	_set_state(next)


func _clear_overlays() -> void:
	_pause_menu.close()
	_game_over_menu.close()
	get_tree().paused = false


func _set_state(next: State) -> void:
	state = next
	state_changed.emit(state)
