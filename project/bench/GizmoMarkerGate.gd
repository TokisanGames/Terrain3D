# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Gates DG, DH, DI, DJ, DK and DL for the BRUSH GIZMO's constant-size sprite markers, its handle
# pick order, and the selection bookkeeping behind both —
# PASTURE3D_BRUSH_EROSION_SPEC.md is not where these live; see the header of
# addons/pasture_3d/src/brush_gizmo.gd.
#
# WHAT A HEADLESS RUN CAN AND CANNOT SAY ABOUT A GIZMO. It cannot say the markers LOOK right: there is
# no viewport, the three size constants are in `fixed_size` units whose pixel mapping depends on the
# camera, and "legible against a checkered terrain" is not a number. What it CAN say is everything the
# eye is bad at anyway — that each brush class resolves to its OWN icon rather than all falling back to
# one, that the selected and unselected dots are actually different images, and that clicking where a
# hidden handle lives selects the POINT. That last one is the whole of usability tweak 3 and it is pure
# geometry, so it is measured against a real camera and a real curve rather than reasoned about.
#
# House discipline (bench/PlowReliefCheck.gd): every criterion carries a CONTROL that must fail if the
# path is dead, so a run of zeros reports "measured nothing" rather than passing.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/GizmoMarkerGate.tscn
extends Node

## The sprite machinery lives here rather than in either gizmo plugin, because BOTH draw markers with
## it and `EditorNode3DGizmoPlugin` cannot be instantiated outside the editor anyway.
const SPRITES := preload("res://addons/pasture_3d/src/gizmo_sprites.gd")
const HANDLES := preload("res://addons/pasture_3d/src/brush_handles.gd")

## How many gates below are expected to report. THE FIRST RUN OF THIS FILE PRINTED "PASS (0 failures)"
## WHILE TWO OF THREE GATES CRASHED — `EditorNode3DGizmoPlugin` cannot be instantiated outside the editor,
## so the plugin came back null and every call on it was a script error, which raises no failure count.
## A gate suite that cannot tell "nothing ran" from "everything passed" is worse than no suite, so each
## gate now increments `_completed` on its way out and the verdict checks the total. That defect is the
## reason the pick logic was moved into a plain RefCounted in the first place.
const COUNTED_GATES := 6

## Every brush family the plugin ships, with the gizmo sprite each is expected to end up with. Written
## out rather than derived, because "it resolved to something" is the failure this gate exists to catch.
##
## Pasture3DSim has no sprite of its own and must inherit Pasture3DSimBase's through the script chain —
## that fallback is the reason there is no list in the gizmo, so it is checked rather than assumed.
const EXPECTED := {
	"Pasture3DMound": "pasture3d_mound.svg",
	"Pasture3DPlow": "pasture3d_plow.svg",
	"Pasture3DRidge": "pasture3d_ridge.svg",
	"Pasture3DTrough": "pasture3d_trough.svg",
	"Pasture3DPond": "pasture3d_pond.svg",
	"Pasture3DSplat": "pasture3d_splat.svg",
	"Pasture3DSim": "pasture3d_sim_base.svg",
	"Pasture3DSimManager": "pasture3d_sim_manager.svg",
	# The water family. NOT brushes — a water body's loop belongs to the brush that carved it, so these
	# are drawn by pool_gizmo.gd instead. They are here because the sprite lookup is shared, and because
	# the first pass of this feature missed them entirely: PondWater kept its octahedron.
	"Pasture3DPool": "pasture3d_pool.svg",
	"Pasture3DStream": "pasture3d_stream.svg",
	"Pasture3DWaterBody": "pasture3d_water_body.svg",
}

var _fail := 0
var _completed := 0
var _root: Node3D
var _handles: HANDLES


