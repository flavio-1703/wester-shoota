extends CanvasLayer

## Autoloaded performance readout pinned to the top-right corner. F3 toggles it.
##
## "Latency" here means frame latency, not network latency: the game is
## single-player, so the delay you actually feel is how long a frame takes to
## come back. That gets reported three ways — this frame, the average over the
## sample window, and the worst frames in it — because an average on its own
## hides hitches, and a hitch in a run-and-gun reads as input lag even when the
## average looks healthy. Audio output latency is the one other real latency in
## the build, so it sits in the same block.
##
## Two structural choices, both taken from PauseMenu: `process_mode` is ALWAYS
## so the numbers keep moving while the tree is paused (a readout frozen at
## whatever the pause keypress happened to catch is worse than no readout), and
## `layer` sits above the pause overlay so this is never covered by it.
##
## Unlike PauseMenu, what gets toggled here is the CanvasLayer's own `visible`
## rather than an inner Control. That file avoids this because hiding a
## CanvasLayer doesn't feed into `Control.is_visible_in_tree()`, so its buttons
## would keep focus and keep answering input while apparently hidden. Nothing
## in here is focusable or takes input, so the flag only has to stop the layer
## drawing and the simple version is enough.
##
## No `class_name`, unlike PauseMenu: this is registered as the `DebugOverlay`
## autoload, and a global class sharing a singleton's name is a project-load
## error. Nothing needs the type statically anyway — the singleton *is* the
## reference.

## Frame times kept for the average/worst/1%-low line. At 60 FPS that's ~8.5
## seconds of history — long enough that a hitch stays on screen for a refresh
## or two instead of vanishing before you can read it.
const SAMPLE_COUNT := 512

## The text is rebuilt on this interval rather than every frame. Twenty-odd
## monitor reads and a string build per frame would show up in the very process
## time this exists to measure.
const REFRESH_INTERVAL := 0.25

## Not a project input action on purpose. The input map holds player-facing,
## rebindable gameplay actions; a debug toggle is neither, and keeping it out
## means it can't collide with a future remapping screen.
const TOGGLE_KEY := KEY_F3

const BYTES_PER_MIB := 1048576.0

## Ring buffer of the last SAMPLE_COUNT frame deltas, in seconds. Entries
## 0.._samples_filled are valid, which holds both while it's filling and once
## it wraps, because writes start at 0 and advance one at a time.
var _frame_times := PackedFloat32Array()
var _write_index := 0
var _samples_filled := 0
var _refresh_timer := 0.0

@onready var _readout: Label = %Readout


func _ready() -> void:
	_frame_times.resize(SAMPLE_COUNT)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.is_pressed() and not event.is_echo()):
		return
	if (event as InputEventKey).keycode != TOGGLE_KEY:
		return

	visible = not visible
	# Zeroed so switching it on repaints immediately rather than showing up to a
	# refresh interval of stale numbers — or the placeholder text, first time.
	_refresh_timer = 0.0
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	# Sampling continues while hidden, so the window is already warm — and the
	# hitch you just felt is already in it — the moment the overlay is toggled on.
	_frame_times[_write_index] = delta
	_write_index = (_write_index + 1) % SAMPLE_COUNT
	_samples_filled = mini(_samples_filled + 1, SAMPLE_COUNT)

	if not visible:
		return

	_refresh_timer -= delta
	if _refresh_timer > 0.0:
		return
	_refresh_timer = REFRESH_INTERVAL
	_readout.text = _build_readout(delta)


func _build_readout(delta: float) -> String:
	var sorted := _sorted_samples()
	var lines := PackedStringArray()

	lines.append("FPS %4d          %7.2f ms" % [
		Engine.get_frames_per_second(), delta * 1000.0,
	])
	lines.append("avg  %7.2f ms  worst %7.2f ms" % [
		_average(sorted) * 1000.0, _worst(sorted) * 1000.0,
	])
	# The 99th-percentile frame time, expressed as the framerate it corresponds
	# to: the conventional "1% low", and the number that moves when the game
	# stutters while the headline FPS barely twitches.
	var one_percent_low := _percentile(sorted, 0.99)
	lines.append("1%% low %4d fps  (%7.2f ms)" % [
		roundi(1.0 / maxf(one_percent_low, 0.0001)), one_percent_low * 1000.0,
	])

	lines.append("")
	lines.append("process   %6.2f ms" % [
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
	])
	# Reported next to the tick rate because everything that moves in this game
	# is driven from _physics_process — this is the budget that matters, and the
	# budget is 1000 / ticks ms.
	lines.append("physics   %6.2f ms  @ %d Hz" % [
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		Engine.physics_ticks_per_second,
	])
	# Seconds, like the other two time monitors — it's AudioServer.get_output_latency()
	# behind the constant, not a millisecond figure.
	lines.append("audio out %6.2f ms" % [
		Performance.get_monitor(Performance.AUDIO_OUTPUT_LATENCY) * 1000.0,
	])

	lines.append("")
	lines.append("draw calls %5d  drawn %5d" % [
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
	])
	lines.append("video mem  %7.1f MiB" % [_mib(Performance.RENDER_VIDEO_MEM_USED)])
	lines.append("static mem %7.1f MiB" % [_mib(Performance.MEMORY_STATIC)])

	lines.append("")
	lines.append("nodes %5d  orphans %4d" % [
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
	])
	lines.append("objects %5d  resources %5d" % [
		Performance.get_monitor(Performance.OBJECT_COUNT),
		Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
	])
	# Bullets and enemies are physics bodies, so these two climb together with
	# how much is on screen — the pair count is the one that gets expensive.
	lines.append("2D bodies %4d  pairs %5d" % [
		Performance.get_monitor(Performance.PHYSICS_2D_ACTIVE_OBJECTS),
		Performance.get_monitor(Performance.PHYSICS_2D_COLLISION_PAIRS),
	])

	return "\n".join(lines)


## Sorted copy of the live window. Sorting a few hundred floats four times a
## second is cheaper than keeping the window ordered on insert, and it leaves
## the ring buffer as a plain overwrite.
func _sorted_samples() -> PackedFloat32Array:
	var window := _frame_times.slice(0, _samples_filled)
	window.sort()
	return window


func _average(sorted: PackedFloat32Array) -> float:
	if sorted.is_empty():
		return 0.0
	var total := 0.0
	for sample in sorted:
		total += sample
	return total / sorted.size()


func _worst(sorted: PackedFloat32Array) -> float:
	return 0.0 if sorted.is_empty() else sorted[sorted.size() - 1]


func _percentile(sorted: PackedFloat32Array, fraction: float) -> float:
	if sorted.is_empty():
		return 0.0
	var index := mini(int(sorted.size() * fraction), sorted.size() - 1)
	return sorted[index]


func _mib(monitor: int) -> float:
	return Performance.get_monitor(monitor) / BYTES_PER_MIB
