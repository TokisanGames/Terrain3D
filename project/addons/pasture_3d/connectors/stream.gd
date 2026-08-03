# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DStream — a river, a creek, a canal: water that runs along an open channel.
# See PASTURE3D_WATER_BODIES_SPEC.md §7.3 and §10.
#
# Normally created by pressing Add Water on a Pasture3DTrough. The Trough carved the channel and
# already knows how wide its bed is; this fills it with a strip of surface that FOLLOWS THE SPLINE
# DOWNHILL (§7.2), because a river drawn flat reads as a canal cut through the hillside.
#
# WHERE THE SURFACE COMES FROM. Not from the spline. A Trough's spline is the BED FLOOR, and the
# level of a river is set by its banks, not by its bottom -- so each row goes and measures the
# terrain on both sides, takes the LOWER crest (water cannot stand higher than the side it would
# spill over), and sits `bank_height` below it. Depth then varies along the run for free: a reach
# where the bed rises toward the surface becomes a ford the player can wade, and nobody authored
# it. The waterline on each side is found the same way, so the strip widens through a shallow
# reach and pulls in through a gorge, asymmetrically where the channel is cut into a slope.
#
# With no Pasture3D to sample the whole of that falls back to bed + fill_offset, which is the
# behaviour this had before, and which is what keeps a stream over a bare mesh working.
#
# WAS PART OF Pasture3DPool. Until the split, an open curve made a Pasture3DPool mesh itself as a
# ribbon; a pool from a scene authored then draws nothing and offers a Convert to Stream button.
@tool
@icon("res://addons/pasture_3d/icons/brush_terrain.svg")
class_name Pasture3DStream
extends Pasture3DWaterBody

const PRESET_PATHS := {
	0: WATER_DIR + "M_water_river.tres",
}

# --- Channel (the surface reference) ------------------------------------------
#
# Its own group rather than more of the base class's "Shape": these are the properties that make a
# river a river, and the inspector should not show two groups called Shape.

@export_group("Channel")
## Half-width of the surface, in metres, before edge_offset is added on each side. This is the
## FALLBACK width: it is used where the banks cannot be sampled -- no terrain in the scene, or a
## row whose surroundings read as NAN -- and ignored everywhere the waterline was found. Seeded
## from a Trough's bed_half_width when the button creates the stream.
@export var ribbon_half_width: float = 4.0:
	set(v):
		ribbon_half_width = maxf(v, 0.1)
		_schedule_rebuild()
## Metres below the bank top that the water sits. Freeboard. This is the level control; the bed
## does not set it. Raise it for a river running low in its channel, lower it toward 0 to fill to
## the brim.
@export var bank_height: float = 0.5:
	set(v):
		bank_height = v
		_schedule_rebuild()
## Metres out from the centreline where the bank top is looked for. 0 = automatic: a Trough's
## bed_half_width + bank_width if this stream came from one, else ribbon_half_width * 3.
##
## This is the knob that matters when a river runs along a hillside. The search has to reach the
## bank crest and stop -- push it out onto the slope above and the "bank" it finds is partway up
## the hill, and the river fills to there.
@export var bank_search_width: float = 0.0:
	set(v):
		bank_search_width = maxf(v, 0.0)
		_schedule_rebuild()
## Smoothing passes over the sampled surface line. Terrain samples are noisy and a river surface
## that climbs, even by centimetres, reads as broken. 0 disables it and shows the raw samples.
@export_range(0, 20) var bank_smoothing: int = 4:
	set(v):
		bank_smoothing = clampi(v, 0, 20)
		_schedule_rebuild()

# --- Flow ---------------------------------------------------------------------

@export_group("Flow")
## Metres per second the surface texture is advected downstream. Written into ARRAY_COLOR.b,
## normalised against FLOW_SPEED_REF, and read by water_river.gdshader. It moves the texture, not
## the water: nothing is simulated and no buoy is pushed by it.
@export var flow_speed: float = 1.5:
	set(v):
		flow_speed = maxf(v, 0.0)
		_schedule_rebuild()
