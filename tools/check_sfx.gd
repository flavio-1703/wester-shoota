extends SceneTree

## Sound effect regression check.
##
##   Godot_v4.7.2-stable_win64.exe --headless --path . --script res://tools/check_sfx.gd
##
## Structured like `check_flask.gd` and `check_player_fx.gd`, and for the same
## reason: it drives the real player through the real level with faked input, so
## the gates and the timing come out of the production code path. The notes at
## the top of check_player_fx.gd about input emulation apply here too — most
## importantly that everything runs in `_physics_process`, so input faked from
## `_process` never produces a `just_pressed` edge.
##
## Sound is verifiable headless despite the Dummy audio driver: `playing` still
## tracks the stream's lifetime, it just goes nowhere. What that costs is
## precision at the tail — the dummy mixer holds a voice ~0.15s past the end of
## the sample — so every count below is a MAXIMUM taken over a window rather than
## a reading off one frame.
##
## What it covers, and why each one is worth a test rather than a read-through:
##
##   1. The Sfx autoload really has its pool of voices, and every generated
##      stream loads with data in it. `tools/gen_sfx.gd` writes those files; a
##      half-written or unregenerated one fails silently everywhere else.
##   2. One trigger pull is one report. The fire sound sits outside the pellet
##      loop in _handle_shoot(), and moving it in is a one-line mistake that
##      turns the shotgun into six overlapping blasts.
##   3. **Six pellets landing on one gunslinger make ONE impact, not six.** This
##      is the whole reason Sfx.REPEAT_WINDOW exists. Corroborated by the target
##      actually losing health, so the assert cannot pass because nothing hit.
##   4. **Jumping out of a slide stops the scrape loop.** _stand_up_to_jump()
##      cancels a slide without going through _end_slide(), so a loop bracketed
##      on that pair hisses forever afterwards. This is why the start/stop lives
##      in _set_state(), and this is the test that keeps it there.
##   5. A slide left to run out also stops it — the ordinary path, which must not
##      regress while the exotic one is being guarded.
##   6. Footsteps fire while running on the ground and are silent while standing
##      still and while airborne. Driving them off the run clip's contact frames
##      rather than a timer is what keeps them on the boots.
##   7. The pool does not leak. play_at() must recycle its voices; creating one
##      per sound would grow the autoload without bound over a play session.
##   8. Pausing silences everything. Sfx deliberately does not copy GameState's
##      PROCESS_MODE_ALWAYS, and an absence is exactly the kind of decision a
##      later edit undoes without noticing.
##   9. The enemies' bullets carry NO impact sound. Sharing the player's would
##      have the dedupe swallow one side's hit to pay for the other's.

const ACTIONS := ["shoot", "move_right", "move_left", "jump", "crouch", "heal", "interact"]

## Flat ground with clear headroom, used by every phase that needs the player to
## run or slide. The ground's surface in test_level is y=958.
##
## Not the level's opening spawn, and this is worth spelling out: the tunnel roof
## sits across x 550..950 at standing height, so a run started near the spawn
## stops dead against it after about 130px. The stretch from x=950 to the first
## gunslinger is the one with nothing overhead — LedgeLow and LedgeHigh both
## clear a standing player's head.
const CLEAR_GROUND := Vector2(1000.0, 958.0)

## A column with no platform under it, for the airborne footstep check. The
## stretch between LedgeHigh (which ends at x=1656) and LedgeFar (which begins at
## x=2615) is open all the way down, and the run input stays held through the
## drop — so the fall has to be somewhere the player can also travel sideways
## without catching a ledge on the way.
const CLEAR_AIR := Vector2(1750.0, 558.0)

const STREAM_PATHS := [
	"res://assets/audio/footstep_dirt_a.tres",
	"res://assets/audio/footstep_dirt_b.tres",
	"res://assets/audio/slide_dirt_loop.tres",
	"res://assets/audio/revolver_shot.tres",
	"res://assets/audio/shotgun_shot.tres",
	"res://assets/audio/impact_flesh.tres",
]

