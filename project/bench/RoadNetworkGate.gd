# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadNetworkGate — the P4a WIRING: network → junction solver → pins → grading. Not the kernels.
#
# ---- WHY THIS GATE EXISTS AT ALL ----
#
# Every P2 bug that reached the editor lived between components, not inside one. The grader was right and
# the brush masked the corridor to 8 m; the solver was right and the padding was stale. Three component
# gates were green through all of it, because a value defined in three places is fixed in none. So this
# gate assembles the real objects — a Pasture3DRoadNetwork with two Pasture3DRoadBrush children, each
# with a real Path3D — and drives them through the actual bake entry point, `grade_surface`.
#
# It needs no Terrain3D: `grade_surface` takes its heightfield as arguments, which is the same property
# that made the grader gateable. What it does NOT cover is the editor's refresh path — that is what the
# manual pass after this is for.
@tool
extends Node

const GW: int = 121
const GH: int = 121
const VS: float = 1.0
const MIN_X: float = -60.0
const MIN_Z: float = -60.0

var _fail: int = 0


func _ready() -> void:
	print("=== RoadNetworkGate: network integration, pins and trim-back (P4a) ===\n")
	_a_the_network_finds_the_crossing_its_brushes_make()
	_b_the_pin_reaches_the_minor_roads_profile()
	_c_the_trim_back_stops_the_minor_road_grading_the_junction()
	_d_the_resolve_loop_settles()
	print("\n=== %s (%d failures) ===\n" % ["ROAD NETWORK PASS" if _fail == 0 else "ROAD NETWORK FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ---- fixtures -----------------------------------------------------------------------------------

func _road_type(p_name: String, p_priority: int, p_lanes: int) -> Pasture3DRoadType:
	var t := Pasture3DRoadType.new()
	t.type_name = p_name
	t.priority = p_priority
	t.lane_count = p_lanes
	t.lane_width = 3.5
	t.shoulder_width = 0.5
	return t


## A brush with one straight spline from `p_a` to `p_b`, parented under `p_net`.
func _brush(p_net: Pasture3DRoadNetwork, p_name: String, p_a: Vector2, p_b: Vector2,
		p_type: Pasture3DRoadType) -> Pasture3DRoadBrush:
	var b := Pasture3DRoadBrush.new()
	b.name = p_name
	p_net.add_child(b)
	var path := Path3D.new()
	path.name = p_name + "Spline"
	var c := Curve3D.new()
	c.add_point(Vector3(p_a.x, 0.0, p_a.y))
	c.add_point(Vector3(p_b.x, 0.0, p_b.y))
	path.curve = c
	b.add_child(path)
	b.road_road_type = p_type
	var mod := Pasture3DNodeRoad.new()
	mod.alignment_step = 1.0
	b.modifiers = [mod]
	return b


## A flat heightfield at `p_h`.
func _grid(p_h: float) -> PackedFloat32Array:
	var z := PackedFloat32Array()
	z.resize(GW * GH)
	z.fill(p_h)
	return z


## A V-shaped valley running north-south, floor at x = 0, sides rising `p_slope` per metre.
##
## Chosen so the two roads DISAGREE about the height of the crossing: the east-west road has to cross the
## valley and its grade limit lifts it metres above the floor, while the north-south road runs along the
## floor and would solve flat. On a plane — tilted or not — both roads want the same height where they
## meet, and a pin that never arrived would be indistinguishable from one that did.
func _valley(p_slope: float) -> PackedFloat32Array:
	var z := PackedFloat32Array()
	z.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			z[iz * GW + ix] = absf(MIN_X + float(ix) * VS) * p_slope
	return z


func _bake(p_brush: Pasture3DRoadBrush, p_ground: PackedFloat32Array) -> Dictionary:
	var mod: Pasture3DNodeRoad = p_brush.road_modifier()
	return p_brush.grade_surface(mod, p_ground, GW, GH, MIN_X, MIN_Z, VS)


func _at(p_z: PackedFloat32Array, p_x: float, p_zw: float) -> float:
	var ix := int(round((p_x - MIN_X) / VS))
	var iz := int(round((p_zw - MIN_Z) / VS))
	return p_z[clampi(iz, 0, GH - 1) * GW + clampi(ix, 0, GW - 1)]


## Network with a major east-west road and a minor north-south one, crossing at the origin.
func _crossroads(p_gap: float = 0.0) -> Dictionary:
	var net := Pasture3DRoadNetwork.new()
	add_child(net)
	var major := _road_type("major", 10, 4)
	var minor := _road_type("minor", 1, 2)
	net.road_types = [major, minor]
	var ew := _brush(net, "EW", Vector2(-50.0, 0.0), Vector2(50.0, 0.0), major)
	var ns := _brush(net, "NS", Vector2(p_gap, -50.0), Vector2(p_gap, 50.0), minor)
	return {"net": net, "ew": ew, "ns": ns}


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	if not p_ok:
		_fail += 1
	print("%s %s: %s" % ["   " if p_ok else "!! ", p_name, p_detail])


# ---- criteria -----------------------------------------------------------------------------------

## [A] Two brushes that cross produce one junction, keyed by their own road_key()s. The control is the
## same scene with the roads 200 m apart: if the network is finding junctions in some way that does not
## depend on where its brushes actually are, this still reports one.
func _a_the_network_finds_the_crossing_its_brushes_make() -> void:
	print("[A] the network finds the crossing its brushes make")
	var w := _crossroads()
	var net: Pasture3DRoadNetwork = w["net"]
	var ground := _grid(0.0)
	_bake(w["ew"], ground)
	_bake(w["ns"], ground)
	net.resolve_junctions()
	var n_cross := net.junctions.size()
	var keys := PackedStringArray()
	var centre := Vector2.INF
	if n_cross == 1:
		keys = net.junctions[0].road_keys
		centre = net.junctions[0].center
	var ew_key: String = (w["ew"] as Pasture3DRoadBrush).road_key()
	var ns_key: String = (w["ns"] as Pasture3DRoadBrush).road_key()
	var keyed := Array(keys).has(ew_key) and Array(keys).has(ns_key)
	net.queue_free()

	var far := _crossroads(200.0)
	var far_net: Pasture3DRoadNetwork = far["net"]
	_bake(far["ew"], ground)
	_bake(far["ns"], ground)
	far_net.resolve_junctions()
	var n_far := far_net.junctions.size()
	far_net.queue_free()

	_check("A", n_cross == 1 and keyed and centre.length() < 1.0 and n_far == 0,
			"crossing -> %d junction(s) at (%.1f, %.1f), keys %s [%s/%s]; 200 m apart -> %d" % [
				n_cross, centre.x, centre.y, "matched" if keyed else "WRONG", ew_key, ns_key, n_far])


## [B] The junction's pin arrives in the minor road's alignment solve. On a tilted plane the two roads
## want different heights where they cross, so a minor road that ignored the pin would sit at its own
## solved height. The control is the same fixture with the junction DISABLED: the pin is withheld and the
## minor road must go back to differing.
func _b_the_pin_reaches_the_minor_roads_profile() -> void:
	print("[B] the pin reaches the minor road's profile")
	var ground := _valley(0.10)
	var w := _crossroads()
	var net: Pasture3DRoadNetwork = w["net"]
	var ew: Pasture3DRoadBrush = w["ew"]
	var ns: Pasture3DRoadBrush = w["ns"]
	_bake(ew, ground)
	_bake(ns, ground)
	var free_h: float = ns.road_modifier().last_alignment.height_at(50.0)
	net.resolve_junctions()
	var j: Pasture3DRoadJunction = net.junctions[0] if net.junctions.size() == 1 else null
	var elev: float = j.elevation if j != null else NAN
	_bake(ns, ground)
	var pinned_h: float = ns.road_modifier().last_alignment.height_at(j.arc_length_for(ns.road_key()) if j != null else 50.0)

	if j != null:
		j.disabled = true
	_bake(ns, ground)
	var off_h: float = ns.road_modifier().last_alignment.height_at(50.0)
	net.queue_free()

	var landed := is_finite(elev) and absf(pinned_h - elev) < 0.05
	var control := absf(off_h - elev) > 0.05 and absf(off_h - free_h) < 0.05
	_check("B", landed and control,
			"junction elevation %.3f; minor solved %.3f, pinned %.3f (%s); disabled -> %.3f (%s)" % [
				elev, free_h, pinned_h, "on the pin" if landed else "IGNORED THE PIN", off_h,
				"back off it" if control else "CONTROL DID NOT MOVE"])


## [C] The trim-back keeps the minor road out of the junction footprint. Right at the centre the ground
## must be whatever the MAJOR road wrote — the minor approach stops short — and that is only true if the
## skip array actually reached the grader. The control is the same bake with the junction disabled: the
## minor road then grades straight through and the cell moves.
func _c_the_trim_back_stops_the_minor_road_grading_the_junction() -> void:
	print("[C] the trim-back stops the minor road grading the junction")
	var ground := _valley(0.10)
	var w := _crossroads()
	var net: Pasture3DRoadNetwork = w["net"]
	var ns: Pasture3DRoadBrush = w["ns"]
	_bake(w["ew"], ground)
	_bake(ns, ground)
	net.resolve_junctions()
	var j: Pasture3DRoadJunction = net.junctions[0] if net.junctions.size() == 1 else null
	var trim: float = j.trim_back_for(ns.road_key()) if j != null else 0.0
	# A point on the NS centreline INSIDE the trim-back, and one comfortably outside it.
	var inside_z := maxf(trim - 1.0, 1.0)
	var outside_z := trim + 12.0

	var trimmed: Dictionary = _bake(ns, ground)
	var h_in: float = _at(trimmed["height"], 0.0, inside_z)
	var bed_in: float = _at(trimmed["roadbed"], 0.0, inside_z)
	var bed_out: float = _at(trimmed["roadbed"], 0.0, outside_z)
	var g_in := _at(ground, 0.0, inside_z)

	if j != null:
		j.disabled = true
	var through: Dictionary = _bake(ns, ground)
	var c_in: float = _at(through["height"], 0.0, inside_z)
	var c_bed: float = _at(through["roadbed"], 0.0, inside_z)
	net.queue_free()

	# The height alone is degenerate on the valley floor — a road that solves flat at ground level writes
	# the height it would have written anyway — so the ROADBED MASK carries the assertion: inside the
	# footprint the minor road claims no carriageway at all.
	var stopped := absf(h_in - g_in) < 1e-4 and bed_in == 0.0
	var still_grades := bed_out == 1.0
	# The control disables the junction, which withholds the pin AND the trim together, so its height on
	# the valley floor is 0 either way — only the mask separates them. The height clause above is not
	# vacuous for the same reason it is here: WITH the pin the road wants to sit 0.76 m up, so a trim that
	# failed to apply would show as a moved cell.
	var control := c_bed == 1.0
	_check("C", trim > 0.0 and stopped and still_grades and control,
			"trim %.2f m; inside z=%.1f ground %.3f -> %.3f roadbed %.0f (%s); disabled -> %.3f roadbed %.0f (%s); outside z=%.1f roadbed %.0f (%s)" % [
				trim, inside_z, g_in, h_in, bed_in, "left alone" if stopped else "GRADED ANYWAY",
				c_in, c_bed, "control graded" if control else "CONTROL DID NOT MOVE",
				outside_z, bed_out, "graded" if still_grades else "NOT GRADED"])


## [D] The bake→resolve→bake loop terminates. After one resolve and the re-bakes it asks for, a second
## resolve must ask for nothing: the digest is the fixed point. Without this the widening feedback and
## the pin feedback could ping-pong forever in the editor and the only symptom would be a hot CPU.
func _d_the_resolve_loop_settles() -> void:
	print("[D] the resolve loop settles")
	var ground := _valley(0.10)
	var w := _crossroads()
	var net: Pasture3DRoadNetwork = w["net"]
	var brushes: Array[Pasture3DRoadBrush] = [w["ew"], w["ns"]]
	var passes := 0
	var dirty := 2
	while dirty > 0 and passes < 6:
		for b in brushes:
			_bake(b, ground)
		net.resolve_junctions()
		dirty = 0
		for b in brushes:
			if b.junction_digest() != b.last_junction_digest:
				dirty += 1
		passes += 1
	# A digest that never changes would make [D] pass for the wrong reason, so it also has to have SAID
	# something: an empty digest means no junction reached the brush at all.
	var said: bool = not (brushes[1].junction_digest().is_empty())
	net.queue_free()
	_check("D", dirty == 0 and passes <= 3 and said,
			"settled after %d pass(es), %d brush(es) still dirty; minor digest %s" % [
				passes, dirty, "non-empty" if said else "EMPTY (nothing was wired)"])
