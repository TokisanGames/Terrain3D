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
	_e_the_lane_graph_is_built_from_the_real_brushes()
	_f_the_networks_traffic_side_reaches_the_connectors()
	_g_every_chunk_host_setting_is_reachable_from_the_inspector()
	_h_turning_collision_on_actually_builds_colliders()
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


## Bake and resolve until the junctions stop asking for anything new — what the editor does across a
## few refreshes, driven explicitly because a gate has no refresh timer.
##
## Two passes are needed and that is inherent: the FIRST resolve builds the lane graph from alignments
## solved before the pins existed, so its arm heights are the unpinned ones. The re-bake those pins
## trigger requests another resolve, and that one sees the profiles the junction asked for.
func _settle(p_net: Pasture3DRoadNetwork, p_brushes: Array, p_ground: PackedFloat32Array,
		p_max: int = 6) -> int:
	var passes := 0
	while passes < p_max:
		for b in p_brushes:
			_bake(b, p_ground)
		p_net.resolve_junctions()
		passes += 1
		var dirty := 0
		for b in p_brushes:
			if b.junction_digest() != b.last_junction_digest:
				dirty += 1
		if dirty == 0 and passes >= 2:
			break
	return passes


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


## [E] The lane graph is built from the brushes the network actually holds, and lands where their
## geometry says. The kernel is gated on literal arms in RoadLaneGraphGate; this is the seam — that the
## network builds those arms from real splines, real trim-backs and real solved heights.
##
## The assertion that catches a wiring error is the POSITION: every connector must start at a trimmed
## end, which is `trim_back` metres from the centre. A graph built from arms at the wrong arc length
## still has twelve connectors and still passes every count, and would be visibly wrong in the viewport.
func _e_the_lane_graph_is_built_from_the_real_brushes() -> void:
	print("[E] the lane graph is built from the real brushes")
	var ground := _valley(0.10)
	var w := _crossroads()
	var net: Pasture3DRoadNetwork = w["net"]
	var brushes: Array[Pasture3DRoadBrush] = [w["ew"], w["ns"]]
	_settle(net, brushes, ground)
	var j: Pasture3DRoadJunction = net.junctions[0] if net.junctions.size() == 1 else null
	if j == null:
		net.queue_free()
		_check("E", false, "no junction to build a lane graph on")
		return
	var n_conn: int = j.connectors.size()
	var n_stop: int = j.stop_lines.size()

	# Every connector endpoint sits on some arm — `trim_back` along the road from the centre, offset to
	# a lane centre — so its distance from the junction centre is hypot(trim, |lane offset|) for one of
	# the participating roads. The major road here is four lanes and the minor two, so there are three
	# distinct radii and an endpoint must land on one of them.
	var want_radii := PackedFloat32Array()
	for b in brushes:
		var trim: float = j.trim_back_for(b.road_key())
		for lane: Dictionary in b.resolved_lanes():
			want_radii.append(sqrt(trim * trim + pow(float(lane["offset"]), 2.0)))
	var worst := 0.0
	for c: Pasture3DRoadLaneConnector in j.connectors:
		for p in [c.entry_point(), c.exit_point()]:
			var r := Vector2(p.x - j.center.x, p.z - j.center.y).length()
			var best := INF
			for want in want_radii:
				best = minf(best, absf(r - want))
			worst = maxf(worst, best)
	var trim_ew: float = j.trim_back_for((w["ew"] as Pasture3DRoadBrush).road_key())
	var trim_ns: float = j.trim_back_for((w["ns"] as Pasture3DRoadBrush).road_key())
	# The heights come from the solved alignments, not from y = 0 — on this valley the junction sits
	# above the floor, so a connector at zero would be metres under the road.
	var lifted := 0
	for c: Pasture3DRoadLaneConnector in j.connectors:
		if absf(c.entry_point().y) > 0.01:
			lifted += 1
	net.queue_free()

	# CONTROL: roads that never meet build no lane graph, so [E] is measuring a junction rather than
	# reporting connectors wherever two brushes exist.
	var far := _crossroads(200.0)
	var far_net: Pasture3DRoadNetwork = far["net"]
	_settle(far_net, [far["ew"], far["ns"]], ground)
	var far_conn := 0
	for k: Pasture3DRoadJunction in far_net.junctions:
		far_conn += k.connectors.size()
	far_net.queue_free()

	print("    %d connectors, %d stop lines; trim-backs %.2f/%.2f m; worst endpoint %.3f m off an arm; %d connectors above y=0"
			% [n_conn, n_stop, trim_ew, trim_ns, worst, lifted])
	print("    control: roads 200 m apart -> %d connectors" % far_conn)
	# Six incoming lanes — two per end of the four-lane major road, one per end of the two-lane minor —
	# each reaching the three other arms.
	_check("E", n_conn == 18 and n_stop == 6 and worst < 0.05 and lifted == n_conn and far_conn == 0,
			"%d connectors / %d stop lines (want 18/6); endpoints %s; %d/%d at a solved height; control %d" % [
				n_conn, n_stop, "on the arms" if worst < 0.05 else "OFF BY %.3f m" % worst,
				lifted, n_conn, far_conn])