var _level: Node
var _player: Node
var _target: Node
## The Sfx autoload, reached through the root rather than by its global name. A
## `--script` SceneTree is compiled before the autoloads are registered, so `Sfx`
## is not a resolvable identifier in this file even though the singleton is very
## much alive by the time _physics_process runs — the same wrinkle check_flask.gd
## records for GameState.
var _sfx: Node

var _pool_size: int = 0
var _revolver_shot: AudioStream
var _shotgun_shot: AudioStream
var _impact: AudioStream

var _phase := 0
var _t := 0.0
var _fails := 0
var _started := false

## Peak simultaneous voices seen this phase, per stream. Sampled every frame
## because the interesting number — six impacts at once — exists for only a
## couple of frames and a single probe would miss it.
var _peak: Dictionary = {}
## Carried across the frames of a phase.
var _target_health_before: int = 0
var _steps_before: int = 0
var _seen: Dictionary = {}


func _initialize() -> void:
	_level = load("res://scenes/levels/test_level.tscn").instantiate()
	root.add_child(_level)


func _release_all() -> void:
	for a in ACTIONS:
		Input.action_release(a)


## Silences everything and clears the dedupe table, so a phase's counts are its
## own. Without the clear, a phase firing the same stream as the one before it
## inside REPEAT_WINDOW would measure zero and look like a pass.
func _reset_audio() -> void:
	for voice in _sfx.get_children():
		voice.stop()
	_player._slide_sfx.stop()
	_sfx._last_played.clear()
	_peak.clear()


func _next() -> void:
	_phase += 1
	_t = 0.0
	_seen.clear()
	_release_all()
	_reset_audio()


func _check(label: String, ok: bool, detail: String = "") -> void:
	if _seen.has(label):
		return
	_seen[label] = true
	if not ok:
		_fails += 1
	print("  %-46s %-9s %s" % [label, "OK" if ok else "*** FAIL", detail])


## How many pool voices are currently sounding `stream`.
func _voices(stream: AudioStream) -> int:
	var n := 0
	for voice in _sfx.get_children():
		if voice.playing and voice.stream == stream:
			n += 1
	return n


func _sample_peak() -> void:
	for stream: AudioStream in [_revolver_shot, _shotgun_shot, _impact]:
		var id := stream.get_instance_id()
		_peak[id] = maxi(int(_peak.get(id, 0)), _voices(stream))


func _peak_of(stream: AudioStream) -> int:
	return int(_peak.get(stream.get_instance_id(), 0))


## The `impact_sound` a projectile scene ships with, without spawning one.
func _scene_impact(path: String) -> AudioStream:
	var probe: Node = load(path).instantiate()
	var stream: AudioStream = probe.impact_sound
	probe.free()
	return stream