func _ready() -> void:
	print("\n=== Brush gizmo markers (gates DG, DH, DI, DJ, DK, DL) ===\n")
	_root = Node3D.new()
	add_child(_root)
	# The picker, NOT the gizmo plugin: see COUNTED_GATES.
	_handles = HANDLES.new()

	_gate_dg_icons_are_per_class()
	_gate_dh_dots_differ()
	_gate_di_hidden_handle_selects_its_point()
	_gate_dj_sprites_are_grayscale()
	_gate_dk_selection_goes_inert_when_renumbered()
	_gate_dl_one_picker()

	if _completed != COUNTED_GATES:
		_fail += 1
		print("\n!! %d of %d gates reported. The rest did not FAIL, they did not RUN — read the errors "
			% [_completed, COUNTED_GATES] + "above rather than the count below.")
	print("\n=== %s (%d failures, %d/%d gates) ===\n"
		% ["GIZMO MARKER PASS" if _fail == 0 else "GIZMO MARKER FAIL", _fail, _completed, COUNTED_GATES])
	get_tree().quit(0 if _fail == 0 else 1)


# --- DG: every brush family resolves to its OWN gizmo sprite ----------------------------------------
#
# The marker is `icons/gizmo/<script file name>.svg`, found by walking the node's script inheritance
# chain. The walk is what lets a new brush family work by dropping in one file — and it is also what can
# silently make the whole feature pointless, because `pasture3d_terrain_brush.svg` exists as the base and
# EVERY subclass would fall back to it if the per-class lookup broke. "A sprite resolved" stays true.
#
# So the criterion is per class AND on the variety: eleven families must produce at least ten DISTINCT
# textures. The control is the count, not a flag.
#
# It also checks WHERE they came from. Drawing the scene-tree `@icon` instead is not a cosmetic
# difference: Godot's "detect 3D" rewrites the import settings of any texture it sees in a 3D material,
# and it did — five editor icons were converted to VRAM-compressed with mipmaps, which is a 16px glyph
# through S3TC and is the low resolution that got reported. `icons/gizmo/` is `.gdignore`d and rasterised
# at runtime so it cannot happen again, and this asserts nothing has drifted back.
func _gate_dg_icons_are_per_class() -> void:
	print("[DG] each brush family draws its own gizmo sprite:")
	var seen := {}
	var missed := PackedStringArray()
	for cls in EXPECTED:
		if not ClassDB.class_exists(cls) and not _script_class_exists(cls):
			missed.append("%s (class not found)" % cls)
			continue
		var node = ClassDB.instantiate(cls) if ClassDB.class_exists(cls) else null
		if node == null:
			node = _instantiate_script_class(cls)
		if node == null:
			missed.append("%s (could not instantiate)" % cls)
			continue
		# NOT added to the tree: `sprite_for` reads the node's script and nothing else, and a water body
		# entering the tree starts building surface meshes this gate has no use for.
		var tex: Texture2D = SPRITES.sprite_for(node)
		var got := tex.resource_name.get_file() if tex != null else "<none>"
		var want: String = EXPECTED[cls]
		if got != want:
			missed.append("%s -> %s (wanted %s)" % [cls, got, want])
		if tex != null:
			seen[tex.resource_name] = true
			if not tex.resource_name.begins_with(SPRITES.SPRITE_DIR):
				missed.append("%s came from %s, outside the gizmo sprite directory"
						% [cls, tex.resource_name])
		node.free()
	print("    %d families, %d distinct icons" % [EXPECTED.size(), seen.size()])
	if not missed.is_empty():
		_fail += 1
		print("    !! wrong or missing: %s" % ", ".join(missed))
	# THE CONTROL. All eight resolving to one texture is exactly what a broken per-class lookup looks
	# like, and every assertion above would still pass if `EXPECTED` had been written from that run.
	if seen.size() < 10:
		_fail += 1
		print("    !! only %d distinct sprites across %d families — the lookup is collapsing to the base "
			% [seen.size(), EXPECTED.size()]
			+ "class's sprite, so the marker says 'a brush' and not which one")
	_completed += 1