## How much a downhill gradient adds to that speed. 0 = uniform along the channel; higher makes
## steep reaches read as rapids. A per-row scalar, so one river can have both.
@export var flow_slope_gain: float = 3.0:
	set(v):
		flow_slope_gain = maxf(v, 0.0)
		_schedule_rebuild()
## Run the flow the other way along the spline, for a channel drawn from the mouth up.
##
## Flips the direction written into ARRAY_COLOR, and with it which way `flow_slope_gain` counts
## as downhill -- reversing the flow without reversing that would leave the rapids on the reaches
## the water now climbs. It does NOT flip the perpendicular, so the left and right waterlines and
## every containment answer stay where they were.
@export var flow_reverse: bool = false:
	set(v):
		flow_reverse = v
		_schedule_rebuild()

# --- Internals ----------------------------------------------------------------

## The sampled centreline in LOCAL space (x, y, z per row) and the per-row flow speed, kept so
## height queries and containment do not re-bake the curve. See _still_surface_y.
var _ribbon_rows := PackedVector3Array()
var _ribbon_speed := PackedFloat32Array()
## Per-row half-width to the left and right of the centreline, in metres. Separate sides because
## a channel cut into a slope has an asymmetric waterline -- the surface reaches further into the
## shallow bank than the steep one, and averaging them would put the mesh edge in the air on one
## side and underground on the other. Empty when the banks could not be sampled; the constant
## ribbon_half_width is used then.
var _ribbon_half_l := PackedFloat32Array()
var _ribbon_half_r := PackedFloat32Array()
## Last terrain resolved for bank sampling, and the brush whose `baked` signal we follow. Held by
## instance check rather than reference so a freed terrain cannot be resurrected by the cache.
var _terrain_cache: Node = null
var _baked_source: Node = null
## Cell -> nearest centreline row index, over _poly_bounds at _cell_spacing. -1 = not on the river.
## The stream's answer to what the inside mask is for a pool: it turns "which row am I near" from a
## scan over every row into an array lookup.
var _ribbon_cell := PackedInt32Array()
var _cell_gw := 0
var _cell_gh := 0
var _cell_spacing := 0.0


# ---- the shape contract ------------------------------------------------------

func _preset_names() -> PackedStringArray:
	# No Lake or Pond entry, and that is not tidiness: the river shader reads a flow direction out
	# of ARRAY_COLOR that only this mesh writes, and the lake shader ignores it. Offering the wrong
	# two here would be offering a river that does not flow.
	return PackedStringArray(["River", "Custom"])


func _preset_paths() -> Dictionary:
	return PRESET_PATHS


func is_ribbon() -> bool:
	return true


func _has_surface() -> bool:
	return _ribbon_rows.size() >= 2


## Lateral distance from the centreline, not a polygon walk: a stream is defined by a width about a
## line and has no outline to be inside of.
func _contains_local(p_local_xz: Vector2) -> bool:
	return _ribbon_surface_at(p_local_xz)[0]


## A river has no single level -- it runs downhill -- so the still surface here is whatever the
## nearest centreline row sits at. Off the river it falls back to the node's own Y, which is what
## the base class would have answered and what keeps a query just outside the strip continuous
## with one just inside it.
func _still_surface_y(p_global_xz: Vector2) -> float:
	if _ribbon_rows.is_empty():
		return global_position.y
	var local: Vector3 = global_transform.affine_inverse() \
		* Vector3(p_global_xz.x, 0.0, p_global_xz.y)
	var surf := _ribbon_surface_at(Vector2(local.x, local.z))
	if not surf[0]:
		return global_position.y
	return (global_transform * Vector3(0.0, surf[1], 0.0)).y