## [F] The network's `traffic_side` reaches the connectors. It is a world constant with no per-brush
## override, so the only way it can be wrong is by not being passed down — which is invisible in a
## right-hand world, because right-hand is the default the kernel would fall back to.
func _f_the_networks_traffic_side_reaches_the_connectors() -> void:
	print("[F] the network's traffic side reaches the connectors")
	var ground := _valley(0.10)
	var w := _crossroads()
	var net: Pasture3DRoadNetwork = w["net"]
	net.traffic_side = Pasture3DRoadNetwork.TrafficSide.LEFT
	_settle(net, [w["ew"], w["ns"]], ground)
	var j: Pasture3DRoadJunction = net.junctions[0] if net.junctions.size() == 1 else null
	var left_conflicts := 0
	var right_conflicts := 0
	if j != null:
		for c: Pasture3DRoadLaneConnector in j.connectors:
			if not c.crosses_oncoming:
				continue
			if c.turn == Pasture3DRoadLaneConnector.Turn.LEFT:
				left_conflicts += 1
			elif c.turn == Pasture3DRoadLaneConnector.Turn.RIGHT:
				right_conflicts += 1
	net.queue_free()

	# CONTROL: the default right-hand world marks the LEFT turns instead. Without it this would pass on
	# a network that never passed the flag at all and a kernel that happened to mark right turns.
	var w2 := _crossroads()
	var net2: Pasture3DRoadNetwork = w2["net"]
	_settle(net2, [w2["ew"], w2["ns"]], ground)
	var j2: Pasture3DRoadJunction = net2.junctions[0] if net2.junctions.size() == 1 else null
	var rht_left := 0
	var rht_right := 0
	if j2 != null:
		for c: Pasture3DRoadLaneConnector in j2.connectors:
			if not c.crosses_oncoming:
				continue
			if c.turn == Pasture3DRoadLaneConnector.Turn.LEFT:
				rht_left += 1
			elif c.turn == Pasture3DRoadLaneConnector.Turn.RIGHT:
				rht_right += 1
	net2.queue_free()

	print("    left-hand world: %d left / %d right turns marked as crossing traffic (want 0/6)"
			% [left_conflicts, right_conflicts])
	print("    control: right-hand world: %d left / %d right (want 6/0)" % [rht_left, rht_right])
	_check("F", left_conflicts == 0 and right_conflicts == 6 and rht_left == 6 and rht_right == 0,
			"left-hand %d/%d, right-hand %d/%d" % [left_conflicts, right_conflicts, rht_left, rht_right])


# ---- G ------------------------------------------------------------------------------------------

