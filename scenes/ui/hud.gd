class_name Hud
extends CanvasLayer

## The in-game readout, pinned to the top-left: health, and the weapon in hand.
##
## Owned by GameState and instantiated once at startup, exactly like the pause
## and game over menus: levels don't carry a HUD and don't need to know one
## exists, so a new level gets the readout for free and a level relaunched by
## Retry doesn't leak a second one.
##
## It finds the player rather than being handed one. `GameState.state_changed`
## looks like the obvious hook and is the wrong one — it fires while the
## *outgoing* scene is still current, because change_scene_to_file is deferred to
## the end of the frame, so a lookup from there finds the old level's player or
## nothing at all. Polling the `player` group is the same lazy resolution
## gunslinger.gd does, for the same reason, and it doubles as the visibility
## rule: a scene with a player is gameplay and gets a HUD, one without is a menu
## and doesn't.
##
## Two placement details. `layer` is below the pause overlay (100) and the debug
## overlay (200), so the pause dim covers this rather than the other way round.
## And it sits top-*left* because DebugOverlay owns the top-right corner.
##
## `process_mode` is PAUSABLE, set explicitly in the scene rather than left to
## inherit — this hangs off GameState, which is PROCESS_MODE_ALWAYS, so
## inheriting would quietly keep it polling behind the pause screen. Nothing here
## has anything to do while the game is frozen.

## Pip row is built from the player's max_health at runtime, so raising it is an
## inspector change and nothing here needs editing.
const PIP_SIZE := Vector2(58.0, 26.0)
const PIP_FULL := Color(0.85, 0.27, 0.25)
const PIP_EMPTY := Color(0.2, 0.16, 0.19)

## Weapon slots are built from the player's `weapons` list the same way the pips
## are built from max_health, and for the same reason: adding a weapon is then an
## inspector change with no edit here.
##
## Every weapon carried gets a slot, not just the one in hand — the equipped one
## is lit and the rest are dimmed. That's the part a name on its own can't do:
## with Q/E cycling you want to see what you're about to switch to, and once
## weapons are drip-fed it's also the readout that shows you've gained one.
const SLOT_SIZE := Vector2(76.0, 46.0)
## The swatch is inset from the slot on all sides, so the slot reads as a frame
## around it and the frame colour is what carries the equipped/idle state.
const SLOT_INSET := 6.0
const SLOT_FRAME_EQUIPPED := Color(0.95, 0.83, 0.6)
const SLOT_FRAME_IDLE := Color(0.2, 0.16, 0.19)
## Carried but not in hand: dimmed rather than hidden, so the row doesn't
## reshuffle every time you cycle.
const SLOT_IDLE_ALPHA := 0.45

var _player: Player
var _pips: Array[ColorRect] = []
var _slots: Array[ColorRect] = []

@onready var _pip_row: HBoxContainer = %PipRow
@onready var _slot_row: HBoxContainer = %SlotRow
@onready var _weapon_label: Label = %WeaponLabel


func _ready() -> void:
	visible = false


func _process(_delta: float) -> void:
	if not is_instance_valid(_player):
		_attach(get_tree().get_first_node_in_group("player") as Player)
	visible = is_instance_valid(_player)

	# Self-heal for a `weapons` list that grows at runtime, which is exactly what
	# unlocking one will do. `weapon_changed` can't cover it — that fires on a
	# switch, and gaining a weapon isn't one. Cheap because it only compares two
	# sizes; the rebuild itself runs on the frame the list actually changed.
	if is_instance_valid(_player) and _slots.size() != _player.weapons.size():
		_refresh_slots()


## Connecting and reading the current value happen together on purpose: the
## player sets its opening health and its opening weapon in its own _ready, long
## before this can be listening, so connecting alone would leave the row blank
## until the first hit and the weapon name blank until the first switch.
func _attach(player: Player) -> void:
	_player = player
	if player == null:
		return
	player.health_changed.connect(_on_health_changed)
	_on_health_changed(player.health, player.max_health)
	player.weapon_changed.connect(_on_weapon_changed)
	_on_weapon_changed(player.weapon)


func _on_health_changed(current: int, total: int) -> void:
	if _pips.size() != total:
		_rebuild_pips(total)
	for i in _pips.size():
		_pips[i].color = PIP_FULL if i < current else PIP_EMPTY


## Null is a real case, not a defensive check: a player whose `weapons` list is
## empty is unarmed and never emits anything else.
func _on_weapon_changed(weapon: Weapon) -> void:
	_weapon_label.text = weapon.display_name if weapon != null else "UNARMED"
	_refresh_slots()


## Lights the slot holding the equipped weapon and dims the rest. Matched by
## identity rather than by index because the index is the player's private
## business — and the same `.tres` listed twice would be a data error, not a case
## worth supporting.
func _refresh_slots() -> void:
	if _slots.size() != _player.weapons.size():
		_rebuild_slots()

	for i in _slots.size():
		var equipped := _player.weapons[i] == _player.weapon
		_slots[i].color = SLOT_FRAME_EQUIPPED if equipped else SLOT_FRAME_IDLE
		_slots[i].modulate.a = 1.0 if equipped else SLOT_IDLE_ALPHA


func _rebuild_slots() -> void:
	for slot in _slots:
		slot.queue_free()
	_slots.clear()

	for weapon in _player.weapons:
		var slot := ColorRect.new()
		slot.custom_minimum_size = SLOT_SIZE
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE

		# Anchored to the slot rather than given a fixed size, so changing
		# SLOT_SIZE resizes the swatch with it. Anchors are set explicitly because
		# a ColorRect is not a container — nothing lays this child out for it.
		var swatch := ColorRect.new()
		swatch.anchor_right = 1.0
		swatch.anchor_bottom = 1.0
		swatch.offset_left = SLOT_INSET
		swatch.offset_top = SLOT_INSET
		swatch.offset_right = -SLOT_INSET
		swatch.offset_bottom = -SLOT_INSET
		swatch.color = weapon.ui_color if weapon != null else Color.BLACK
		swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE

		slot.add_child(swatch)
		_slot_row.add_child(slot)
		_slots.append(slot)


func _rebuild_pips(count: int) -> void:
	for pip in _pips:
		pip.queue_free()
	_pips.clear()

	for i in count:
		var pip := ColorRect.new()
		pip.custom_minimum_size = PIP_SIZE
		pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_pip_row.add_child(pip)
		_pips.append(pip)