func _shape_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	var src := _source_curve()
	if src == null:
		w.append("No source. Set source_spline to a brush's Path3D, or assign a Curve3D.")
	elif src.point_count < 2:
		w.append("The source curve has fewer than 2 points, so there is no channel to follow.")
	return w


# ---- source plumbing ---------------------------------------------------------

## Follow the source brush's `baked` signal, on top of the curve signals the base class connects.
##
## A bank-referenced stream reads its surface out of terrain heights, so a Trough edit invalidates
## it without touching the curve -- and the curve is all the base class watches. Deepening a
## channel by 2 m with no spline change would have left the water where it was.
##
## Not in Pasture3DWaterBody, because a pool genuinely does not care: its level is its own
## transform, and rebuilding every lake in the scene on every brush bake would be a rebuild storm
## while a spline is being dragged.
func _connect_source() -> void:
	super()
	var brush := _source_brush()
	if brush == null or not brush.has_signal("baked"):
		return
	if _baked_source == brush and is_instance_valid(brush):
		return
	_disconnect_baked()
	_baked_source = brush
	if not brush.baked.is_connected(_on_source_baked):
		brush.baked.connect(_on_source_baked)


func _disconnect_source() -> void:
	_disconnect_baked()
	super()


func _disconnect_baked() -> void:
	if _baked_source != null and is_instance_valid(_baked_source) \
			and _baked_source.has_signal("baked") \
			and _baked_source.baked.is_connected(_on_source_baked):
		_baked_source.baked.disconnect(_on_source_baked)
	_baked_source = null


## The terrain under this stream was rebaked. Only worth a rebuild when there IS terrain: with none,
## the surface is on fill_offset and nothing the brush did can have moved it.
func _on_source_baked() -> void:
	if _resolve_terrain() != null:
		_schedule_rebuild()


# ---- meshing (spec §7.3, §10) ------------------------------------------------