func _physics_process(delta: float) -> bool:
	if not _started:
		_player = _level.get_tree().get_first_node_in_group("player")
		if _player == null:
			return false
		_started = true
		_sfx = root.get_node("Sfx")
		_pool_size = _sfx.get_child_count()
		_revolver_shot = load("res://assets/audio/revolver_shot.tres")
		_shotgun_shot = load("res://assets/audio/shotgun_shot.tres")
		_impact = load("res://assets/audio/impact_flesh.tres")

		# Every gunslinger is blinded and rooted for the whole run, so the target
		# is exactly where the level put it when phase C teleports the player a
		# measured distance in front of it.
		#
		# Done with the exported knobs rather than PROCESS_MODE_DISABLED, which
		# would also pull their collision shapes out of the physics space and leave
		# phase C firing a shotgun at nothing.
		for enemy in _level.get_tree().get_nodes_in_group("enemies"):
			enemy.sight_range = 0.0
			enemy.patrol_speed = 0.0
			enemy.velocity = Vector2.ZERO
		_target = _level.get_node("Gunslinger")
		_release_all()
		print("\n--- the pool and the streams ---")

	_t += delta
	_sample_peak()

	match _phase:
		# A: everything is loaded and wired before any of it is fired.
		0:
			if _t < 0.02:
				_check("Sfx autoload is in the tree", _sfx != null)
				_check("pool of positional voices exists", _pool_size > 0,
					"%d voices" % _pool_size)
				var all_2d := true
				for voice in _sfx.get_children():
					if not (voice is AudioStreamPlayer2D):
						all_2d = false
				_check("every voice is an AudioStreamPlayer2D", all_2d)
				_check("nothing is playing at rest", _voices(_revolver_shot) == 0)

				for path: String in STREAM_PATHS:
					var wav := load(path) as AudioStreamWAV
					_check("%s loads with audio in it" % path.get_file().get_basename(),
						wav != null and not wav.data.is_empty(),
						"%d bytes" % (wav.data.size() if wav != null else 0))
				var loop: AudioStreamWAV = load("res://assets/audio/slide_dirt_loop.tres")
				_check("the slide scrape is marked as looping",
					loop.loop_mode == AudioStreamWAV.LOOP_FORWARD)

				_check("the player carries footstep sounds",
					_player.footstep_sounds.size() >= 2,
					"%d" % _player.footstep_sounds.size())
				_check("the player has a slide loop node",
					_player._slide_sfx != null and _player._slide_sfx.stream != null)
				_check("the revolver has a fire sound",
					_player.weapons[0].fire_sound != null)
				_check("the shotgun has a fire sound",
					_player.weapons[1].fire_sound != null)
				# The player's projectiles carry the impact sound; the enemies'
				# deliberately do not. Giving them the same stream would let one of
				# their bullets reaching the player swallow the sound of your own
				# shot landing, and vice versa — play_at() dedupes per stream. See
				# the note on `impact_sound` in bullet.gd.
				_check("player rounds carry an impact sound",
					_scene_impact("res://scenes/projectiles/bullet.tscn") != null
						and _scene_impact("res://scenes/projectiles/pellet.tscn") != null)
				_check("enemy rounds share no impact sound with them",
					_scene_impact("res://scenes/projectiles/enemy_bullet.tscn") == null)
			if _t > 0.05:
				_next()
				print("\n--- one trigger pull, one report ---")
		# B: the revolver. Baseline for phase C: a weapon that fires one
		# projectile had better make exactly one noise.
		1:
			if _t < 0.02:
				_player.global_position = CLEAR_GROUND
				_player.velocity = Vector2.ZERO
				_player._set_weapon(0)
				_player._fire_cooldown = 0.0
				_player.get_node("Camera2D").reset_smoothing()
			if _t > 0.05 and _t < 0.09:
				Input.action_press("shoot")
			else:
				Input.action_release("shoot")
			if _t > 0.30:
				_check("one revolver shot plays one report",
					_peak_of(_revolver_shot) == 1,
					"peak %d voices" % _peak_of(_revolver_shot))
				_next()
				print("\n--- a shotgun blast into a gunslinger ---")
		# C: the dedupe. Six pellets, one target, one impact sound.
		2:
			if _t < 0.02:
				# Well within the pellet's 490px range (1400px/s for 0.35s), and
				# close enough that the 26-degree fan stays inside the target: over
				# ~110px of travel it opens to about +/-25px, against a body that is
				# 160px tall. Survives the blast so all six pellets land on
				# something alive rather than passing through a corpse.
				_target.health = 99
				_player.global_position = _target.global_position - Vector2(140.0, 0.0)
				_player.velocity = Vector2.ZERO
				_player.facing = 1
				_player._set_weapon(1)
				_player._fire_cooldown = 0.0
				_player._invuln_timer = 999.0
				_player.get_node("Camera2D").reset_smoothing()
				_target_health_before = _target.health
			if _t > 0.05 and _t < 0.09:
				Input.action_press("shoot")
			else:
				Input.action_release("shoot")
			if _t > 0.45:
				var landed: int = _target_health_before - _target.health
				# The corroboration. Without it, "one impact" would also be the
				# reading from a blast that missed entirely.
				_check("several pellets actually landed", landed >= 2,
					"%d damage" % landed)
				_check("six pellets make ONE impact, not six",
					_peak_of(_impact) == 1,
					"peak %d voices" % _peak_of(_impact))
				_check("the blast itself is one report",
					_peak_of(_shotgun_shot) == 1,
					"peak %d voices" % _peak_of(_shotgun_shot))
				_target.health = _target.max_health
				_next()
				print("\n--- the slide scrape ---")
		# D: the regression the _set_state() hook exists for. Jumping out of a
		# slide never touches _end_slide(), so a loop bracketed on the
		# _start_slide/_end_slide pair would still be hissing at the end of this.
		3:
			if _t < 0.02:
				_player.global_position = CLEAR_GROUND
				_player.velocity = Vector2.ZERO
				_player._slide_cooldown_timer = 0.0
				_player.get_node("Camera2D").reset_smoothing()
			# A third of a second of running first, so the body is genuinely up to
			# speed and settled on the floor before the slide starts.
			if _t > 0.05 and _t < 0.60:
				Input.action_press("move_right")
			else:
				Input.action_release("move_right")
			# Called directly rather than by faking a crouch press, for the reason
			# check_player_fx.gd records at the top of that file: Input.action_press()
			# makes is_action_pressed() true one physics frame BEFORE
			# is_action_just_pressed(), so an emulated crouch is seen held but
			# without an edge and _update_stance() takes the plain-crouch branch. A
			# real keyboard sets both on the same frame. What is under test here is
			# _set_state(), and this reaches it by the production path.
			if _t > 0.40 and _t < 0.42:
				_player._start_slide()
			if _t > 0.48 and _t < 0.54:
				_check("sliding starts the scrape loop", _player._slide_sfx.playing,
					"state %d" % _player.state)
			# Well inside slide_duration, so this really is a cancel and not the
			# slide quietly expiring on its own.
			if _t > 0.56 and _t < 0.60:
				Input.action_press("jump")
			else:
				Input.action_release("jump")
			if _t > 0.66:
				_check("jumping out of a slide left the state",
					_player.state != _player.State.SLIDE,
					"state %d" % _player.state)
				_check("jumping out of a slide stops the scrape loop",
					not _player._slide_sfx.playing)
				_next()
				print("\n--- a slide left to run out ---")
		# E: the ordinary path, so guarding the exotic one above cannot quietly
		# break it.
		4:
			if _t < 0.02:
				_player.global_position = CLEAR_GROUND
				_player.velocity = Vector2.ZERO
				_player._slide_cooldown_timer = 0.0
				_player.get_node("Camera2D").reset_smoothing()
			if _t > 0.05 and _t < 0.40:
				Input.action_press("move_right")
			else:
				Input.action_release("move_right")
			# Direct, for the same emulation reason as the phase above.
			if _t > 0.40 and _t < 0.42:
				_player._start_slide()
			if _t > 0.48 and _t < 0.54:
				_check("the scrape loop is running mid-slide",
					_player._slide_sfx.playing, "state %d" % _player.state)
			# Comfortably past slide_duration plus the stand-up. No jump anywhere
			# in this phase — the slide has to expire on its own.
			if _t > 0.44 + _player.slide_duration + 0.25:
				_check("the slide ran out on its own",
					_player.state != _player.State.SLIDE,
					"state %d" % _player.state)
				_check("running out of slide stops the scrape loop",
					not _player._slide_sfx.playing)
				_next()
				print("\n--- footsteps ---")
		# F: footsteps, counted off the player's own step counter rather than off
		# voices — a footstep is 75ms long and two of them can be over before any
		# single frame looks at the pool.
		5:
			if _t < 0.02:
				_player.global_position = CLEAR_GROUND
				_player.velocity = Vector2.ZERO
				_player.get_node("Camera2D").reset_smoothing()
				_steps_before = _player._footstep_index
			# Both windows of this phase in ONE statement: run, then the same input
			# held through the drop. Two separate press/release blocks for the same
			# action would have the second one's `else` releasing what the first one
			# just pressed, every frame, and the player never moves at all.
			if (_t > 0.05 and _t < 0.95) or (_t > 1.44 and _t < 1.70):
				Input.action_press("move_right")
			else:
				Input.action_release("move_right")
			if _t > 0.95 and _t < 0.99:
				# ~500px of run against a 142px stride is around three and a half
				# steps, so anything below two means they are not firing at all.
				_check("running on the ground makes footsteps",
					_player._footstep_index - _steps_before >= 2,
					"%d steps" % (_player._footstep_index - _steps_before))
				_steps_before = _player._footstep_index
			if _t > 1.40 and _t < 1.44:
				_check("standing still makes none",
					_player._footstep_index == _steps_before,
					"%d extra" % (_player._footstep_index - _steps_before))
				# Dropped from a height with the run input still held, and sampled
				# well before it can land: the clip is not `run` up there, and a
				# footstep in mid-air is exactly what a timer-driven version gives
				# you.
				_player.global_position = CLEAR_AIR
				_player.velocity = Vector2.ZERO
				_player.get_node("Camera2D").reset_smoothing()
				_steps_before = _player._footstep_index
			if _t > 1.70:
				_check("airborne makes none",
					_player._footstep_index == _steps_before,
					"%d extra" % (_player._footstep_index - _steps_before))
				_check("the drop really was airborne", not _player.is_on_floor())
				_next()
				print("\n--- the pool recycles ---")
		# G: no leak. play_at() must reuse its voices; one player per sound would
		# grow this node for as long as the game runs.
		6:
			if _t < 0.02:
				_player.global_position = CLEAR_GROUND
				_player.velocity = Vector2.ZERO
				_player.get_node("Camera2D").reset_smoothing()
			if _t < 0.60:
				# Straight at the API, 50 times over, rather than through 50
				# trigger pulls: what is being measured is the pool, not the gun.
				for i in 10:
					_sfx._last_played.clear()
					_sfx.play_at(_revolver_shot, _player.global_position)
			if _t > 0.60:
				_check("the pool did not grow",
					_sfx.get_child_count() == _pool_size,
					"%d voices, started with %d" % [_sfx.get_child_count(), _pool_size])
				_check("voices are still usable after the storm",
					_voices(_revolver_shot) > 0)
				_next()
				print("\n--- pausing silences it ---")
		# H: Sfx deliberately does NOT copy GameState's PROCESS_MODE_ALWAYS, so
		# gameplay sound stops with the game. Worth an assert rather than a
		# read-through: it is an absence — nobody setting a process mode — and the
		# next person to add one line to sfx.gd's _ready() could undo it without
		# noticing, leaving a slide hissing under the pause menu.
		7:
			if _t < 0.02:
				_player.global_position = CLEAR_GROUND
				_player.velocity = Vector2(_player.run_speed, 0.0)
				_player._slide_cooldown_timer = 0.0
				_player.get_node("Camera2D").reset_smoothing()
			if _t > 0.05 and _t < 0.07:
				_player._start_slide()
				_sfx.play_at(_revolver_shot, _player.global_position)
			if _t > 0.10 and _t < 0.14:
				_check("something is sounding before the pause",
					_player._slide_sfx.playing and _voices(_revolver_shot) > 0)
				root.get_tree().paused = true
			if _t > 0.20:
				_check("pausing stops the slide loop",
					not _player._slide_sfx.playing)
				_check("pausing stops the one-shot pool",
					_voices(_revolver_shot) == 0)
				root.get_tree().paused = false
				_next()
		8:
			_release_all()
			# The level was added to the root by hand, so nothing else will ever
			# take it down; dropping it here keeps the exit quiet instead of
			# reporting the whole scene as leaked objects.
			_level.free()
			_level = null
			_player = null
			_target = null
			if _fails == 0:
				print("\nALL SFX CHECKS OK")
				return true
			print("\n%d FAILURES" % _fails)
			quit(1)
			return true

	return false
