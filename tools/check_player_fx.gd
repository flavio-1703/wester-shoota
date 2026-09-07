extends SceneTree

## Player effects regression check.
##
##   Godot_v4.7.2-stable_win64.exe --path . --script res://tools/check_player_fx.gd
##
## Two things, neither of which a screenshot can settle:
##
##   1. The code-drawn muzzle flash appears for EXACTLY the poses whose art has
##      no flash painted in. That gate is UNPAINTED_FLASH_CLIPS in player.gd — a
##      hand-maintained list mirroring what the artist has and hasn't drawn. Add
##      a `run_shoot` strip to the sheet without updating it and the shot flashes
##      twice; rename a clip and it stops flashing at all. Nothing else catches
##      either. Sheet 3 did exactly that — it added run_shoot and jump_shoot and
##      dropped the crouched firing pose — so the expectations below inverted:
##      running and airborne fire is now painted, crouched fire is not.
##   2. The run does not skate: world travel per animation cycle matches the
##      distance the drawn feet carry the body (2 * run_stride).
##   3. Squash and stretch move the sprite and the MUZZLE DOES NOT. Bullets spawn
##      at Visuals/Muzzle, whose offsets are measured off the painted flashes, so
##      a squash applied one node too high would silently walk the spawn point.
##
## It drives the real player with faked input, so the clip choice comes out of
## the real code path. Three things about that were learned the hard way:
##
##   - Everything runs in _physics_process. Input faked from _process lands on
##     the wrong frame-kind and is_action_just_pressed() never sees it.
##   - Input.action_press() makes is_action_pressed() true one physics frame
##     BEFORE is_action_just_pressed(). Jump survives that because it has a
##     buffer; the slide does not — the player sees crouch held without an edge,
##     takes the plain-crouch branch, and the match then dispatches to
##     State.CROUCH where no slide can start. A real keyboard sets both flags on
##     the same frame, so that is an emulation artifact rather than a bug, and
##     the slide phase calls _start_slide() directly instead.
##   - Phases are time-based and the flash is observed over a window rather than
##     sampled on one frame. It lives 0.07s, so a frame-counted probe checks
##     before the shot has even fired and reads a false pass.

const ACTIONS := ["move_right", "move_left", "jump", "shoot", "crouch"]

var _level: Node
var _player: Node
var _visuals: Node2D

var _phase := 0
var _t := 0.0
var _saw_flash := false
var _clips: Dictionary = {}
var _fails := 0

## True from the moment a phase is reset until the player is standing on the
## ground again.
##
## _next() teleports to a fixed point rather than to the floor's exact height,
## so the player opens every phase in a short fall. That ruins the phases that
## need a stance: a slide started in the air is cancelled by _update_stance on
## the very next frame, and a jump is refused for want of coyote time. Holding
## the phase clock at zero until the drop lands makes every phase start from the
## same conditions whatever the level's ground is doing under x=1900.
var _settling := true
var _settle_time := 0.0


func _initialize() -> void:
	_level = load("res://scenes/levels/test_level.tscn").instantiate()
	root.add_child(_level)


func _release_all() -> void:
	for a in ACTIONS:
		Input.action_release(a)


## Screenshots are a debugging aid, not an assertion — and they need a real
## renderer. Under `--headless` the viewport has no texture, and an unguarded
## save_png() there throws *after* the verdict but *before* _next(), so the phase
## never advances and the run hangs on it forever. Guarded, the checks themselves
## run either way and only the pictures are lost.
func _capture(name: String) -> void:
	var texture := root.get_texture()
	if texture == null:
		return
	var image := texture.get_image()
	if image != null:
		image.save_png("user://%s.png" % name)


var _saved_flash := false
var _peak_stretch := 0.0
var _peak_squash := 0.0
var _air_sx := 0.0
var _air_sy := 0.0
var _cad_x := 0.0
var _cad_adv := 0
var _cad_last := -1


func _observe() -> void:
	for c in _visuals.get_children():
		if c.name.begins_with("MuzzleFlash"):
			_saw_flash = true
			# Grab the frame the flash is actually on screen — it lives 0.07s,
			# so a capture at a fixed time usually misses it entirely.
			if not _saved_flash:
				_saved_flash = true
				_capture("fx_flash")
	var clip: StringName = _player._sprite.animation
	_clips[clip] = true