## Build the strip for an open curve.
##
## The mesh carries real Y per row, so every height query has to ask the centreline rather than
## return one number -- which is the whole reason _still_surface_y is a hook rather than a constant.
func _build_surface(p_spacing: float) -> void:
	var centre := _ribbon_centreline(p_spacing)
	if centre.size() < 2:
		_build_failed("the curve has no usable length")
		return
	_ribbon_rows = centre

	# Column count is sized off the WIDEST row, so a river that opens out is not under-sampled
	# there; narrower rows pack the same columns closer, which costs nothing and keeps the strip
	# a regular grid.
	var half := ribbon_half_width + edge_offset
	var widest := half
	for r in centre.size():
		widest = maxf(widest, _row_half(r, true) + _row_half(r, false))
	# Columns across the channel at the same spacing as along it, so the surface is not stretched in
	# one axis -- the detail normals are derived from world position and a stretched grid shows.
	var cols := maxi(int(ceil(widest / p_spacing)) + 1, 2)
	var rows := centre.size()
	if _budget_exceeded(rows * cols, p_spacing):
		return

	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colours := PackedColorArray()
	var indices := PackedInt32Array()
	verts.resize(rows * cols)
	uvs.resize(rows * cols)
	colours.resize(rows * cols)

	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for r in rows:
		var c: Vector3 = centre[r]
		var tangent := _ribbon_tangent(centre, r)
		# Perpendicular in XZ. Y is deliberately not rotated into: the surface stays horizontal
		# across the channel and only its centreline descends, which is what water does.
		var side := Vector2(-tangent.y, tangent.x)
		var speed: float = _ribbon_speed[r]
		# Only the ENCODED direction is reversed, not `side` above: flipping the perpendicular
		# would swap the left and right waterlines out from under the containment test, which
		# reads them by the same sign convention.
		var flow := -tangent if flow_reverse else tangent
		var col := Color(
			flow.x * 0.5 + 0.5, flow.y * 0.5 + 0.5,
			clampf(speed / FLOW_SPEED_REF, 0.0, 1.0), 1.0)
		var half_l := _row_half(r, true)
		var half_r := _row_half(r, false)
		for k in cols:
			var t := float(k) / float(cols - 1)
			# Asymmetric: -left .. +right, so a channel cut into a slope keeps its mesh edge on
			# the waterline on BOTH sides rather than splitting the difference.
			var off := lerpf(-half_l, half_r, t)
			var x := c.x + side.x * off
			var z := c.z + side.y * off
			var i := r * cols + k
			verts[i] = Vector3(x, c.y, z)
			uvs[i] = Vector2(x, z)
			colours[i] = col
			mn = Vector2(minf(mn.x, x), minf(mn.y, z))
			mx = Vector2(maxf(mx.x, x), maxf(mx.y, z))
	for r in rows - 1:
		for k in cols - 1:
			var a := r * cols + k
			var b := a + 1
			var cc := (r + 1) * cols + k
			var d := cc + 1
			# Same winding as the pool mesher: CCW seen from above.
			indices.append_array([a, cc, b, b, cc, d])

	var normals := PackedVector3Array()
	normals.resize(verts.size())
	normals.fill(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	_poly_bounds = Rect2(mn, mx - mn)
	_cell_spacing = p_spacing
	# The cell grid is a broad phase, so it takes the WIDEST reach on the river rather than a
	# per-row one -- stamping short would lose cells that _ribbon_surface_at would then have
	# accepted, and a containment test that disagrees with itself by row is worse than a coarse one.
	_build_ribbon_cells(p_spacing, maxf(widest, half))

	_ensure_surface()
	_surface.mesh = mesh
	_apply_material()
	_apply_cull_box(mn, mx)
	_rebuild_volume()

	_last_stats["ok"] = true
	_last_stats["native"] = false # ribbon meshing is O(rows x cols); there is no native path yet
	_last_stats["vertices"] = verts.size()
	_last_stats["triangles"] = indices.size() / 3


## The centreline, sampled at uniform ARC LENGTH in this node's local space, with the per-row flow
## speed filled in alongside.
func _ribbon_centreline(p_spacing: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	_ribbon_speed = PackedFloat32Array()
	var src := _source_curve()
	if src == null or src.point_count < 2:
		return out
	var xf := _source_to_local()
	var baked := src.get_baked_points()
	if baked.size() < 2:
		return out

	var step := maxf(p_spacing, 0.25)
	var last := Vector3.INF
	for p in baked:
		var lp: Vector3 = xf * p
		if last == Vector3.INF or Vector2(lp.x - last.x, lp.z - last.z).length() >= step:
			out.append(lp)
			last = lp
	# Always keep the final point, or the river stops short of where the spline ends.
	var final_p: Vector3 = xf * baked[baked.size() - 1]
	if out.is_empty() or Vector2(final_p.x - out[out.size() - 1].x,
			final_p.z - out[out.size() - 1].z).length() > step * 0.25:
		out.append(final_p)

	# The rows still carry the BED height here -- the spline's own Y. _apply_bank_surface lifts
	# them to the water level, or falls back to fill_offset when there is no terrain to ask.
	_apply_bank_surface(out, p_spacing)

	# Flow speed per row, from the downhill gradient: steeper reaches read as rapids, and a river
	# authored on a level spline still flows at the base rate rather than not at all.
	_ribbon_speed.resize(out.size())
	for r in out.size():
		var a: Vector3 = out[maxi(r - 1, 0)]
		var b: Vector3 = out[mini(r + 1, out.size() - 1)]
		var run := Vector2(b.x - a.x, b.z - a.z).length()
		# Positive running downhill IN THE DIRECTION OF FLOW. Reversed, the descent that made a
		# reach a rapid now makes it a climb, so the sign goes with the toggle -- otherwise a
		# reversed river would speed up exactly where it should be slowing down.
		var drop: float = (b.y - a.y) if flow_reverse else (a.y - b.y)
		var grade := (drop / run) if run > 1e-4 else 0.0
		_ribbon_speed[r] = flow_speed * (1.0 + flow_slope_gain * maxf(grade, 0.0))
	return out


## Lift the centreline from the bed to the water surface, and find the waterline on each side.
##
## Called with rows still at the spline's own Y. On exit every row carries the surface height it
## will be drawn at, and _ribbon_half_l / _ribbon_half_r carry that row's waterline.
##
## THE FALLBACK MATTERS AS MUCH AS THE FEATURE. With no Pasture3D to sample -- a stream on a bare
## mesh, a headless fixture, a scene mid-load -- this returns to bed + fill_offset and leaves the
## widths empty rather than producing a flat or buried river. The water guide supports water with
## no terrain in the scene and that has to keep working.
func _apply_bank_surface(p_rows: PackedVector3Array, p_spacing: float) -> void:
	_ribbon_half_l = PackedFloat32Array()
	_ribbon_half_r = PackedFloat32Array()
	var terrain := _resolve_terrain()
	if terrain == null or p_rows.is_empty():
		for r in p_rows.size():
			var row := p_rows[r]
			row.y += fill_offset
			p_rows[r] = row
		return

	var search := _effective_bank_search()
	var n := p_rows.size()
	var surface := PackedFloat32Array()
	surface.resize(n)
	var sampled := PackedByteArray()
	sampled.resize(n)

	for r in n:
		var c: Vector3 = p_rows[r]
		var tangent := _ribbon_tangent(p_rows, r)
		var side := Vector2(-tangent.y, tangent.x)
		var world := global_transform * c
		var centre_xz := Vector2(world.x, world.z)
		var left := _bank_crest(terrain, centre_xz, side, search, p_spacing)
		var right := _bank_crest(terrain, centre_xz, -side, search, p_spacing)
		var crest := NAN
		if is_finite(left) and is_finite(right):
			# The LOWER bank decides the level: water cannot stand higher than the side it
			# would spill over.
			crest = minf(left, right)
		elif is_finite(left):
			crest = left
		elif is_finite(right):
			crest = right
		if is_finite(crest):
			# Back into this node's space, since the rows are local.
			var local_crest: float = (global_transform.affine_inverse()
					* Vector3(world.x, crest, world.z)).y
			surface[r] = local_crest - bank_height
			sampled[r] = 1
		else:
			surface[r] = c.y + fill_offset
			sampled[r] = 0

	_smooth_line(surface, bank_smoothing)

	# Never below the bed. Where the clamp bites, depth is zero and the reach is a ford -- which
	# is the point of sampling banks rather than offsetting the floor.
	for r in n:
		var row := p_rows[r]
		row.y = maxf(surface[r], row.y)
		p_rows[r] = row

	_ribbon_half_l.resize(n)
	_ribbon_half_r.resize(n)
	for r in n:
		if sampled[r] == 0:
			_ribbon_half_l[r] = ribbon_half_width
			_ribbon_half_r[r] = ribbon_half_width
			continue
		var c2: Vector3 = p_rows[r]
		var tangent2 := _ribbon_tangent(p_rows, r)
		var side2 := Vector2(-tangent2.y, tangent2.x)
		var world2 := global_transform * c2
		var centre2 := Vector2(world2.x, world2.z)
		var surf_world: float = (global_transform * Vector3(0.0, c2.y, 0.0)).y
		_ribbon_half_l[r] = _waterline_half(terrain, centre2, side2, surf_world, search, p_spacing)
		_ribbon_half_r[r] = _waterline_half(terrain, centre2, -side2, surf_world, search, p_spacing)
	_smooth_line(_ribbon_half_l, bank_smoothing)
	_smooth_line(_ribbon_half_r, bank_smoothing)


## In-place box blur along a per-row line. Endpoints are held so the river keeps starting and
## ending where the spline says it does.
func _smooth_line(p_values: PackedFloat32Array, p_passes: int) -> void:
	var n := p_values.size()
	if p_passes <= 0 or n < 3:
		return
	for _pass in p_passes:
		var prev: float = p_values[0]
		for i in range(1, n - 1):
			var cur: float = p_values[i]
			p_values[i] = (prev + cur + p_values[i + 1]) / 3.0
			prev = cur


# ---- bank sampling (the surface reference) -----------------------------------

## The Pasture3D this stream samples bank heights from, or null.
##
## Via the source brush first, because that is the terrain the channel was actually carved into
## and a scene can hold more than one. Falls back to a search so a hand-placed stream over terrain
## still works. Null is a supported answer, not a failure: water on a bare mesh with no Pasture3D
## in the scene is a case the water guide explicitly supports, and it falls back to fill_offset.
func _resolve_terrain() -> Node:
	if _terrain_cache != null and is_instance_valid(_terrain_cache) \
			and _terrain_cache.is_inside_tree():
		return _terrain_cache
	_terrain_cache = null
	var brush := _source_brush()
	if brush != null and brush.get("terrain") != null:
		var t = brush.get("terrain")
		if t != null and is_instance_valid(t):
			_terrain_cache = t
			return _terrain_cache
	if not is_inside_tree():
		return null
	# Ancestors first: a stream is normally a sibling of its brush under the Pasture3D, so this
	# finds the right terrain in one short walk and cannot pick the wrong one in a scene with
	# two. Only then fall back to a search.
	var up: Node = get_parent()
	while up != null:
		if up.is_class("Pasture3D"):
			_terrain_cache = up
			return _terrain_cache
		up = up.get_parent()
	# current_scene is null in a --script harness and during some editor transitions, so the
	# tree root is the fallback rather than the first choice.
	for root in [get_tree().current_scene, get_tree().root]:
		if root == null:
			continue
		for n in _descendants(root):
			if n.is_class("Pasture3D"):
				_terrain_cache = n
				return _terrain_cache
	return _terrain_cache


## Composited terrain height at a world XZ, or NAN when there is no terrain to ask.
func _terrain_height(p_terrain: Node, p_world_xz: Vector2) -> float:
	if p_terrain == null:
		return NAN
	var data = p_terrain.get("data")
	if data == null or not data.has_method("get_height"):
		return NAN
	var h: float = data.get_height(Vector3(p_world_xz.x, 0.0, p_world_xz.y))
	return h if is_finite(h) else NAN


## The spill height of one bank: the LOWEST terrain in the band just inside the search limit.
##
## Lowest and not highest, because water fills until it reaches the lowest edge that still holds
## it. A maximum would happily fill past a gap in the bank and flood whatever is beyond. Returns
## NAN when the terrain cannot be sampled, which the caller treats as "no bank here".
func _bank_crest(p_terrain: Node, p_world_centre: Vector2, p_side: Vector2,
		p_search: float, p_spacing: float) -> float:
	# Only the outer quarter of the span: nearer in is the bank ramp, still climbing, and its
	# height is a function of how far out we happened to look rather than of the channel.
	var from := p_search * 0.75
	var step := maxf(p_spacing, 0.5)
	var best := NAN
	var d := from
	while d <= p_search + 1e-4:
		var h := _terrain_height(p_terrain, p_world_centre + p_side * d)
		if is_finite(h) and (not is_finite(best) or h < best):
			best = h
		d += step
	return best


## Lateral distance from the centreline to where the ground rises to `p_surface_y` -- the
## waterline on this side. This is what makes the strip widen in a shallow reach and pull in
## through a gorge without anyone authoring a width curve.
##
## Floored at one grid step: a fully dry row (bed above the surface, a ford at its driest) would
## otherwise collapse to zero width and tear the triangle strip. A sliver of zero-depth water is
## something the shore foam and depth fade already know how to hide; a hole in the mesh is not.
func _waterline_half(p_terrain: Node, p_world_centre: Vector2, p_side: Vector2,
		p_surface_y: float, p_search: float, p_spacing: float) -> float:
	var step := maxf(p_spacing, 0.25)
	var d := step
	while d <= p_search:
		var h := _terrain_height(p_terrain, p_world_centre + p_side * d)
		if is_finite(h) and h >= p_surface_y:
			return maxf(d, step)
		d += step
	return maxf(p_search, step)


## How far out to look for the bank. Explicit if set, else the channel the brush carved.
func _effective_bank_search() -> float:
	if bank_search_width > 0.0:
		return bank_search_width
	var brush := _source_brush()
	if brush != null:
		var bed = brush.get("bed_half_width")
		var bank = brush.get("bank_width")
		if bed != null and bank != null:
			return maxf(float(bed) + float(bank), 1.0)
	return maxf(ribbon_half_width * 3.0, 1.0)


# ---- per-row queries ---------------------------------------------------------

## Unit XZ tangent at row `p_i`, from its neighbours. A central difference, so a bend turns smoothly
## across the rows rather than stepping at each sample -- which is what the fragment stage
## interpolates between and therefore what makes flow direction correct through a corner.
func _ribbon_tangent(p_centre: PackedVector3Array, p_i: int) -> Vector2:
	var a: Vector3 = p_centre[maxi(p_i - 1, 0)]
	var b: Vector3 = p_centre[mini(p_i + 1, p_centre.size() - 1)]
	var t := Vector2(b.x - a.x, b.z - a.z)
	if t.length_squared() < 1e-10:
		return Vector2(1.0, 0.0)
	return t.normalized()


## Stamp each grid cell over the stream's bounds with the nearest centreline row, or -1.
##
## The equivalent of the pool's inside mask, and it exists for the same reason: Phase 6 asks
## containment and height per buoy per physics tick, and scanning every row of a long river for the
## nearest is O(rows) per query. Built by walking the ROWS and stamping the cells within reach of
## each, so the build costs O(rows x reach) rather than O(cells).
func _build_ribbon_cells(p_spacing: float, p_half: float) -> void:
	var gw := int(ceil(_poly_bounds.size.x / p_spacing)) + 2
	var gh := int(ceil(_poly_bounds.size.y / p_spacing)) + 2
	_cell_gw = gw
	_cell_gh = gh
	_ribbon_cell = PackedInt32Array()
	_ribbon_cell.resize(gw * gh)
	_ribbon_cell.fill(-1)
	var reach := int(ceil((p_half + p_spacing) / p_spacing)) + 1
	for r in _ribbon_rows.size():
		var c: Vector3 = _ribbon_rows[r]
		var cx := int(floor((c.x - _poly_bounds.position.x) / p_spacing))
		var cz := int(floor((c.z - _poly_bounds.position.y) / p_spacing))
		for dz in range(-reach, reach + 1):
			var iz := cz + dz
			if iz < 0 or iz >= gh:
				continue
			for dx in range(-reach, reach + 1):
				var ix := cx + dx
				if ix < 0 or ix >= gw:
					continue
				# First-writer-wins is wrong at a bend, where a later row can be nearer. Compare.
				var idx := iz * gw + ix
				var px := _poly_bounds.position.x + (ix + 0.5) * p_spacing
				var pz := _poly_bounds.position.y + (iz + 0.5) * p_spacing
				var d := Vector2(px - c.x, pz - c.z).length_squared()
				if _ribbon_cell[idx] < 0:
					_ribbon_cell[idx] = r
				else:
					var o: Vector3 = _ribbon_rows[_ribbon_cell[idx]]
					if d < Vector2(px - o.x, pz - o.z).length_squared():
						_ribbon_cell[idx] = r


## This row's half-width on one side, in metres, including edge_offset.
##
## One accessor for the whole strip so the mesher, the containment test and the cell grid cannot
## disagree about how wide the river is at a given row -- they did once, and the symptom was a
## buoy floating beside water it was not in.
func _row_half(p_row: int, p_left: bool) -> float:
	var arr := _ribbon_half_l if p_left else _ribbon_half_r
	if p_row < 0 or p_row >= arr.size():
		return ribbon_half_width + edge_offset
	return arr[p_row] + edge_offset


## Nearest centreline row to a local XZ, or -1 when the point is nowhere near the river.
func _ribbon_nearest_row(p_local_xz: Vector2) -> int:
	if _ribbon_cell.is_empty() or _cell_spacing <= 0.0 or _ribbon_rows.is_empty():
		return -1
	var ix := int(floor((p_local_xz.x - _poly_bounds.position.x) / _cell_spacing))
	var iz := int(floor((p_local_xz.y - _poly_bounds.position.y) / _cell_spacing))
	if ix < 0 or iz < 0 or ix >= _cell_gw or iz >= _cell_gh:
		return -1
	var seed: int = _ribbon_cell[iz * _cell_gw + ix]
	if seed < 0:
		return -1
	# The cell answers to within one cell; refine over a small window so a query near a bend lands
	# on the genuinely nearest row rather than on whichever one stamped that cell.
	var best := seed
	var best_d := INF
	for r in range(maxi(seed - 3, 0), mini(seed + 4, _ribbon_rows.size())):
		var c: Vector3 = _ribbon_rows[r]
		var d := Vector2(p_local_xz.x - c.x, p_local_xz.y - c.z).length_squared()
		if d < best_d:
			best_d = d
			best = r
	return best


## Surface at a local XZ, as [is_over_the_channel, local_y].
func _ribbon_surface_at(p_local_xz: Vector2) -> Array:
	var r := _ribbon_nearest_row(p_local_xz)
	if r < 0:
		return [false, 0.0]
	var c: Vector3 = _ribbon_rows[r]
	# Lateral distance decides containment; the row's own Y is the surface. Interpolating Y between
	# rows would be smoother, but rows are one vertex_spacing apart and the drop over that is
	# millimetres on any river a person would author.
	#
	# SIGNED across the channel, because the two banks no longer agree: the waterline reaches
	# further into the shallow side. Which side a point is on is the sign of its offset along the
	# row's own perpendicular, so this asks the same question the mesher answered when it placed
	# that row's vertices.
	var offset := Vector2(p_local_xz.x - c.x, p_local_xz.y - c.z)
	var tangent := _ribbon_tangent(_ribbon_rows, r)
	var side := Vector2(-tangent.y, tangent.x)
	var lateral := offset.dot(side)
	var limit := _row_half(r, lateral < 0.0)
	return [absf(lateral) <= limit, c.y]


## The stream's centreline in local space, one point per row, as the mesh was last built from it.
## Exposed so a gate -- or a tool -- can check the surface against the same rows the node uses
## rather than a re-derived curve, which is the pool's get_polygon() for a shape that has no
## outline.
func get_centreline() -> PackedVector3Array:
	return _ribbon_rows


func _forget_surface() -> void:
	super()
	_ribbon_rows = PackedVector3Array()
	_ribbon_cell = PackedInt32Array()
	_ribbon_half_l = PackedFloat32Array()
	_ribbon_half_r = PackedFloat32Array()


# ---- inspector ---------------------------------------------------------------

func _validate_property(property: Dictionary) -> void:
	super(property)
	if property.name == "fill_offset":
		# Dead whenever the banks are being sampled: the surface comes from them and only the
		# no-terrain fallback still reads this. Greyed rather than hidden, because it IS live again
		# the moment the stream is used without a Pasture3D in the scene, and a property that
		# vanishes reads as one that was removed.
		if _resolve_terrain() != null:
			property.usage |= PROPERTY_USAGE_READ_ONLY
	elif property.name == "force_gdscript_mesh":
		# There is no native ribbon mesher to switch away from. Shown greyed rather than hidden so
		# it is clear the A/B switch exists on water bodies and simply has nothing to do here.
		property.usage |= PROPERTY_USAGE_READ_ONLY
