extends Node

## One-shot sound effects, played from a fixed pool of positional players.
##
## Why an autoload rather than an AudioStreamPlayer2D on whatever makes the
## noise: most of the things that want a sound in this game are destroyed on the
## same frame they make it. `Bullet._on_hit()` calls `queue_free()` on the line
## after the hit, and `Gunslinger._die()` frees itself immediately — a child
## player on either would be cut off before a single sample reached the speakers.
## Playing from a node that outlives the caller is the only way those events can
## be heard at all.
##
## Deliberately NOT `PROCESS_MODE_ALWAYS`, unlike the GameState autoload. That
## one owns the un-pause input and has to keep running while the tree is paused;
## everything here is a gameplay sound, and gunfire carrying on under the pause
## menu is the wrong behaviour.
##
## No audio bus layout and no volume sliders yet: sounds go to Master at
## per-stream volumes. Adding an SFX bus later is a `default_bus_layout.tres`
## plus setting `bus` on the pool below, and nothing that calls in has to change.
##
## Looping sounds are not handled here — see the player's SlideSfx node. A loop
## has to follow its owner and be stopped explicitly, and a pooled player can be
## recycled out from under it mid-loop.

## Enough voices for a shotgun blast, its impacts, footsteps and whatever an
## enemy is doing, without ever hearing the steal path below in practice.
const POOL_SIZE := 16

## The same stream started twice inside this window is played once.
##
## The shotgun is what this exists for: it fires six pellets, and six pellets
## landing on one gunslinger stack six copies of the identical impact sample into
## a clipped blast that sounds like a bug. Keyed per stream, so a footstep landing
## on the same frame as a gunshot is unaffected.
##
## The value sits between two measured numbers. Below it: a blast's pellets do
## not all land on one frame — they leave in a fan, so they cross the target over
## about three physics ticks, or 50ms. Above it: the revolver's `fire_interval`
## is 0.18s, which is the shortest gap between two shots that genuinely are two
## separate events and must both be heard. Footsteps are safe at any value here,
## because consecutive ones alternate between two different streams.
const REPEAT_WINDOW := 0.09

## Beyond this the sound is inaudible. Generous rather than tight: the camera
## leads the player by some distance, so a hit at the far edge of the screen is
## already several hundred pixels from the listener.
const MAX_DISTANCE := 2400.0

var _pool: Array[AudioStreamPlayer2D] = []
## Engine time each pool member last started, in seconds. Used to pick the
## longest-running voice when every one of them is busy.
var _started_at: PackedFloat64Array = PackedFloat64Array()
## Stream instance id -> engine time it last started, for REPEAT_WINDOW. Keyed by
## id rather than by the stream itself so this dictionary never keeps an
## otherwise-unused stream alive.
var _last_played: Dictionary = {}


func _ready() -> void:
	_started_at.resize(POOL_SIZE)
	for i in POOL_SIZE:
		# Parented to this autoload rather than to the root, for the reason
		# game_state.gd records: adding to the root from an autoload's _ready()
		# runs while the root is still assembling itself. Position is set per
		# call, so where these sit in the tree costs nothing.
		var voice := AudioStreamPlayer2D.new()
		voice.name = "Voice%02d" % i
		voice.max_distance = MAX_DISTANCE
		add_child(voice)
		_pool.append(voice)
		_started_at[i] = -1000.0


## Plays `stream` once at a world position. A null stream is silent rather than
## an error, so an unassigned `@export` slot degrades to no sound instead of
## breaking whatever fired it.
##
## `pitch` is a multiplier — pass something like `randf_range(0.94, 1.06)` for
## anything that repeats often, or footsteps read as one sample on a loop.
func play_at(stream: AudioStream, pos: Vector2, volume_db: float = 0.0,
		pitch: float = 1.0) -> void:
	if stream == null or _pool.is_empty():
		return

	var now := _now()
	var key := stream.get_instance_id()
	if _last_played.has(key) and now - float(_last_played[key]) < REPEAT_WINDOW:
		return
	_last_played[key] = now

	var voice := _take_voice(now)
	voice.stream = stream
	voice.global_position = pos
	voice.volume_db = volume_db
	voice.pitch_scale = pitch
	voice.play()


## First idle voice, or else the one that has been going longest.
##
## Stealing rather than dropping: with every voice busy, cutting the tail off the
## oldest sound is far less noticeable than a gunshot that makes no noise at all.
func _take_voice(now: float) -> AudioStreamPlayer2D:
	var oldest := 0
	for i in _pool.size():
		if not _pool[i].playing:
			_started_at[i] = now
			return _pool[i]
		if _started_at[i] < _started_at[oldest]:
			oldest = i
	_started_at[oldest] = now
	return _pool[oldest]


## Wall-clock seconds since launch. Deliberately not a `_process` accumulator:
## this node pauses with the game, and a stalled clock would make every stream
## look like a same-frame repeat on the first frame after un-pausing.
func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0
