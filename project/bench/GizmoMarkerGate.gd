# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Gates DG, DH and DI for the BRUSH GIZMO's constant-size sprite markers and its handle pick order —
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

const GIZMO := preload("res://addons/pasture_3d/src/brush_gizmo.gd")
const HANDLES := preload("res://addons/pasture_3d/src/brush_handles.gd")

## How many gates below are expected to report. THE FIRST RUN OF THIS FILE PRINTED "PASS (0 failures)"
## WHILE TWO OF THREE GATES CRASHED — `EditorNode3DGizmoPlugin` cannot be instantiated outside the editor,
## so the plugin came back null and every call on it was a script error, which raises no failure count.
## A gate suite that cannot tell "nothing ran" from "everything passed" is worse than no suite, so each
## gate now increments `_completed` on its way out and the verdict checks the total. That defect is the
## reason the pick logic was moved into a plain RefCounted in the first place.
const COUNTED_GATES := 3

## Every brush family the plugin ships, with the icon each is expected to end up with. Written out
## rather than derived, because "it resolved to something" is the failure this gate exists to catch.
const EXPECTED := {
	"Pasture3DMound": "brush_mound.svg",
	"Pasture3DPlow": "brush_plow.svg",
	"Pasture3DRidge": "brush_ridge.svg",
	"Pasture3DTrough": "brush_trough.svg",
	"Pasture3DPond": "brush_mound.svg",
	"Pasture3DSim": "brush_sim.svg",
	"Pasture3DSplat": "brush_splat.svg",
	"Pasture3DStream": "brush_terrain.svg",
}

var _fail := 0
var _completed := 0
var _root: Node3D
var _handles: HANDLES


func _ready() -> void:
	print("\n=== Brush gizmo markers (gates DG, DH, DI) ===\n")
	_root = Node3D.new()
	add_child(_root)
	# The picker, NOT the gizmo plugin: see COUNTED_GATES.
	_handles = HANDLES.new()

	_gate_dg_icons_are_per_class()
	_gate_dh_dots_differ()
	_gate_di_hidden_handle_selects_its_point()

	if _completed != COUNTED_GATES:
		_fail += 1
		print("\n!! %d of %d gates reported. The rest did not FAIL, they did not RUN — read the errors "
			% [_completed, COUNTED_GATES] + "above rather than the count below.")
	print("\n=== %s (%d failures, %d/%d gates) ===\n"
		% ["GIZMO MARKER PASS" if _fail == 0 else "GIZMO MARKER FAIL", _fail, _completed, COUNTED_GATES])
	get_tree().quit(0 if _fail == 0 else 1)


# --- DG: every brush family resolves to its OWN scene-tree icon -------------------------------------
#
# The origin marker is the node's `@icon`, read out of the project's global class list and walked up the
# `base` chain until a class declares one. The walk is what makes a new brush family work without a list
# in the gizmo — and it is also the thing that can silently make this feature pointless, because
# `Pasture3DTerrainBrush` declares `brush_terrain.svg` and EVERY subclass would fall back to it if the
# per-class lookup were broken. "The icon resolved" would still be true.
#
# So the criterion is per class AND on the variety: eight families must produce at least six DISTINCT
# textures. The control is the count, not a flag.
func _gate_dg_icons_are_per_class() -> void:
	print("[DG] each brush family draws its own scene-tree icon:")
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
		_root.add_child(node)
		var tex: Texture2D = GIZMO.icon_for(node)
		var got := tex.resource_path.get_file() if tex != null else "<none>"
		var want: String = EXPECTED[cls]
		if got != want:
			missed.append("%s -> %s (wanted %s)" % [cls, got, want])
		if tex != null:
			seen[tex.resource_path] = true
		node.queue_free()
	print("    %d families, %d distinct icons" % [EXPECTED.size(), seen.size()])
	if not missed.is_empty():
		_fail += 1
		print("    !! wrong or missing: %s" % ", ".join(missed))
	# THE CONTROL. All eight resolving to one texture is exactly what a broken per-class lookup looks
	# like, and every assertion above would still pass if `EXPECTED` had been written from that run.
	if seen.size() < 6:
		_fail += 1
		print("    !! only %d distinct icons across %d families — the lookup is collapsing to the base "
			% [seen.size(), EXPECTED.size()]
			+ "class's icon, so the marker says 'a brush' and not which one")
	_completed += 1


# --- DH: the selected and unselected dots are different images --------------------------------------
#
# "The sprite changes when a point or handle is selected" is the claim, and the two textures are
# generated rather than authored, so nothing outside this gate ever looks at them. Measured where the
# difference is supposed to be — the CENTRE, hollow against filled — and on the rim, which must survive
# being tinted or the marker vanishes against pale ground.
func _gate_dh_dots_differ() -> void:
	print("\n[DH] the selected dot is a different image from the unselected one:")
	var hollow: ImageTexture = GIZMO._dot(false)
	var filled: ImageTexture = GIZMO._dot(true)
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
