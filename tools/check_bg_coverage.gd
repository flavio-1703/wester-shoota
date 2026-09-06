extends SceneTree

## Does every parallax layer still cover the frame?
##
##   Godot_v4.7.2-stable_win64.exe --path . --script res://tools/check_bg_coverage.gd
##   Godot_v4.7.2-stable_win64.exe --path . --script res://tools/check_bg_coverage.gd --resolution 2560x1080
##
## Exits non-zero and prints the shortfall in pixels if a layer has run out of
## width. Also writes a PNG per camera position to user:// so the composition
## can be looked at, not just measured.
##
## This exists for the same reason slice_player_sheet.py prints the muzzle
## constants on every run: the per-layer widths in desert_bg.tscn are hand-copied
## numbers derived from CameraBounds, lookahead_distance and max_offset, and
## nothing stops a later edit to any of those from silently invalidating them.
## Re-run this after moving a CameraBounds rect or retuning the camera.
##
## Why it is not just arithmetic: Camera2D applies `offset` AFTER its limits, so
## look-ahead and shake both push the view outside CameraBounds. Measuring the
## real visible world rect catches that; deriving it from the bounds does not,
## and did not — see the Backgrounds section of the README.

const LEVEL := "res://scenes/levels/test_level.tscn"

## Camera positions to test: both ends of the level and the top of the climb.
const SHOTS := [
	{"name": "left", "pos": Vector2(240, 1020), "look": -1.0},
	{"name": "right", "pos": Vector2(3800, 1020), "look": 1.0},
	{"name": "high", "pos": Vector2(3600, 340), "look": 1.0},
]

## Frames spent letting look-ahead slide to full extension before measuring.
## It moves at lookahead_speed across a 2 * lookahead_distance swing.
const SETTLE_FRAMES := 150

## Frames sampled with trauma pinned at maximum. Shake is noise-driven, so one
## sample under-reads it; the worst shortfall across the window is what counts.
const SHAKE_FRAMES := 40

## Layers that only owe horizontal coverage — translucent garnish drawn over
## something that already covers. Everything else must also reach the bottom of
## the frame, and the sky must reach the top as well.
const OVERLAY_LAYERS := ["Clouds", "ForegroundDust"]

var _level: Node
var _player: Node2D
var _cam: Camera2D
var _shot := 0
var _frame := 0
var _worst: Dictionary = {}
var _failures := 0


func _initialize() -> void:
	_level = load(LEVEL).instantiate()
	root.add_child(_level)


func _process(_delta: float) -> bool:
	if _player == null:
		_player = _level.get_tree().get_first_node_in_group("player")
		if _player == null:
			return false
		_cam = _player.get_node("Camera2D")
		# Smoothing would make every sample a race against the tween.
		_cam.position_smoothing_enabled = false
		_cam.drag_vertical_enabled = false

	_frame += 1
	var setup: Dictionary = SHOTS[_shot]

	if _frame == 1:
		_player.global_position = setup["pos"]
		_player.velocity = Vector2.ZERO
		_cam.set_look_direction(setup["look"])
		_worst = {}
		return false

	if _frame < SETTLE_FRAMES:
		return false

	if _frame == SETTLE_FRAMES:
		_save_png(setup)

	# Trauma decays at `decay` per second, so it is topped up every frame to
	# hold the camera at peak shake while the noise moves underneath it.
	_cam.add_trauma(1.0)
	_sample()

	if _frame < SETTLE_FRAMES + SHAKE_FRAMES:
		return false

	_report(setup)

	_shot += 1
	_frame = 0
	if _shot < SHOTS.size():
		return false

	if _failures == 0:
		print("\nALL LAYERS COVER")
		return true

	print("\n%d FAILURES — widen the layers named above" % _failures)
	quit(1)
	return true


## The world-space quad the player can actually see, offset and roll included.
## All four corners, because under camera roll two of them do not bound it.
func _visible_rect() -> Rect2:
	var vp := root.get_viewport()
	var size: Vector2 = vp.get_visible_rect().size
	var to_world := vp.get_canvas_transform().affine_inverse()

	var out := Rect2(to_world * Vector2.ZERO, Vector2.ZERO)
	out = out.expand(to_world * Vector2(size.x, 0.0))
	out = out.expand(to_world * Vector2(0.0, size.y))
	out = out.expand(to_world * size)
	return out