func _verdict(label: String, want_flash: bool, want_clips: Array) -> void:
	var clips := _clips.keys()
	var clip_ok := false
	for c in clips:
		if c in want_clips:
			clip_ok = true
	var ok := _saw_flash == want_flash and clip_ok
	if not ok:
		_fails += 1
	print("  %-10s clips=%-26s flash=%-5s want=%-5s %s" % [
		label, str(clips), str(_saw_flash), str(want_flash),
		"OK" if ok else "*** FAIL (clip_ok=%s)" % clip_ok])


## Each phase restarts from the same clear stretch of ground. Two reasons it has
## to be this exact spot: without a reset the phases inherit each other's
## position and the player runs into the tunnel roof at x=750 (110px of
## clearance), stalling so velocity.x never reaches slide_min_speed and the
## crouch tap becomes a plain crouch; and the jump apex has to clear LedgeLow's
## underside at x 998..1334, or the squash phase measures a bonk instead of a
## landing.
##
## It is deliberately NOT the floor's exact height. Levels get re-authored and
## the ground under x=1900 has already moved once, which dropped the player 40px
## into the air at the top of every phase — see `_settling`.
func _next() -> void:
	_phase += 1
	_t = 0.0
	_saw_flash = false
	_clips = {}
	_settling = true
	_release_all()
	if _player != null:
		_player.global_position = Vector2(1900, 1020)
		_player.velocity = Vector2.ZERO


