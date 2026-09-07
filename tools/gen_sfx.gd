extends SceneTree

## Synthesises the placeholder sound effects into `assets/audio/`.
##
##   Godot_v4.7.2-stable_win64.exe --headless --path . --script res://tools/gen_sfx.gd
##
## Placeholder audio, in the same spirit as the coloured rectangles everything
## else is prototyped with: it exists so the game is audible and the wiring is
## testable today, and so that swapping in a real recording later is an inspector
## drag onto the same `AudioStream` slot rather than a code change.
##
## **Why the output is `.tres` and not `.wav`.** A `.wav` written by a script has
## no `.import` sibling, so `load("res://assets/audio/x.wav")` returns null until
## somebody has opened the editor and let the import pipeline run — which breaks
## every headless check script and a fresh clone. Saving the `AudioStreamWAV`
## resource itself sidesteps the importer entirely: it loads in the editor, under
## `--headless`, and in an export build with no extra step. Do not "simplify"
## this back to writing `.wav` files.
##
## Every generator is seeded with a constant, so re-running produces byte-identical
## files and the repo does not churn.
##
## Amplitudes are peak-normalised at the end of each recipe rather than trusted
## from the arithmetic: the filters below change gain by an order of magnitude
## depending on cutoff, so the mix is set by the `peak` argument alone. The
## numbers are a rough mix — the slide loop sits under the one-shots because it
## is sustained, and gunfire sits on top because it is the loudest thing a
## revolver does.

const RATE := 22050
const OUT_DIR := "res://assets/audio/"


func _initialize() -> void:
	print("\n--- generating placeholder sfx ---")
	_save("footstep_dirt_a", _footstep(1001, 1500.0))
	_save("footstep_dirt_b", _footstep(1002, 1150.0))
	_save("slide_dirt_loop", _slide_loop(1003), true)
	_save("revolver_shot", _gunshot(1004, 0.14, 420.0, 90.0, 6000.0, 700.0, 0.9))
	_save("shotgun_shot", _gunshot(1005, 0.30, 260.0, 50.0, 3500.0, 240.0, 1.0))
	_save("impact_flesh", _impact(1006))
	print("done\n")
	quit(0)


func _process(_delta: float) -> bool:
	return true


# --- Recipes -----------------------------------------------------------------

## Boot on dry dirt: a scuff of filtered noise over a short low thud. Two
## variants are generated with different cutoffs so alternating steps don't read
## as one sample on repeat.
func _footstep(seed_value: int, cutoff: float) -> PackedFloat32Array:
	var n := _frames(0.075)
	var scuff := _noise(n, seed_value)
	scuff = _low_pass(scuff, cutoff)
	scuff = _high_pass(scuff, 140.0)
	_apply_env(scuff, 0.003, 0.030)

	var thud := _sweep(n, 95.0, 62.0, 0.04)
	_apply_env(thud, 0.002, 0.022)

	var out := _mix([scuff, thud], [1.0, 0.5])
	_normalise(out, 0.55)
	return out


## Sustained dirt scrape for the slide. Band-passed noise with a slow amplitude
## wobble, so it reads as a body dragging rather than as tape hiss.
##
## The tail is crossfaded into the head by `_seamless()`, which is what lets
## LOOP_FORWARD run without a click at the seam — a raw noise buffer looped
## end-to-start ticks audibly once per cycle.
func _slide_loop(seed_value: int) -> PackedFloat32Array:
	var n := _frames(0.5)
	var out := _noise(n, seed_value)
	out = _low_pass(out, 3000.0)
	out = _high_pass(out, 500.0)

	for i in out.size():
		var t := float(i) / float(RATE)
		out[i] *= 0.85 + 0.15 * sin(TAU * 7.0 * t)

	out = _seamless(out, _frames(0.04))
	_normalise(out, 0.35)
	return out


## Black-powder report: a crack of bright noise riding a fast downward pitch
## sweep, with a low-passed tail underneath for the body of the blast. The
## revolver and the shotgun are the same recipe at different sizes.
func _gunshot(seed_value: int, dur: float, sweep_from: float, sweep_to: float,
		crack_lp: float, crack_hp: float, peak: float) -> PackedFloat32Array:
	var n := _frames(dur)

	var crack := _noise(n, seed_value)
	crack = _low_pass(crack, crack_lp)
	crack = _high_pass(crack, crack_hp)
	_apply_env(crack, 0.0008, dur * 0.30)

	var body := _sweep(n, sweep_from, sweep_to, dur * 0.45)
	_apply_env(body, 0.001, dur * 0.22)

	var tail := _noise(n, seed_value + 1)
	tail = _low_pass(tail, sweep_from * 2.0)
	_apply_env(tail, 0.004, dur * 0.75)

	var out := _mix([crack, body, tail], [1.0, 0.75, 0.45])
	_normalise(out, peak)
	return out


