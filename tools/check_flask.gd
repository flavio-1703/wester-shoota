extends SceneTree

## Tequila flask + saloon checkpoint regression check.
##
##   Godot_v4.7.2-stable_win64.exe --headless --path . --script res://tools/check_flask.gd
##
## Structured like `check_player_fx.gd` and for the same reason: it drives the
## real player in the real level with faked input, so the clamps, the gates and
## the timing come out of the production code path rather than out of a mock.
## The notes at the top of that file about input emulation apply here too — most
## importantly that everything runs in `_physics_process`, so input faked from
## `_process` never produces a `just_pressed` edge.
##
## What it covers, and why each one is worth a test rather than a read-through:
##
##   1. `flask_charges` cannot go below 0 or above `flask_charges_max`, whatever
##      arithmetic a caller does — the clamp is in `_set_flask_charges()` and a
##      future pickup will be trusting it.
##   2. A swig spends its charge on the PRESS and delivers the health
##      `drink_heal_delay` LATER. Those two being separate events is the whole
##      feel of the flask, and nothing else notices if they collapse together.
##   3. Healing does not overheal, even when `flask_heal_amount` exceeds the
##      missing health.
##   4. Shooting is refused mid-swig. That's the cost that makes the flask a
##      decision; without a test it silently stops being one.
##   5. Resting at a saloon refills health AND flask, and records the checkpoint.
##   6. Retry resolves to the active checkpoint for this level, and falls back to
##      the level's authored spawn when there isn't one — the case that must keep
##      working for every level with no saloon in it.
##   7. A REAL level reload — not `get_respawn_position()` in isolation — puts the
##      player at the saloon, at full health, with a full flask, and the saloon
##      comes back lit. Everything upstream of `Player._ready()` can be right and
##      still land the player at the level's opening spawn.
##   8. The flask readout does not overlap the health pips or the weapon slots.
##      The HUD row positions are hand-placed numbers in `hud.tscn`; the README
##      records that the weapon row was originally verified against a rendered
##      frame, and adding a row between them is exactly what would quietly undo
##      that. Rect intersection is the check a charge-count assert cannot make.

const ACTIONS := ["heal", "interact", "shoot", "move_right", "move_left", "jump", "crouch"]

var _level: Node
var _player: Node
var _saloon: Node
var _hud: Node
## The GameState autoload, reached through the root rather than by its global
## name. A `--script` SceneTree is compiled before the autoloads are registered,
## so `GameState` is not a resolvable identifier in this file even though the
## singleton is very much alive by the time _physics_process runs. Every other
## script in the project is compiled after registration and uses the name.
var _gs: Node

var _phase := 0
var _t := 0.0
var _fails := 0
var _started := false

## Carried across the frames of a phase, since each phase samples at two or three
## different times and has to compare against what it set up at the start.
var _health_at_press := 0
var _charges_at_press := 0
var _mid_drink_checked := false
var _saloon_spawn := Vector2.ZERO
## Labels already reported in this phase. See _check().
var _seen: Dictionary = {}


func _initialize() -> void:
	_level = load("res://scenes/levels/test_level.tscn").instantiate()
	root.add_child(_level)


func _release_all() -> void:
	for a in ACTIONS:
		Input.action_release(a)


func _next() -> void:
	_phase += 1
	_t = 0.0
	_mid_drink_checked = false
	_seen.clear()
	_release_all()


## Reported once per phase per label. Several of the assertions below sit inside
## a time WINDOW rather than on a single frame — deliberately, because a
## one-frame probe is how `check_player_fx.gd` learned to read false passes off
## effects that had not happened yet — and a window spans several physics ticks.
## Deduping here keeps that robustness without printing the same line three times.
func _check(label: String, ok: bool, detail: String = "") -> void:
	if _seen.has(label):
		return
	_seen[label] = true
	if not ok:
		_fails += 1
	print("  %-44s %-9s %s" % [label, "OK" if ok else "*** FAIL", detail])


## Bullets are spawned as siblings of the player, so this is where they land.
func _bullet_count() -> int:
	var n := 0
	for c in _level.get_children():
		if c.name.begins_with("Bullet"):
			n += 1
	return n