## [G] Every chunk host setting is reachable from the inspector, and the network actually pushes it.
##
## ---- WHY A SETTING CAN EXIST AND STILL NOT EXIST ----
##
## Chunk hosts are BUILT output. They are created on first bake, replaced on the next one, and
## deliberately not owned by the edited scene — so they never appear in the scene dock, cannot be
## selected, and every `@export` on them is an export with no way in. `collision_enabled` shipped like
## that: declared, defaulted, documented at length, and unreachable. It was found by someone going to
## turn it on and not finding it.
##
## Two halves, because either alone passes on a broken system: the network must EXPOSE a counterpart for
## every host setting, and `_configure_host` must actually COPY it. A network with the exports and no
## copy looks identical in the inspector and does nothing.
func _g_every_chunk_host_setting_is_reachable_from_the_inspector() -> void:
	print("[G] every chunk host setting is reachable from the inspector")
	var net := Pasture3DRoadNetwork.new()
	add_child(net)
	var host := Pasture3DRoadChunkHost.new()

	# Distinctive values, none of them a host default, so a field that is never written stays visibly at
	# its default rather than accidentally matching.
	net.ribbon_lod_distances = PackedFloat32Array([11.0, 22.0, 33.0])
	net.ribbon_far_distance = 444.0
	net.ribbon_hysteresis = 5.5
	net.ribbon_lift = 0.077
	net.ribbon_collision = true
	net.ribbon_collision_layer = 8
	net.ribbon_collision_mask = 4
	net.ribbon_markings = false
	net.ribbon_props = false
	net._configure_host(host)

	var want := {
		"lod_distances": PackedFloat32Array([11.0, 22.0, 33.0]),
		"far_distance": 444.0,
		"lod_hysteresis": 5.5,
		"depth_lift": 0.077,
		"collision_enabled": true,
		"collision_layer": 8,
		"collision_mask": 4,
		"markings_enabled": false,
		"props_enabled": false,
	}
	var unpushed := PackedStringArray()
	for k: String in want:
		if host.get(k) != want[k]:
			unpushed.append("%s (%s, want %s)" % [k, str(host.get(k)), str(want[k])])
	print("    %d host setting(s) checked; not pushed: %s" % [want.size(), str(Array(unpushed))])

	# The COVERAGE half: walk the host's own script exports and require each to be in the pushed set. This
	# is what catches the NEXT one — a setting added to the host later is unreachable the day it is
	# added, and nothing else in the suite would notice.
	var exempt := PackedStringArray(["markings_material"])  # a Material, set from the road type
	var uncovered := PackedStringArray()
	for prop in host.get_property_list():
		if int(prop["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		if int(prop["usage"]) & PROPERTY_USAGE_EDITOR == 0:
			continue
		var n: String = prop["name"]
		if n.begins_with("_") or want.has(n) or exempt.has(n):
			continue
		uncovered.append(n)
	print("    host exports with no network counterpart: %s" % str(Array(uncovered)))
	_check("G", unpushed.is_empty() and uncovered.is_empty(),
			"%d setting(s) not pushed, %d with no way in" % [unpushed.size(), uncovered.size()])

	# CONTROL: the check must be able to SEE a host that was not configured, or it is comparing a value
	# against itself and would pass on a `_configure_host` that returned immediately.
	var fresh := Pasture3DRoadChunkHost.new()
	var differing := 0
	for k: String in want:
		if fresh.get(k) != want[k]:
			differing += 1
	print("    control: an unconfigured host differs on %d of %d setting(s) (want all)"
			% [differing, want.size()])
	if differing != want.size():
		_fail += 1
		print("    !! some fixture values match the host defaults, so those fields prove nothing")

	# CONTROL: the coverage walk must actually be finding properties. An empty walk reports zero uncovered
	# and passes forever.
	print("    control: the walk saw %d host export(s) (want more than the %d it checks)"
			% [want.size() + uncovered.size() + exempt.size(), want.size()])
	if want.size() + uncovered.size() + exempt.size() <= want.size():
		_fail += 1
		print("    !! the property walk found nothing, so coverage is not being checked")
	fresh.free()
	host.free()
	net.free()


## Every StaticBody3D under `p_at`, at any depth.
func _bodies(p_at: Node) -> Array[StaticBody3D]:
	var out: Array[StaticBody3D] = []
	var stack: Array[Node] = [p_at]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is StaticBody3D:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


# ---- H ------------------------------------------------------------------------------------------

## [H] Turning collision on actually builds colliders, on the ribbon AND on the junction aprons.
##
## [G] proves the setting can be reached and is copied into the host. That is not the same claim as this
## one: a host with `collision_enabled` true still builds nothing if the bake path never rebuilds, if the
## spans are empty, or if the aprons take a different code path from the chunks — which they did.
##
## Driven through `build_chunks`, the real bake entry point, rather than by calling `rebuild` on a host
## the gate made itself. The host-level route is already covered by RoadMeshGate; what is untested and
## what has broken is the WIRING from an inspector checkbox to a shape in the tree.
func _h_turning_collision_on_actually_builds_colliders() -> void:
	print("[H] turning collision on actually builds colliders")
	var f := _crossroads()
	var net: Pasture3DRoadNetwork = f["net"]
	var brushes: Array = [f["ew"], f["ns"]]
	_settle(net, brushes, _grid(0.0))

	net.ribbon_collision = true
	net.ribbon_collision_layer = 2
	net.build_chunks(brushes)
	var ribbon := _bodies(f["ew"]).size() + _bodies(f["ns"]).size()
	var aprons := _bodies(net.ensure_junction_host()).size()
	var on_layer := 0
	for b in _bodies(net):
		if b.collision_layer == 2:
			on_layer += 1
	print("    collision on: %d ribbon collider(s), %d apron collider(s), %d on layer 2"
			% [ribbon, aprons, on_layer])
	_check("H", ribbon > 0 and aprons > 0 and on_layer == ribbon + aprons,
			"%d ribbon / %d apron collider(s), %d on the road layer" % [ribbon, aprons, on_layer])

	# CONTROL: off must build NONE. Without this the criterion passes on a host that ignores the flag and
	# always builds shapes, which is the same bug with the opposite sign and costs every road its shapes.
	net.ribbon_collision = false
	net.build_chunks(brushes)
	var off := _bodies(net).size()
	print("    control: collision off -> %d collider(s) anywhere under the network (want 0)" % off)
	if off != 0:
		_fail += 1
		print("    !! colliders are built whether the setting is on or not")

	# CONTROL: the apron count must be the JUNCTION count, not zero-because-there-are-no-junctions. An
	# apron collider criterion on a network with no junctions proves nothing at all.
	var detected := 0
	for j in net.junctions:
		if j.detected and j.radius > 0.01:
			detected += 1
	print("    control: %d detected junction(s) to build aprons for (want more than 0)" % detected)
	if detected == 0:
		_fail += 1
		print("    !! the fixture has no junction, so the apron half of this criterion is vacuous")
	net.queue_free()
