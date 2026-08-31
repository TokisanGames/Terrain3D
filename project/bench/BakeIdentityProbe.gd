# Dumps the composited height of a set of brush fixtures to JSON, so the SAME fixtures can be run
# before and after a compositing change and compared pixel for pixel.
#
# Compositing is correctness-critical and has no GDScript A/B oracle, so the bar for changing it is
# BIT-IDENTICAL output (PASTURE3D_BRUSH_PERF_ROUND3_SPEC.md "Verification"). "The pond still looks
# carved" is not that bar, which is why this exists rather than another delta gate.
#
# The fixtures deliberately span the cases where a deferred composite could differ from a per-cell one:
# a single tool, TWO tools sharing one layer (which is where reading a half-composited layer back
# through get_height would show up), a tool with snap_to_surface on (it reads get_height between the
# clear and the paint), and a Plow reading the layers below its own.
#
# Usage:
#   ... --headless --path project bench/BakeIdentityProbe.tscn -- <out.json>
extends Node

const DEMO_DATA := "res://demo/data"

var _terrain
var _root: Node3D
var _out := {}


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var path: String = args[0] if args.size() > 0 else "user://bake_identity.json"

	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA

	_case_pond(Vector3(180.0, 0.0, 120.0))
	_case_mound(Vector3(380.0, 0.0, 120.0))
	_case_two_tools_one_layer(Vector3(580.0, 0.0, 120.0))
	_case_snap(Vector3(180.0, 0.0, 340.0))
	_case_plow_relief(Vector3(380.0, 0.0, 340.0))

	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("could not write %s" % path)
		get_tree().quit(1)
		return
	f.store_string(JSON.stringify(_out, "  ", true))
	f.close()
	print("wrote %d cases to %s" % [_out.size(), path])
	get_tree().quit(0)


## Sample a dense grid of heights over the fixture and record them all. 41x41 at 4 m = a 160 m span,
## which comfortably covers every fixture's loop plus its falloff.
func _record(p_key: String, p_at: Vector3) -> void:
	var vals: Array[float] = []
	for iz in range(41):
		for ix in range(41):
			var p := Vector3(p_at.x + (ix - 20) * 4.0, 0.0, p_at.z + (iz - 20) * 4.0)
			var h: float = _terrain.data.get_height(p)
			vals.append(h if is_finite(h) else NAN)
	# Stored as strings at full float precision: JSON round-tripping a float is where a comparison
	# quietly turns into "equal to 6 decimal places", which is not the bar being tested.
	var out: Array[String] = []
	var finite := 0
	for v in vals:
		if is_finite(v):
			finite += 1
			out.append("%.9f" % v)
		else:
			out.append("nan")
	_out[p_key] = {"n": out.size(), "finite": finite, "h": out}
	print("  %-22s %d samples, %d finite" % [p_key, out.size(), finite])


func _loop(p_node: Node3D, p_hx: float, p_hz: float) -> void:
	var path := Path3D.new()
	var c := Curve3D.new()
	c.add_point(Vector3(-p_hx, 0.0, -p_hz))
	c.add_point(Vector3(p_hx, 0.0, -p_hz))
	c.add_point(Vector3(p_hx, 0.0, p_hz))
	c.add_point(Vector3(-p_hx, 0.0, p_hz))
	c.closed = true
	path.curve = c
	p_node.add_child(path)


func _case_pond(p_at: Vector3) -> void:
	var p := Pasture3DPond.new()
	p.name = "IdPond"
	p.auto_add_water = false
	p.auto_add_loop = false
	_root.add_child(p)
	p.terrain = _terrain
	p.global_position = p_at
	_loop(p, 40.0, 40.0)
	p._refresh_owner(p._layer_owner, false, [])
	_record("pond", p_at)


func _case_mound(p_at: Vector3) -> void:
	var m := Pasture3DMound.new()
	m.name = "IdMound"
	_root.add_child(m)
	m.terrain = _terrain
	m.global_position = p_at
	m.height = 15.0
	_loop(m, 40.0, 30.0)
	m._refresh_owner(m._layer_owner, false, [])
	_record("mound", p_at)


## TWO tools on ONE layer, overlapping. This is the case a per-cell composite could differ on: with the
## old path the second tool's rasterise could read the first tool's contribution back through get_height.
func _case_two_tools_one_layer(p_at: Vector3) -> void:
	var a := Pasture3DMound.new()
	a.name = "IdShareA"
	_root.add_child(a)
	a.terrain = _terrain
	a.global_position = p_at
	a.height = 18.0
	_loop(a, 45.0, 45.0)

	var b := Pasture3DMound.new()
	b.name = "IdShareB"
	_root.add_child(b)
	b.terrain = _terrain
	b.global_position = p_at + Vector3(35.0, 0.0, 20.0)
	b.height = 11.0
	_loop(b, 40.0, 40.0)
	# Same tool layer, so both composite into one stack and overlap.
	b._layer_owner = a._layer_owner

	a._refresh_owner(a._layer_owner, false, [])
	_record("two_tools_one_layer", p_at)


func _case_snap(p_at: Vector3) -> void:
	var m := Pasture3DMound.new()
	m.name = "IdSnap"
	_root.add_child(m)
	m.terrain = _terrain
	m.global_position = p_at
	m.height = 12.0
	m.snap_to_surface = true
	_loop(m, 35.0, 35.0)
	m._refresh_owner(m._layer_owner, false, [])
	_record("snap_to_surface", p_at)


func _case_plow_relief(p_at: Vector3) -> void:
	var p := Pasture3DPlow.new()
	p.name = "IdPlow"
	_root.add_child(p)
	p.terrain = _terrain
	p.global_position = p_at
	var mat := Pasture3DReliefFractal.new()
	mat.style = Pasture3DReliefFractal.Style.CRAGGY
	mat.feature_size = 20.0
	p.modifiers = _relief_mods(mat, 9.0)
	_loop(p, 40.0, 40.0)
	p._refresh_owner(p._layer_owner, false, [])
	_record("plow_relief", p_at)


## The modifier stack replaced the Plow's old `source`/`relief`/`noise`/`height_scale` properties, and
## the compatibility shim that carried them is gone. Relief reaches a brush as a modifier or not at all.
func _relief_mods(p_mat, p_strength: float = 8.0) -> Array[Pasture3DNode]:
	var mr := Pasture3DNodeRelief.new()
	mr.resource_name = "Relief"
	mr.material = p_mat
	mr.strength = p_strength
	return [mr] as Array[Pasture3DNode]