## Lead landing in a body: a bright tick so the hit registers instantly, over a
## dull low-passed thump.
func _impact(seed_value: int) -> PackedFloat32Array:
	var n := _frames(0.10)

	var tick := _noise(n, seed_value)
	tick = _high_pass(tick, 3000.0)
	_apply_env(tick, 0.0005, 0.008)

	var thump := _noise(n, seed_value + 1)
	thump = _low_pass(thump, 900.0)
	_apply_env(thump, 0.002, 0.038)

	var body := _sweep(n, 185.0, 70.0, 0.05)
	_apply_env(body, 0.001, 0.030)

	var out := _mix([tick, thump, body], [0.35, 1.0, 0.6])
	_normalise(out, 0.8)
	return out


# --- Synthesis primitives ----------------------------------------------------

func _frames(seconds: float) -> int:
	return int(seconds * RATE)


func _noise(n: int, seed_value: int) -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = rng.randf_range(-1.0, 1.0)
	return out


## Sine sweeping exponentially from `from_hz` to `to_hz` over `glide` seconds,
## then holding. Phase is accumulated per sample rather than computed from
## `sin(TAU * f * t)`, which would tear whenever the frequency moved.
func _sweep(n: int, from_hz: float, to_hz: float, glide: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	var glide_frames := maxf(float(_frames(glide)), 1.0)
	for i in n:
		var k := clampf(float(i) / glide_frames, 0.0, 1.0)
		var f: float = from_hz * pow(to_hz / from_hz, k)
		phase += TAU * f / float(RATE)
		out[i] = sin(phase)
	return out


## Linear attack into an exponential decay, applied in place. `decay` is the
## time constant, not the full length — the buffer is expected to outlast it.
func _apply_env(samples: PackedFloat32Array, attack: float, decay: float) -> void:
	var attack_frames := maxf(float(_frames(attack)), 1.0)
	var decay_frames := maxf(float(_frames(decay)), 1.0)
	for i in samples.size():
		var a := minf(float(i) / attack_frames, 1.0)
		var d: float = exp(-float(i) / decay_frames)
		samples[i] *= a * d


## One-pole low-pass. Cheap and gentle (6 dB/octave), which is all a placeholder
## needs — the point is to take the fizz off white noise, not to be a filter.
func _low_pass(samples: PackedFloat32Array, cutoff: float) -> PackedFloat32Array:
	var dt := 1.0 / float(RATE)
	var rc := 1.0 / (TAU * cutoff)
	var a := dt / (rc + dt)
	var out := PackedFloat32Array()
	out.resize(samples.size())
	var prev := 0.0
	for i in samples.size():
		prev += a * (samples[i] - prev)
		out[i] = prev
	return out


## One-pole high-pass, the mirror of the above. Chaining the two is the
## band-pass the slide loop uses.
func _high_pass(samples: PackedFloat32Array, cutoff: float) -> PackedFloat32Array:
	var dt := 1.0 / float(RATE)
	var rc := 1.0 / (TAU * cutoff)
	var a := rc / (rc + dt)
	var out := PackedFloat32Array()
	out.resize(samples.size())
	var prev_in := 0.0
	var prev_out := 0.0
	for i in samples.size():
		prev_out = a * (prev_out + samples[i] - prev_in)
		prev_in = samples[i]
		out[i] = prev_out
	return out


func _mix(layers: Array[PackedFloat32Array], gains: Array) -> PackedFloat32Array:
	var n := 0
	for layer in layers:
		n = maxi(n, layer.size())
	var out := PackedFloat32Array()
	out.resize(n)
	for li in layers.size():
		var layer := layers[li]
		var g: float = gains[li]
		for i in layer.size():
			out[i] += layer[i] * g
	return out


## Scales so the loudest sample sits exactly at `peak`. Silence is left alone
## rather than divided by zero.
func _normalise(samples: PackedFloat32Array, peak: float) -> void:
	var loudest := 0.0
	for v in samples:
		loudest = maxf(loudest, absf(v))
	if loudest <= 0.0:
		return
	var g := peak / loudest
	for i in samples.size():
		samples[i] *= g


## Crossfades the last `fade` frames into the first `fade` and drops them, so
## the end of the buffer already equals its beginning.
func _seamless(samples: PackedFloat32Array, fade: int) -> PackedFloat32Array:
	var n := samples.size()
	if fade <= 0 or fade * 2 >= n:
		return samples
	for i in fade:
		var t := float(i) / float(fade)
		samples[i] = samples[i] * t + samples[n - fade + i] * (1.0 - t)
	return samples.slice(0, n - fade)


# --- Output ------------------------------------------------------------------

func _save(name: String, samples: PackedFloat32Array, looping: bool = false) -> void:
	var n := samples.size()
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	for i in n:
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = RATE
	stream.stereo = false
	stream.data = bytes
	if looping:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_begin = 0
		stream.loop_end = n - 1

	var path := OUT_DIR + name + ".tres"
	var err := ResourceSaver.save(stream, path)
	if err != OK:
		printerr("  FAILED to write %s (error %d)" % [path, err])
		return
	print("  %-24s %5d frames  %5.0f ms%s" % [
		name, n, 1000.0 * float(n) / float(RATE), "  (loop)" if looping else ""])
