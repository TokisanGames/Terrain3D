# Gates for the masked Pool's sheet-coarsening warning and the vertex budget, both of which used to be
# evaluated BEFORE the code decided whether a static sheet or the camera-centred clipmap carries the
# surface (pool.gd _build_masked).
#
# Two defects came out of that ordering:
#   1. a clipmapped body warned that "the sheet was coarsened", about a sheet never built -- the warning
#      even ended "this is the gap the camera-centred clipmap closes", on a body where it had. This is
#      the one users hit; it fires on any masked lake big enough to reach the clipmap.
#   2. _budget_exceeded ran on that same phantom sheet, so a clipmapped body could fail to build over
#      vertices the clipmap was never going to emit. LATENT, not something anyone hit: the coarsening
#      has to reach 512 m spacing first, which at the default 400 000 ceiling needs a body roughly
#      323 km across. Gate D pins the correct behaviour down anyway, with a hand-lowered ceiling.
#
# Every criterion here carries a control: the warning must still fire, and the budget must still refuse,
# on a static-sheet body, or these gates would pass just as well if the warning had been deleted.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/PoolClipmapWarningProbe.tscn
extends Node

const COARSEN_MARK := "was coarsened"

var _fail := 0
var _root: Node3D


func _ready() -> void:
	print("\n=== Pool: coarsening warning and budget vs the clipmap ===\n")
	_root = Node3D.new()
	add_child(_root)
	if not ClassDB.class_exists("Pasture3DWaterClipmap"):
		print("!! Pasture3DWaterClipmap is missing from this build; every case below would take the")
		print("   static-sheet path and the gates would be vacuous. Rebuild the extension.")
		get_tree().quit(1)
		return

	_gate_a_small_body_unchanged()
	_gate_b_clipmapped_does_not_warn()
	_gate_c_static_sheet_still_warns()
	_gate_d_clipmap_ignores_the_budget()

	print("\n=== %s (%d failures) ===\n" % ["POOL CLIPMAP PASS" if _fail == 0 else "POOL CLIPMAP FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- A: a body that fits is untouched by any of this ----------------------------------------------
func _gate_a_small_body_unchanged() -> void:
	print("[A] a small body still builds a real sheet and says nothing about coarsening:")
	var p = _build(40.0, false, 0)
	print("    clipmap %s | sheet mesh %s | _sheet_spacing_used %.2f" % [
			p._last_stats.get("clipmap", false), p._surface != null and p._surface.mesh != null,
			p._sheet_spacing_used])
	if p._last_stats.get("clipmap", false):
		_fail += 1
		print("    !! a small body went to the clipmap; this gate is not testing the sheet path")
	if not p._last_stats.get("ok", false):
		_fail += 1
		print("    !! it did not build")
	if _has_coarsen_warning(p):
		_fail += 1
		print("    !! a body that fits max_vertices reported coarsening")


# --- B: THE BUG -- a clipmapped body must not warn about a sheet it never built --------------------
func _gate_b_clipmapped_does_not_warn() -> void:
	print("\n[B] a clipmapped body does not warn about sheet coarsening:")
	var p = _build(600.0, false, 0)
	var carried: bool = p._last_stats.get("clipmap", false)
	var meshed: bool = p._surface != null and p._surface.mesh != null
	print("    clipmap carries %s | surface mesh %s | _sheet_spacing_used %.2f | vertices %s" % [
			carried, meshed, p._sheet_spacing_used, p._last_stats.get("vertices", 0)])
	if not carried:
		_fail += 1
		print("    !! the clipmap did not take this body; the gate cannot see the bug")
		return
	if meshed:
		_fail += 1
		print("    !! a sheet was built as well as the clipmap; that is a doubled surface")
	if not p._last_stats.get("ok", false):
		_fail += 1
		print("    !! it did not build")
	if _has_coarsen_warning(p):
		_fail += 1
		print("    !! still warning about a sheet that does not exist")
	if p._sheet_spacing_used != 0.0:
		_fail += 1
		print("    !! _sheet_spacing_used is non-zero on a body with no sheet")
	# The clipmap must still be paying for itself, or "no warning" would just mean "no surface".
	if int(p._last_stats.get("vertices", 0)) < 1000:
		_fail += 1
		print("    !! the clipmap emitted almost no vertices; there may be no surface at all")


# --- C: CONTROL -- the same body on the static sheet must still coarsen AND still say so -----------
func _gate_c_static_sheet_still_warns() -> void:
	print("\n[C] CONTROL the same body with mask_static_sheet ON still coarsens and still warns:")
	var p = _build(600.0, true, 0)
	print("    clipmap %s | _sheet_spacing_used %.2f | ok %s" % [
			p._last_stats.get("clipmap", false), p._sheet_spacing_used, p._last_stats.get("ok", false)])
	if p._last_stats.get("clipmap", false):
		_fail += 1
		print("    !! mask_static_sheet did not force the sheet path")
		return
	if p._sheet_spacing_used <= 0.0:
		_fail += 1
		print("    !! the sheet path recorded no spacing")
	if not _has_coarsen_warning(p):
		_fail += 1
		print("    !! the coarsening warning has been lost for the case where it IS true")
	else:
		print("    warns: yes -- the warning still works where a sheet really was coarsened")


# --- D: the budget is a sheet limit, not a body limit ----------------------------------------------
# max_vertices is deliberately tiny. On the sheet path that must refuse; on the clipmap path, whose
# cost is a property of its rings and not of the body, it must build anyway.
func _gate_d_clipmap_ignores_the_budget() -> void:
	print("\n[D] a punishing max_vertices refuses a sheet but not a clipmap:")
	var sheet = _build(600.0, true, 4096)
	var loose = _build(600.0, true, 0)
	print("    static sheet, default max_vertices -> spacing %.2f m" % loose._sheet_spacing_used)
	print("    static sheet, max_vertices 4096    -> ok %s | spacing %.2f m" % [
			sheet._last_stats.get("ok", false), sheet._sheet_spacing_used])
	var clip = _build(600.0, false, 4096)
	var verts := int(clip._last_stats.get("vertices", 0))
	print("    clipmap,      max_vertices 4096    -> ok %s | vertices %d" % [
			clip._last_stats.get("ok", false), verts])

	if not clip._last_stats.get("ok", false):
		_fail += 1
		print("    !! the clipmapped body failed the budget for a sheet it never builds")
	if not clip._last_stats.get("clipmap", false):
		_fail += 1
		print("    !! it did not go to the clipmap, so this proves nothing")
	# The sharpest statement of the claim: the clipmap emitted MORE vertices than max_vertices and built
	# anyway, because its cost is a property of its rings and the budget is a sheet limit.
	if verts <= 4096:
		_fail += 1
		print("    !! the clipmap stayed under the budget, so this run cannot tell whether it applies")
	else:
		print("    the clipmap drew %dx max_vertices and built -- the budget is a SHEET limit" % (verts / 4096))

	# CONTROL -- the budget must visibly bite the sheet path under the same setting, or "the clipmap
	# ignored it" is not evidence of anything. It pushes back by COARSENING, not only by refusing, so
	# the test is that the tight budget produced a much coarser sheet than the loose one.
	if not sheet._last_stats.get("ok", false):
		print("    CONTROL the sheet refused outright at this budget")
	elif sheet._sheet_spacing_used < loose._sheet_spacing_used * 4.0:
		_fail += 1
		print("    !! the tight budget barely changed the sheet (%.2f vs %.2f m); it is not enforced"
				% [sheet._sheet_spacing_used, loose._sheet_spacing_used])
	else:
		print("    CONTROL the sheet coarsened %.2f -> %.2f m under the same budget"
				% [loose._sheet_spacing_used, sheet._sheet_spacing_used])


# --- helpers ---------------------------------------------------------------------------------------

func _build(p_half: float, p_static: bool, p_max_vertices: int):
	var path := Path3D.new()
	var c := Curve3D.new()
	c.add_point(Vector3(-p_half, 0.0, -p_half))
	c.add_point(Vector3(p_half, 0.0, -p_half))
	c.add_point(Vector3(p_half, 0.0, p_half))
	c.add_point(Vector3(-p_half, 0.0, p_half))
	c.closed = true
	path.curve = c
	_root.add_child(path)

	var script: GDScript = load("res://addons/pasture_3d/connectors/pasture3d_pool.gd")
	var pool: Node = script.new()
	pool.name = "P%d%s%d" % [int(p_half), "S" if p_static else "C", p_max_vertices]
	_root.add_child(pool)
	pool.mask_static_sheet = p_static
	if p_max_vertices > 0:
		pool.max_vertices = p_max_vertices
	pool.source_spline = path
	pool.rebuild()
	return pool


func _has_coarsen_warning(p_pool) -> bool:
	for w in p_pool._get_configuration_warnings():
		if String(w).contains(COARSEN_MARK):
			return true
	return false