func _physics_process(delta: float) -> bool:
	if _player == null:
		_player = _level.get_tree().get_first_node_in_group("player")
		if _player == null:
			return false
		_visuals = _player.get_node("Visuals")
		print("\n--- muzzle flash gate ---")
		_release_all()

	if _settling:
		if _player.is_on_floor():
			_settling = false
			_settle_time = 0.0
		else:
			# No faked input while falling, and no clock either — the phase has
			# not started yet.
			_t = 0.0
			_settle_time += delta
			if _settle_time > 3.0:
				print("  *** FAIL: player never landed after the phase reset."
					+ " Is (1900, 1020) still over solid ground?")
				_fails += 1
				quit(1)
				return true
			return false

	_t += delta

	match _phase:
		# A: standing still and firing. Clip is `shoot`, which has a painted
		# flash, so the code one must stay away.
		0:
			Input.action_press("shoot")
			if _t > 0.20:
				_observe()
			if _t > 0.50:
				_verdict("standing", false, [&"shoot"])
				_next()
		# B: running and firing. Clip is `run_shoot`, which sheet 3 paints a
		# flash into, so the code one must stay away.
		1:
			Input.action_press("move_right")
			if _t > 0.35:
				Input.action_press("shoot")
			if _t > 0.50:
				_observe()
			if _t > 0.85:
				_verdict("running", false, [&"run_shoot"])
				_capture("fx_run_shoot")
				_next()
		# C: airborne and firing. `jump_shoot`, also painted in sheet 3.
		2:
			Input.action_press("move_right")
			if _t < 0.02:
				Input.action_press("jump")
			else:
				Input.action_release("jump")
			if _t > 0.12:
				Input.action_press("shoot")
			if _t > 0.16:
				_observe()
			if _t > 0.34:
				_verdict("airborne", false, [&"jump_shoot"])
				_next()
		# D: sliding and firing. The slide poses draw no gun at all, so the
		# flash is deliberately suppressed there.
		3:
			# The slide is entered directly rather than through faked input.
			# Input.action_press() makes is_action_pressed() true one physics
			# frame BEFORE is_action_just_pressed(), so the player sees crouch
			# held-without-an-edge first, takes the plain-crouch branch, and the
			# match then dispatches to State.CROUCH where no slide can start. A
			# real keyboard sets both on the same frame. That skew is an input
			# emulation artifact, and this probe is about the flash gate, so it
			# puts the player in the state and tests what it came to test.
			if _t < 0.02:
				_player.velocity.x = _player.run_speed
				_player._start_slide()
			if _t > 0.05:
				Input.action_press("shoot")
			if _t > 0.08:
				_observe()
			if _t > 0.30:
				_verdict("sliding", false, [&"slide"])
				_capture("fx_slide")
				_next()
		# E: crouched and firing. The one pose left that the art does NOT paint
		# a flash into — sheet 3 dropped the crouched firing pose sheet 2 had —
		# so this is the only stance the code-drawn flash still covers.
		#
		# From a standstill the crouch press cannot become a slide (velocity is
		# nowhere near slide_min_speed), so unlike phase D this one can be driven
		# through real input.
		4:
			Input.action_press("crouch")
			if _t > 0.05:
				Input.action_press("shoot")
			if _t > 0.08:
				_observe()
			if _t > 0.30:
				_verdict("crouching", true, [&"crouch", &"crouch_walk"])
				_capture("fx_crouch_shoot")
				_next()
		# F: squash and stretch. A still frame cannot show these, so they are
		# read off the sprite's actual scale as the player jumps and lands.
		5:
			if _t < 0.02:
				Input.action_press("jump")
			else:
				Input.action_release("jump")
			if _t > 0.10 and _t < 0.30:
				_peak_stretch = maxf(_peak_stretch, _player._stretch)
				_air_sx = _player._sprite.scale.x
				_air_sy = _player._sprite.scale.y
			if _player.is_on_floor() and _t > 0.35:
				_peak_squash = minf(_peak_squash, _player._stretch)
			if _t > 1.30:
				print("\n--- squash and stretch ---")
				print("  airborne  stretch=%+.3f  sprite scale=(%.3f, %.3f)" % [
					_peak_stretch, _air_sx, _air_sy])
				print("  landing   squash =%+.3f" % _peak_squash)
				if _peak_stretch <= 0.0:
					print("  *** FAIL: never stretched in the air")
					_fails += 1
				if _peak_squash >= 0.0:
					print("  *** FAIL: never squashed on landing")
					_fails += 1
				if _air_sy <= _air_sx:
					print("  *** FAIL: airborne pose is not taller than it is wide")
					_fails += 1
				# The muzzle must not move with the squash: bullets spawn there,
				# and the MUZZLE offsets are measured off the painted flashes.
				# It IS placed per firing pose by _place_muzzle(), and standing
				# still on the ground that pose is `shoot` — so MUZZLE_STAND is
				# still the right expectation here, and anything else means the
				# squash reached a node it should not have.
				var muzzle_local: Vector2 = _player.get_node("Visuals/Muzzle").position
				if muzzle_local != _player.MUZZLE_STAND:
					print("  *** FAIL: muzzle moved to %s, expected %s" % [
						str(muzzle_local), str(_player.MUZZLE_STAND)])
					_fails += 1
				else:
					print("  muzzle    %s unmoved by the squash" % str(muzzle_local))
				_next()
		# G: does the run skate? Count animation-frame advances against world
		# travel. The clip is a full cycle of two steps, so one cycle should
		# carry the body 2 * run_stride. `run_stride` is measured off the sheet
		# by hand, so new run art silently desyncs it — this is what catches that.
		6:
			# Shielded from enemy fire: a knockback mid-window would corrupt the
			# travel measurement. The i-frame blink is irrelevant here, nothing
			# is captured in this phase.
			_player._invuln_timer = 5.0
			# Its own start point. The shared one at x=1900 gives the jump phase
			# the headroom it needs, but running right from there hits LedgeFar
			# (x 2412..2748, collision top 860) — the player's collision top is
			# 850, so it blocks — and a stalled run measures as a skate. From
			# x=1000 the ledges overhead all clear a standing player.
			if _t < 0.02:
				_player.global_position = Vector2(1000, 1020)
			Input.action_press("move_right")
			if _t < 0.35:
				_cad_x = _player.global_position.x
				_cad_adv = 0
				_cad_last = -1
			else:
				var idx: int = _player._sprite.frame
				if _cad_last >= 0 and idx != _cad_last:
					_cad_adv += 1
				_cad_last = idx
			if _t > 1.75:
				var count: float = _player._sprite.sprite_frames.get_frame_count(&"run")
				var cycles: float = _cad_adv / count
				var per_cycle: float = (_player.global_position.x - _cad_x) \
					/ maxf(cycles, 0.001)
				var feet: float = 2.0 * _player.run_stride
				var ratio: float = per_cycle / feet
				print("\n--- run cadence ---")
				print("  world %.0f px/cycle vs feet %.0f px/cycle -> ratio %.2f" % [
					per_cycle, feet, ratio])
				if absf(ratio - 1.0) > 0.12:
					print("  *** FAIL: the run skates. Re-measure run_stride, or")
					print("      retune it until this reads 1.00.")
					_fails += 1
				else:
					print("  feet stay planted")
				_next()
		7:
			_release_all()
			if _fails == 0:
				print("\nALL FX CHECKS OK")
				return true
			print("\n%d FAILURES" % _fails)
			quit(1)
			return true

	return false