# --- DH: the selected and unselected dots are different images --------------------------------------
#
# "The sprite changes when a point or handle is selected" is the claim, and the two textures are
# generated rather than authored, so nothing outside this gate ever looks at them. Measured where the
# difference is supposed to be — the CENTRE, hollow against filled — and on the rim, which must survive
# being tinted or the marker vanishes against pale ground.
func _gate_dh_dots_differ() -> void:
	print("\n[DH] the selected dot is a different image from the unselected one:")
	var hollow: ImageTexture = SPRITES._dot(false)
	var filled: ImageTexture = SPRITES._dot(true)
	if hollow == null or filled == null:
		_fail += 1
		print("    !! a dot texture was not generated at all")
		_completed += 1
		return
	var hi := hollow.get_image()
	var fi := filled.get_image()
	var mid := Vector2i(hi.get_width() / 2, hi.get_height() / 2)
	var h_centre := hi.get_pixelv(mid)
	var f_centre := fi.get_pixelv(mid)
	# The rim: one pixel inside the outer edge, on the horizontal through the centre.
	var edge := Vector2i(hi.get_width() - 3, mid.y)
	var h_rim := hi.get_pixelv(edge)
	print("    hollow centre alpha %.2f, filled centre alpha %.2f" % [h_centre.a, f_centre.a])
	print("    rim luminance %.2f at the outer edge (must be dark to read on pale ground)" % h_rim.r)
	if h_centre.a > 0.05:
		_fail += 1
		print("    !! the unselected dot is not hollow, so the two states look the same")
	if f_centre.a < 0.95:
		_fail += 1
		print("    !! the selected dot is not filled")
	if h_rim.a < 0.5 or h_rim.r > 0.35:
		_fail += 1
		print("    !! the outer rim is not an opaque dark outline, so a tinted dot has nothing to "
			+ "separate it from the terrain behind it")
	# CONTROL: the body must be WHITE somewhere, or the material's tint has nothing to act on and every
	# dot comes out black — point and handle indistinguishable.
	var body := fi.get_pixelv(Vector2i(mid.x, mid.y))
	print("    CONTROL filled body luminance %.2f (tinted by the material, so it must be near white)"
			% body.r)
	if body.r < 0.9:
		_fail += 1
		print("    !! the dot body is not white, so cyan points and orange handles both draw dark")
	_completed += 1