func _physics_process(delta: float) -> bool:
	# Latched rather than keyed off `_player == null`, because the last phase
	# deliberately drops the level and the player to do a real scene reload.
	if not _started:
		_player = _level.get_tree().get_first_node_in_group("player")
		if _player == null:
			return false
		_started = true
		_saloon = _level.get_node("Saloon")
		# The HUD hangs off the GameState autoload, not off the level — see
		# hud.gd. Reached by name because nothing hands it out.
		_gs = root.get_node("GameState")
		_hud = _gs.get_node("Hud")
		# Enemies are live in this level and a knockback mid-measurement would
		# corrupt every health assert below. Re-armed each phase.
		_player._invuln_timer = 999.0
		_release_all()
		print("\n--- flask invariants ---")

	_t += delta
	# The i-frame shield decays like any other timer, so it is topped up rather
	# than set once. Guarded because the reload phase frees the player it was
	# holding and picks a new one up on the other side.
	if is_instance_valid(_player):
		_player._invuln_timer = 999.0

	match _phase:
		# A: the opening state, and the ceiling. A full flask cannot be topped up
		# and a full player cannot drink — both are refusals a pickup and the HUD
		# depend on.
		0:
			if _t < 0.02:
				_check("opens full", _player.flask_charges == _player.flask_charges_max,
					"%d / %d" % [_player.flask_charges, _player.flask_charges_max])
				_check("add_flask_charges refused when full",
					_player.add_flask_charges(1) == false,
					"charges still %d" % _player.flask_charges)
				_check("charges did not exceed max",
					_player.flask_charges == _player.flask_charges_max)
				_check("can_drink() false at full health", _player.can_drink() == false)
				_charges_at_press = _player.flask_charges
			if _t > 0.02 and _t < 0.14:
				Input.action_press("heal")
			if _t > 0.30:
				_check("heal press at full health spends nothing",
					_player.flask_charges == _charges_at_press,
					"%d charges" % _player.flask_charges)
				_next()
		# B: the clamps, driven straight at the setter so no amount of caller
		# arithmetic can be blamed for a pass.
		1:
			if _t < 0.02:
				_player._set_flask_charges(-5)
				_check("clamped at 0, never negative", _player.flask_charges == 0,
					"got %d" % _player.flask_charges)
				_player._set_flask_charges(99)
				_check("clamped at max, never above",
					_player.flask_charges == _player.flask_charges_max,
					"got %d" % _player.flask_charges)
				_player._set_flask_charges(0)
				_player._set_health(_player.max_health - 2)
				_health_at_press = _player.health
			if _t > 0.02 and _t < 0.14:
				Input.action_press("heal")
			if _t > 0.9:
				_check("empty flask heals nothing", _player.health == _health_at_press,
					"health %d" % _player.health)
				_check("empty flask stays at 0", _player.flask_charges == 0)
				_next()
		# C: the split. Charge out on the press, health in one drink_heal_delay
		# later, and no firing in between.
		2:
			if _t < 0.02:
				_player.rest_refill()
				_player._set_health(_player.max_health - 2)
				_player._fire_cooldown = 0.0
				_health_at_press = _player.health
				_charges_at_press = _player.flask_charges
				print("\n--- the swig ---")
			if _t > 0.02 and _t < 0.14:
				Input.action_press("heal")
			else:
				Input.action_release("heal")
			# Held from before the mid-drink sample through to after it, so the
			# refusal is tested over a window rather than on one frame.
			if _t > 0.14 and _t < 0.34:
				Input.action_press("shoot")
			else:
				Input.action_release("shoot")
			# drink_heal_delay is 0.45 from the press, so 0.30 is safely inside
			# the swig and safely before the payout.
			if _t > 0.30 and not _mid_drink_checked:
				_mid_drink_checked = true
				_check("charge spent on the press",
					_player.flask_charges == _charges_at_press - 1,
					"%d -> %d" % [_charges_at_press, _player.flask_charges])
				_check("health not yet restored", _player.health == _health_at_press,
					"health %d" % _player.health)
				_check("is_drinking() during the swig", _player.is_drinking())
			if _t > 0.36 and _t < 0.40:
				_check("shooting refused mid-swig", _bullet_count() == 0,
					"%d bullets" % _bullet_count())
			if _t > 1.10:
				_check("swig over", _player.is_drinking() == false)
				_check("health restored by flask_heal_amount",
					_player.health == _health_at_press + _player.flask_heal_amount,
					"%d -> %d" % [_health_at_press, _player.health])
				_next()
		# D: a swig worth more than the health missing. Clamped by _set_health(),
		# but a Silver Flask Cap is going to push straight at this.
		3:
			if _t < 0.02:
				_player.rest_refill()
				_player.flask_heal_amount = 4
				_player._set_health(_player.max_health - 1)
			if _t > 0.02 and _t < 0.14:
				Input.action_press("heal")
			if _t > 1.10:
				_check("oversized swig does not overheal",
					_player.health == _player.max_health,
					"health %d / %d" % [_player.health, _player.max_health])
				_player.flask_heal_amount = 1
				_next()
		# E: the saloon. Driven through the real Area2D and the real interact
		# action, with only the reload suppressed — a scene swap mid-run would
		# take this script's level out from under it.
		4:
			if _t < 0.02:
				print("\n--- the saloon ---")
				_saloon.reload_on_rest = false
				_saloon_spawn = _saloon.get_node("SpawnPoint").global_position
				_gs.clear_checkpoint()
				_player.global_position = _saloon_spawn
				_player.velocity = Vector2.ZERO
				_player._set_health(1)
				_player._set_flask_charges(0)
				_player.get_node("Camera2D").reset_smoothing()
			# A couple of physics frames for the Area2D to notice the teleported
			# body before the prompt and the press can mean anything.
			if _t > 0.10 and _t < 0.14:
				_check("saloon sees the player in range",
					_saloon._player_in_range == _player)
				_check("prompt shown while in range", _saloon._prompt.visible)
				_check("saloon starts unlit", _saloon._active == false)
				# The before half of the before/after. Whether the two states are
				# actually distinguishable is a judgement a rect assert can't
				# make, so it gets a pair of frames instead.
				if DisplayServer.get_name() != "headless":
					root.get_texture().get_image().save_png("user://flask_saloon_unrested.png")
			if _t > 0.16 and _t < 0.28:
				Input.action_press("interact")
			else:
				Input.action_release("interact")
			if _t > 0.50:
				_check("rest refilled health",
					_player.health == _player.max_health,
					"%d / %d" % [_player.health, _player.max_health])
				_check("rest refilled the flask",
					_player.flask_charges == _player.flask_charges_max,
					"%d / %d" % [_player.flask_charges, _player.flask_charges_max])
				_check("saloon recorded as active checkpoint",
					_gs.is_active_checkpoint(&"test_level_saloon"))
				_check("saloon lit after resting", _saloon._active)
				_next()
		# F: what Retry will resolve to. The fallback case is the one that must
		# keep working — it is every level that has no saloon in it.
		5:
			if _t < 0.02:
				print("\n--- respawn resolution ---")
				var fallback := Vector2(240, 1020)
				_check("respawn resolves to the checkpoint",
					_gs.get_respawn_position(fallback) == _saloon_spawn,
					"%s" % str(_gs.get_respawn_position(fallback)))
				_check("unknown checkpoint id is not active",
					_gs.is_active_checkpoint(&"nope") == false)
				_gs.clear_checkpoint()
				_check("no checkpoint falls back to the level spawn",
					_gs.get_respawn_position(fallback) == fallback,
					"%s" % str(_gs.get_respawn_position(fallback)))
				_check("a foreign level's checkpoint is not offered here",
					_gs.get_respawn_position(fallback) == fallback)
				# Put it back so the last phase's HUD readout is the rested one.
				_gs.set_checkpoint(&"test_level_saloon", _saloon_spawn)
			if _t > 0.05:
				_next()
		# G: HUD layout. Counts are covered by the phases above; what a count
		# cannot catch is the flask row landing on top of something.
		6:
			if _t < 0.02:
				print("\n--- HUD layout ---")
				# Out of range first. Phase E left the player standing inside the
				# saloon having just rested, which correctly suppresses the
				# prompt — walking away and back is what re-arms it, and it is
				# also what the captured frame below needs to show.
				_player.global_position = _saloon_spawn - Vector2(1000.0, 0.0)
				_player.velocity = Vector2.ZERO
				_player._set_health(3)
				_player._set_flask_charges(1)
			# Back into range, with a part-spent flask and a part-spent bar, so
			# one frame shows both readouts, the rested building and the prompt.
			# No interact is pressed in this phase, so standing there costs
			# nothing.
			if _t > 0.20 and _t < 0.24:
				_player.global_position = _saloon_spawn - Vector2(170.0, 0.0)
				_player.velocity = Vector2.ZERO
				_player.get_node("Camera2D").reset_smoothing()
			if _t > 0.60:
				_check("prompt re-arms on re-entry", _saloon._prompt.visible)
				var pips: Control = _hud.get_node("Health/PipRow")
				var flask: Control = _hud.get_node("Health/Flask")
				var slots: Control = _hud.get_node("Weapon/SlotRow")
				var label: Label = _hud.get_node("Health/Flask/FlaskLabel")
				print("  pips  %s" % str(pips.get_global_rect()))
				print("  flask %s" % str(flask.get_global_rect()))
				print("  slots %s" % str(slots.get_global_rect()))
				_check("flask row clear of the health pips",
					not flask.get_global_rect().intersects(pips.get_global_rect()))
				_check("flask row clear of the weapon slots",
					not flask.get_global_rect().intersects(slots.get_global_rect()))
				_check("health pips clear of the weapon slots",
					not pips.get_global_rect().intersects(slots.get_global_rect()))
				_check("charge swatch per maximum, not a hardcoded 3",
					_hud.get_node("Health/Flask/ChargeRow").get_child_count()
						== _player.flask_charges_max,
					"%d swatches" % _hud.get_node("Health/Flask/ChargeRow").get_child_count())
				_check("readout reads current / max",
					label.text == "TEQUILA %d / %d" % [
						_player.flask_charges, _player.flask_charges_max],
					'"%s"' % label.text)
				# The rect asserts are the deterministic half; this is so the
				# composition can be looked at, the same bargain
				# check_bg_coverage.gd makes. Skipped under --headless, where the
				# dummy renderer returns a null texture — that is exactly what
				# makes check_player_fx.gd noisy when it is run headless.
				if DisplayServer.get_name() != "headless":
					root.get_texture().get_image().save_png("user://flask_hud.png")
					print("  frame saved to user://flask_hud.png")
				_next()
		# H: the real reload, end to end. Everything above tests
		# `get_respawn_position()` in isolation; this one puts a fresh level in
		# the tree and asks where `Player._ready()` actually put the player —
		# which is what Retry and a saloon rest both do for real.
		7:
			if _t < 0.02:
				print("\n--- a real reload lands at the checkpoint ---")
				_gs.set_checkpoint(&"test_level_saloon", _saloon_spawn)
				# The level was added to the root by hand, so it is NOT
				# `current_scene` and `change_scene_to_file` will not free it.
				# Left in place, its player would keep answering the group query
				# and the assertion below could read the wrong one.
				_level.queue_free()
				_level = null
				_player = null
				_saloon = null
				_gs.retry_level()
			if _t > 0.40:
				var fresh: Node = root.get_tree().get_first_node_in_group("player")
				_check("a player exists after the reload", fresh != null)
				if fresh != null:
					# Compared with a tolerance, not for equality. The player is
					# a physics body that has had 0.4s of gravity and
					# move_and_slide() since it spawned, so it settles about a
					# pixel into the floor — as it does from the authored spawn
					# too. The question this asks is "the saloon, not (240,
					# 1020)", and a pixel of settling is not an answer to it.
					var drift: float = fresh.global_position.distance_to(_saloon_spawn)
					_check("reloaded player stands at the checkpoint", drift < 8.0,
						"%s vs %s, drift %.2fpx" % [
							str(fresh.global_position), str(_saloon_spawn), drift])
					_check("reloaded player is at full health",
						fresh.health == fresh.max_health)
					_check("reloaded player has a full flask",
						fresh.flask_charges == fresh.flask_charges_max)
					_check("the saloon comes back lit",
						(fresh.get_parent().get_node("Saloon"))._active)
				_next()
		8:
			_release_all()
			if _fails == 0:
				print("\nALL FLASK CHECKS OK")
				return true
			print("\n%d FAILURES" % _fails)
			quit(1)
			return true

	return false