func _sample() -> void:
	var visible := _visible_rect()

	for layer in _level.find_children("*", "Parallax2D", true, false):
		var covered := _covered_rect(layer)

		# Signed margin: how many pixels of layer sit beyond the frame edge.
		# Negative is a gap. Reporting the margin rather than a bare pass/fail
		# is the point — it shows how much headroom the hand-copied widths in
		# desert_bg.tscn actually have before an edge slides into view.
		var margin := Vector4(
			visible.position.x - covered.position.x,
			covered.end.x - visible.end.x,
			visible.position.y - covered.position.y,
			covered.end.y - visible.end.y
		)

		if not _worst.has(layer.name):
			_worst[layer.name] = margin
			continue

		var prev: Vector4 = _worst[layer.name]
		_worst[layer.name] = Vector4(
			minf(prev.x, margin.x), minf(prev.y, margin.y),
			minf(prev.z, margin.z), minf(prev.w, margin.w)
		)


func _report(setup: Dictionary) -> void:
	var size: Vector2 = root.get_viewport().get_visible_rect().size
	print("\n=== %s @ %dx%d (worst of %d shake frames) ===" % [
		setup["name"], int(size.x), int(size.y), SHAKE_FRAMES,
	])

	for name in _worst:
		var margin: Vector4 = _worst[name]
		var ok := margin.x >= 0.0 and margin.y >= 0.0
		if not OVERLAY_LAYERS.has(name):
			ok = ok and margin.w >= 0.0
			if name == "Sky":
				ok = ok and margin.z >= 0.0

		if not ok:
			_failures += 1
		print("  %-16s %s  margin px  L %5.0f  R %5.0f  B %5.0f" % [
			name, "PASS" if ok else "FAIL", margin.x, margin.y, margin.w,
		])


## Union of the layer's children in world space. A tiling layer covers its whole
## repeat axis, so that axis is treated as unbounded.
func _covered_rect(layer: Parallax2D) -> Rect2:
	var out := Rect2()
	var first := true

	for child in layer.get_children():
		# Control.get_rect() is already in the parent's space, so it takes the
		# layer transform. Sprite2D.get_rect() is in the sprite's OWN space and
		# has to go through the sprite's global transform instead — passing it
		# the layer transform silently drops the sprite's position.
		var world: Rect2
		if child is Control:
			var xf := layer.get_global_transform()
			var r: Rect2 = (child as Control).get_rect()
			world = Rect2(xf * r.position, Vector2.ZERO).expand(xf * r.end)
		elif child is Sprite2D:
			var xf2 := (child as Sprite2D).get_global_transform()
			var r2: Rect2 = (child as Sprite2D).get_rect()
			world = Rect2(xf2 * r2.position, Vector2.ZERO).expand(xf2 * r2.end)
		else:
			continue

		if first:
			out = world
			first = false
		else:
			out = out.merge(world)

	if first:
		return Rect2()

	if layer.repeat_size.x > 0.0:
		out.position.x -= 1.0e7
		out.size.x += 2.0e7
	if layer.repeat_size.y > 0.0:
		out.position.y -= 1.0e7
		out.size.y += 2.0e7
	return out


func _save_png(setup: Dictionary) -> void:
	var size: Vector2 = root.get_viewport().get_visible_rect().size
	var path := "user://bg_%s_%dx%d.png" % [setup["name"], int(size.x), int(size.y)]

	# These frames are for judging the background; the perf readout covers a
	# quarter of it. Hidden for the capture only, then put back.
	var overlay: Node = root.get_node_or_null("DebugOverlay")
	var was_visible := false
	if overlay is CanvasLayer:
		was_visible = (overlay as CanvasLayer).visible
		(overlay as CanvasLayer).visible = false
		await process_frame
		await process_frame

	root.get_texture().get_image().save_png(path)

	if overlay is CanvasLayer:
		(overlay as CanvasLayer).visible = was_visible
	print("\n%s -> %s" % [setup["name"], ProjectSettings.globalize_path(path)])