# --- DI: clicking where a HIDDEN handle lives selects the point, not the handle ----------------------
#
# Usability tweak 3. A loop point's tangents are drawn only while that point is selected, but they were
# still PICKED whether drawn or not — and a zero-length tangent is shown at a three-metre stub from its
# point, so aiming at a point and landing a few pixels off it grabbed an invisible handle. It looked
# like the point had been selected, because the tangents appear either way, right up until the drag bent
# the curve.
#
# THE FIXTURE AIMS AT THE HANDLE ON PURPOSE. The click is placed exactly on the out-tangent's screen
# position, which is the worst case and the one the old code got wrong. Two clicks:
#
#   1st — tangents hidden — must return the POINT (id % 3 == 0), and reveal the handles.
#   2nd — tangents now shown — must return the HANDLE, because the user can now see what they are
#         aiming at and asked for it deliberately.
#
# The second click is the control, and it is the important one: a fix that simply stopped tangents being
# pickable at all would pass the first assertion perfectly and make the handles unusable.
func _gate_di_hidden_handle_selects_its_point() -> void:
	print("\n[DI] clicking a hidden handle selects its point (usability 3):")
	var brush := Pasture3DMound.new()
	brush.name = "PickFixture"
	_root.add_child(brush)
	var path := Path3D.new()
	var c := Curve3D.new()
	# A square loop with straight points, so every tangent is zero-length and drawn at its stub — which
	# is the configuration a freshly placed brush is in, and the one the complaint came from.
	for p in [Vector3(-40, 0, -40), Vector3(40, 0, -40), Vector3(40, 0, 40), Vector3(-40, 0, 40)]:
		c.add_point(p)
	c.closed = true
	path.curve = c
	brush.add_child(path)

	# CLOSE, and aimed at the point under test rather than at the loop centre. From a comfortable
	# framing of the whole loop the three-metre tangent stub projects to about 9 px, which is INSIDE the
	# 13 px pick radius — the first click would then land on the point whatever the code did, and the
	# gate would be reporting the camera. The third control below is what caught that.
	var focus := Vector3(-40, 0, -40)
	var cam := Camera3D.new()
	_root.add_child(cam)
	cam.global_position = focus + Vector3(0, 25, 25)
	cam.look_at(focus, Vector3.UP)
	cam.current = true
	# The viewport has to have a size for unproject_position to mean anything.
	get_viewport().size = Vector2i(1280, 720)

	_handles.clear_point_selection()
	_handles.sel_node_id = 0
	# Point 0's OUT tangent, at the stub where it would be drawn.
	var target: Vector3 = brush.to_global(_handles.handle_display_local(brush, path, 0, 2))
	var point: Vector3 = brush.to_global(_handles.handle_display_local(brush, path, 0, 0))
	if cam.is_position_behind(target):
		_fail += 1
		print("    !! the fixture is behind the camera; nothing was measured")
		_completed += 1
		return
	var at := cam.unproject_position(target)
	var sep := at.distance_to(cam.unproject_position(point))
	print("    the hidden handle sits %.1f px from its point (pick radius %.0f px)"
			% [sep, HANDLES.PICK_RADIUS])

	var first: int = _handles.pick_handle(brush, cam, at)
	print("    1st click, aimed at the handle: id %d -> point %d, kind %d"
			% [first, first / 3 if first >= 0 else -1, first % 3 if first >= 0 else -1])
	if first < 0:
		_fail += 1
		print("    !! the click hit nothing at all")
	elif first % 3 != 0:
		_fail += 1
		print("    !! it took the handle. A point that is not selected has no visible handles, so this "
			+ "is a grab on something that is not on screen")

	# CONTROL. The handles are now shown, so the same click must take one — otherwise the fix has simply
	# made tangents unpickable and the curve cannot be shaped at all.
	var second: int = _handles.pick_handle(brush, cam, at)
	print("    CONTROL 2nd click, handles now visible: id %d -> point %d, kind %d"
			% [second, second / 3 if second >= 0 else -1, second % 3 if second >= 0 else -1])
	if second % 3 == 0 or second < 0:
		_fail += 1
		print("    !! the handle is unreachable now, which trades one frustration for a worse one")

	# CONTROL 2. The separation must be REAL. If the stub happened to project on top of its own point,
	# the first click would return the point for the wrong reason and prove nothing.
	if sep < HANDLES.PICK_RADIUS:
		_fail += 1
		print("    !! the handle projects within the pick radius of its own point, so the first click "
			+ "would have taken the point whatever the code did")
	_completed += 1


# ---- [DK] / [DL] the selection index and the second picker (BRUSH_GIZMO_INPUT_SPEC P2/P3) ----------

## A brush with one open spline of `p_n` points and a camera framing it. Shared by DK and DL, which both
## need real screen projections rather than reasoning about them.
func _pick_fixture(p_n: int) -> Array:
	var brush := Pasture3DRidge.new()
	_root.add_child(brush)
	var path := Path3D.new()
	var c := Curve3D.new()
	for i in p_n:
		c.add_point(Vector3(float(i) * 20.0 - 60.0, 0.0, 0.0))
	path.curve = c
	brush.add_child(path)
	var cam := Camera3D.new()
	_root.add_child(cam)
	cam.global_position = Vector3(0, 90, 90)
	cam.look_at(Vector3.ZERO, Vector3.UP)
	cam.current = true
	get_viewport().size = Vector2i(1280, 720)
	return [brush, path, cam]


## P2. `sel_gpi` is a RUNNING index across a brush's splines, so adding or removing a point renumbers it.
## The Delete key reads `selected_point()`, so a stale index does not merely mislead — it removes the
## WRONG POINT. The selection therefore records the point count it was taken at and goes inert on any
## mismatch, which covers add, remove, undo of either, and an inspector edit; patching the two call
## sites (which is what shipped before) covered only one of those, and not even all of it.
func _gate_dk_selection_goes_inert_when_renumbered() -> void:
	print("
[DK] a renumbered point selection goes inert, not wrong:")
	var fx := _pick_fixture(7)
	var brush: Node3D = fx[0]
	var path: Path3D = fx[1]
	_handles.clear_point_selection()
	_handles.sel_node_id = 0

	# Select point 4 the way a click does, and confirm it resolves — without this the rest is vacuous.
	_handles._update_selected_point(brush, 4, 0)
	var sel: Array = _handles.selected_point(brush)
	if sel[1] != 4:
		_fail += 1
		print("    !! the fixture never selected point 4 (got %d); nothing below is measured" % sel[1])
		_completed += 1
		return
	print("    selected point %d of %d" % [sel[1], path.curve.point_count])

	# A removal BEFORE the selection: the classic wrong-point deletion.
	path.curve.remove_point(1)
	var after: Array = _handles.selected_point(brush)
	if after[0] != null:
		_fail += 1
		print("    !! still resolves to point %d after a removal before it — Delete would take the "
			% after[1] + "wrong point")
	else:
		print("    a removal before the selection makes it inert")

	# CONTROL. A removal AFTER the selection must invalidate too. `sel_gpi` still happens to name the
	# right point there, so a design that merely fixed up the index would pass the line above and fail
	# here — and this gate is what says the count, not the position, is the rule.
	var fx2 := _pick_fixture(7)
	var brush2: Node3D = fx2[0]
	var path2: Path3D = fx2[1]
	_handles.clear_point_selection()
	_handles._update_selected_point(brush2, 2, 0)
	path2.curve.remove_point(6)
	var after2: Array = _handles.selected_point(brush2)
	if after2[0] != null:
		_fail += 1
		print("    !! CONTROL: a removal after the selection left it live (point %d)" % after2[1])
	else:
		print("    CONTROL: a removal after the selection is inert too — the rule is the count")

	# CONTROL 2. A TANGENT edit changes no count, so the selection must SURVIVE it. Without this the
	# whole gate passes on a `selection_valid` that simply always answers false.
	var fx3 := _pick_fixture(7)
	var brush3: Node3D = fx3[0]
	var path3: Path3D = fx3[1]
	_handles.clear_point_selection()
	_handles._update_selected_point(brush3, 3, 0)
	path3.curve.set_point_in(3, Vector3(0, 0, -8))
	var after3: Array = _handles.selected_point(brush3)
	if after3[1] != 3:
		_fail += 1
		print("    !! CONTROL: a tangent edit cleared the selection (got %d); inert-always is not a fix"
			% after3[1])
	else:
		print("    CONTROL: a tangent edit leaves the selection alone")
	_completed += 1


## P3. There used to be TWO pickers: the gizmo's (13 px, tangent-aware) decided what a click SELECTED,
## and `Pasture3DTerrainBrush.pick_point_screen` (14 px, positions only) decided what the double-click
## and right-click paths ACTED ON. They disagree, so a click could select one handle and act on another,
## and a double-click on a visible tangent toggled the point underneath it instead.
##
## What is gated is the property, not the deletion: the handle acted on is the handle selected.
func _gate_dl_one_picker() -> void:
	print("
[DL] the handle a click acts on is the handle it selected:")
	var fx := _pick_fixture(7)
	var brush: Node3D = fx[0]
	var path: Path3D = fx[1]
	var cam: Camera3D = fx[2]

	# THE DIVERGENCE ONLY EXISTS WHERE A TANGENT IS VISIBLE. With every point straight and nothing
	# selected, the hidden-handle collapse resolves every hit to its POSITION — which is exactly what the
	# retired positions-only picker answered, so the two agree and the gate would measure nothing. The
	# reported bug was a double-click on a SHOWN handle, so the fixture gives the points real tangents
	# and turns the show-all toggle on.
	for i in path.curve.point_count:
		path.curve.set_point_in(i, Vector3(0.0, 0.0, -7.0))
		path.curve.set_point_out(i, Vector3(0.0, 0.0, 7.0))
	var was_show_all: bool = Pasture3DTerrainBrush._show_all_tangents
	Pasture3DTerrainBrush._show_all_tangents = true

	# Sample a grid across the spline's screen span rather than random points, so a failure is
	# reproducible and the count is not luck.
	var samples: Array[Vector2] = []
	for gx in range(-6, 7):
		for gy in range(-3, 4):
			var world := Vector3(float(gx) * 10.0, 0.0, float(gy) * 4.0)
			if not cam.is_position_behind(world):
				samples.append(cam.unproject_position(world))

	var hits := 0
	var disagree_new := 0
	var disagree_old := 0
	var impure := 0
	for at in samples:
		_handles.clear_point_selection()
		_handles.sel_node_id = 0
		# PURE first: it must not move the selection it is asked about.
		var before_gpi: int = _handles.sel_gpi
		var acted: Array = _handles.pick_handle_at(brush, cam, at)
		if _handles.sel_gpi != before_gpi:
			impure += 1
		# Then the selecting call, from the same state.
		var selected: int = _handles.pick_handle(brush, cam, at)
		if selected < 0:
			continue
		hits += 1
		var acted_id: int = -1
		if acted[0] != null:
			var base := _handles.resolve_handle(brush, selected)
			acted_id = selected if (acted[0] == base[0] and acted[1] == base[1]
					and acted[2] == base[2]) else -2
		if acted_id != selected:
			disagree_new += 1
		# THE CONTROL: the retired picker, on the same click.
		var old_pick: Array = brush.pick_point_screen(cam, at, 14.0)
		var base2 := _handles.resolve_handle(brush, selected)
		if old_pick[0] != base2[0] or old_pick[1] != base2[1]:
			disagree_old += 1

	Pasture3DTerrainBrush._show_all_tangents = was_show_all
	print("    %d sample clicks, %d landed on a handle" % [samples.size(), hits])
	if hits < 10:
		_fail += 1
		print("    !! too few clicks landed on anything; the camera, not the pickers, was measured")
	if disagree_new != 0:
		_fail += 1
		print("    !! %d clicks selected one handle and acted on another" % disagree_new)
	else:
		print("    every click acts on what it selected")
	if impure != 0:
		_fail += 1
		print("    !! pick_handle_at moved the selection on %d clicks; the query is not pure" % impure)
	else:
		print("    pick_handle_at wrote nothing down")
	# The control must FAIL to agree, or the two pickers never diverged on this fixture and [DL] is
	# reporting a tautology.
	if disagree_old == 0:
		_fail += 1
		print("    !! CONTROL: the retired 14 px picker agreed everywhere, so nothing was reproduced")
	else:
		print("    CONTROL: the retired 14 px picker disagreed on %d of %d clicks — the divergence was real"
			% [disagree_old, hits])
	_completed += 1


# ---- helpers ---------------------------------------------------------------------------------------

## The plugin's brushes are GDScript classes, not ClassDB entries, so they are looked up by global name.
func _script_class_exists(p_class: String) -> bool:
	for e in ProjectSettings.get_global_class_list():
		if String(e.get("class", "")) == p_class:
			return true
	return false


func _instantiate_script_class(p_class: String) -> Node:
	for e in ProjectSettings.get_global_class_list():
		if String(e.get("class", "")) != p_class:
			continue
		var scr: Script = load(String(e.get("path", "")))
		return scr.new() if scr != null else null
	return null


# --- DJ: the sprites are grayscale, and carry both ends of the ramp ----------------------------------
#
# The marker's colour is the BRUSH'S (`_gizmo_color`) and the material applies it as a multiply, so a
# sprite with any colour of its own would come out doubly tinted — a red glyph under the erosion
# family's dark blue is near black. Grayscale is therefore a requirement and not a style note.
#
# TWO ENDS, and a sprite needs both. The WHITE body is what the tint acts on, and is what separates the
# marker from a dark hillside. The BLACK outline survives the multiply unchanged, and is what separates
# it from pale terrain. A sprite that is all white vanishes against the sky; one that is all outline
# cannot be told from any other family's.
#
# THE CONTROL IS AN OLD EDITOR ICON. `brush_mound.svg` is the coloured 16px scene-tree icon the gizmo
# used to draw, and it must FAIL the saturation test — without it "every sprite is grayscale" would also
# be true of a test that could not measure saturation at all.
func _gate_dj_sprites_are_grayscale() -> void:
	print("\n[DJ] the gizmo sprites are grayscale, with both a white body and a black outline:")
	var worst_sat := -1.0
	var worst_name := ""
	var min_white := 1.0
	var min_black := 1.0
	var thin := PackedStringArray()
	var files := _sprite_files()
	for path in files:
		var img := _load_svg(path)
		if img == null:
			_fail += 1
			print("    !! %s did not rasterise" % path)
			continue
		var stat := _ink(img)
		if float(stat["sat"]) > worst_sat:
			worst_sat = float(stat["sat"])
			worst_name = path.get_file()
		min_white = minf(min_white, float(stat["white"]))
		min_black = minf(min_black, float(stat["black"]))
		if float(stat["white"]) < 0.02 or float(stat["black"]) < 0.02:
			thin.append("%s (white %.3f, black %.3f)"
					% [path.get_file(), stat["white"], stat["black"]])
	print("    %d sprites, worst saturation %.4f (%s)" % [files.size(), worst_sat, worst_name])
	print("    thinnest body %.3f of frame, thinnest outline %.3f (both must clear 0.020)"
			% [min_white, min_black])
	if files.size() < 11:
		_fail += 1
		print("    !! only %d sprites found; the directory is not the one being drawn from" % files.size())
	if worst_sat > 0.02:
		_fail += 1
		print("    !! %s carries colour of its own, which the brush's tint will multiply into "
			% worst_name + "something nobody chose")
	if not thin.is_empty():
		_fail += 1
		print("    !! missing one end of the ramp: %s" % ", ".join(thin))

	# THE CONTROL. The coloured editor icon the gizmo used to draw must fail the same test.
	var old := _load_svg("res://addons/pasture_3d/icons/brush_mound.svg")
	var old_sat := float(_ink(old)["sat"]) if old != null else -1.0
	print("    CONTROL the old coloured editor icon measures %.4f saturation" % old_sat)
	if old_sat <= 0.02:
		_fail += 1
		print("    !! the control passed the grayscale test, so the test does not measure colour and "
			+ "the assertions above are about nothing")
	_completed += 1


## Every sprite in the gizmo directory. Listed from disk rather than from EXPECTED, so a file added
## without a class behind it is still held to the rules.
func _sprite_files() -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(SPRITES.SPRITE_DIR)
	if dir == null:
		return out
	for f in dir.get_files():
		if f.get_extension() == "svg":
			out.append(SPRITES.SPRITE_DIR + f)
	out.sort()
	return out


func _load_svg(p_path: String) -> Image:
	if not FileAccess.file_exists(p_path):
		return null
	var img := Image.new()
	return img if img.load_svg_from_string(FileAccess.get_file_as_string(p_path), 1.0) == OK else null


## `{sat, white, black}` over the OPAQUE pixels: peak saturation, and the fraction of the image that is
## near-white body and near-black outline. Transparent pixels are skipped — most of a glyph is nothing,
## and averaging that in would make every sprite look identical.
func _ink(p_img: Image) -> Dictionary:
	if p_img == null:
		return {"sat": 0.0, "white": 0.0, "black": 0.0}
	var sat := 0.0
	var white := 0
	var black := 0
	var opaque := 0
	for y in p_img.get_height():
		for x in p_img.get_width():
			var c := p_img.get_pixel(x, y)
			if c.a < 0.5:
				continue
			opaque += 1
			sat = maxf(sat, maxf(c.r, maxf(c.g, c.b)) - minf(c.r, minf(c.g, c.b)))
			if c.r > 0.9 and c.g > 0.9 and c.b > 0.9:
				white += 1
			elif c.r < 0.2 and c.g < 0.2 and c.b < 0.2:
				black += 1
	var n := float(maxi(p_img.get_width() * p_img.get_height(), 1))
	return {"sat": sat, "white": float(white) / n, "black": float(black) / n, "opaque": opaque}
