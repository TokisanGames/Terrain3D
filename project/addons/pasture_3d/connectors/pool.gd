# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DPool — a lake, a pond, a reservoir: still water filling a closed outline.
# See PASTURE3D_WATER_BODIES_SPEC.md §7.
#
# The node that makes "add water to this basin" one button press. It takes the loop a
# Pasture3DMound (or Pond, or Plow, or Splat) already drew, fills it with a subdivided flat
# surface, and puts a water material on it. The waves, the clock and the material all come from
# the scene's Pasture3DPoolManager, so a pond is not a special case of anything -- it is the same
# water the ocean is, over a smaller polygon.
#
# CLOSED CURVES ONLY, and that is the change the split made. This file used to switch on
# `curve.closed` at every rebuild and become a river when the answer was no; rivers are now
# Pasture3DStream, and an open curve here is a misconfiguration with a Convert to Stream button
# next to it rather than a second personality. Everything a lake and a river agree about lives in
# Pasture3DWaterBody; this class is only the part that is a filled outline.
@tool
@icon("res://addons/pasture_3d/icons/brush_terrain.svg")
class_name Pasture3DPool
extends Pasture3DWaterBody

const PRESET_PATHS := {
	0: WATER_DIR + "M_water_lake.tres",
	1: WATER_DIR + "M_water_pond.tres",
}
## The masked variant of the lake shader, swapped in for MASKED mode. See _runtime_material.
const MASKED_SHADER := WATER_DIR + "water_lake_masked.gdshader"

## How the outline becomes geometry.
##
## MESHED is what a pool has always done: a grid clipped exactly to the loop, so the waterline IS
## the polygon. It does not scale -- a 1.4 km body at lake_calm's automatic 1.27 m spacing wants
## 1.1 M vertices and the build refuses -- but below that it is the cheaper and simpler of the two,
## and on a small pond it is also the faster to rebuild.
##
## MASKED draws a sheet that does not know where the shore is and cuts it with a signed distance
## field baked from the same polygon. The drawn vertex count stops being a property of the lake,
## which is what makes a large body possible at all, and it is the step towards putting one on a
## camera-centred clipmap. Measured cost of the swap: the waterline lands 0.16 m from the outline
## against the 2 m edge_offset that buries it in the bank (bench/WaterShoreEdgeProbe.gd).
enum SurfaceMode {
	AUTO, ## MESHED when it fits max_vertices, MASKED when it does not.
	MESHED, ## Always the exactly-clipped grid.
	MASKED, ## Always the sheet plus a distance field.
}

# A group of its own, and not for tidiness: an inspector group runs until the next one, and the
# base class ends inside "Underwater" -- so an ungrouped export here would file the migration
# button under the fog settings.
@export_group("Migration")
## Turn this pool into a Pasture3DStream, in place, keeping its settings and its name.
##
## The migration path for water authored before the split, when an open curve made a
## Pasture3DPool mesh itself as a ribbon. Such a pool now draws nothing and says so; this is the
## one press that fixes it. Hidden on a closed curve, where there is nothing to convert.
@export_tool_button("Convert to Stream") var _convert_btn = convert_to_stream

# A group of its own for the same reason Migration has one: an inspector group runs until the next,
# and these would otherwise file themselves under whatever came before.
@export_group("Surface")
## Meshed grid, masked sheet, or chosen by size. See SurfaceMode.
@export var surface_mode: SurfaceMode = SurfaceMode.AUTO:
	set(v):
		surface_mode = v
		_schedule_rebuild()
		notify_property_list_changed()
		update_configuration_warnings()
## Metres per texel of the distance field. THE accuracy dial for the waterline, and steeper than
## linear: 1 m texels put the shore within 0.16 m, 4 m texels within 1.37 m. Above about 1.5 m the
## rim stops being hidden by a default edge_offset.
@export var mask_texel: float = 1.5:
	set(v):
		mask_texel = clampf(v, 0.25, 8.0)
		_schedule_rebuild()
## Metres of distance the field encodes before clamping. Must exceed the sheet's vertex kill margin
## (spacing * 1.5) or the geometric half of the cut goes inert and the sheet is trimmed by the
## fragment stage alone -- correct, but paying for fragments it could have skipped.
@export var mask_range: float = 24.0:
	set(v):
		mask_range = maxf(v, 1.0)
		_schedule_rebuild()
## Width of the alpha ramp at the waterline, in metres, centred on the outline. Zero is a hard cut
## and measurably worse -- it quantises the rim to the field's texels.
@export var mask_feather: float = 0.5:
	set(v):
		mask_feather = maxf(v, 0.0)
		_schedule_rebuild()
## Metres between sheet vertices in MASKED mode. 0 = follow vertex_spacing.
##
## Separate from vertex_spacing because the two now answer different questions. vertex_spacing is
## the WAVE sampling rate and is correctness (guide §7); this is only how finely the sheet is
## subdivided, and the waterline no longer depends on it at all -- measured bit-identical from
## 1.27 m to 10 m. Raise it to trade wave fidelity for vertices on a body that is mostly distant.
@export var mask_sheet_spacing: float = 0.0:
	set(v):
		mask_sheet_spacing = maxf(v, 0.0)
		_schedule_rebuild()
@export_group("")

## The offset loop in LOCAL XZ, as of the last rebuild. Every containment query reads this rather
## than re-deriving it; see _build_surface.
var _poly_cache := PackedVector2Array()
## The mesher's own inside mask, kept so containment is a lookup rather than a polygon walk. See
## _contains_local. Empty means "no mask, fall back to the exact test everywhere".
var _mask := PackedByteArray()
var _mask_gw := 0
var _mask_gh := 0
var _mask_spacing := 0.0

## MASKED mode's private material, and the reason it has to be private: the distance field is a
## sampler2D, and Godot's instance uniforms take scalars and vectors only. _water_domain_origin
## could become per-instance and let ten ponds share one material (see water_common.gdshaderinc);
## a texture cannot, so a masked body owns its own copy or two lakes fight over one field.
##
## The same thing Pasture3DOcean keeps for the same reason. Rebuilt whenever the resolved base
## material changes identity, so a preset swap or a profile change is not silently ignored.
var _runtime_material: ShaderMaterial = null
## Base the running duplicate was taken from, to notice when it is no longer the right base.
var _runtime_source: Material = null
## What was last built, so queries and warnings can say which path produced them.
var _masked := false
var _sdf_rect := Vector4.ZERO
var _sdf_texels := 0
## Sheet spacing the last masked build actually used, which is not mask_sheet_spacing when the
## vertex ceiling forced it coarser. Read by _shape_warnings so the trade is stated.
var _sheet_spacing_used := 0.0


# ---- the shape contract ------------------------------------------------------

func _preset_names() -> PackedStringArray:
	return PackedStringArray(["Lake", "Pond", "Custom"])


func _preset_paths() -> Dictionary:
	return PRESET_PATHS


func _has_surface() -> bool:
	return _poly_cache.size() >= 3


## Cell classification off the mesher's mask, which turns the common answer into an array
## lookup. The exact polygon walk is O(perimeter) — a few hundred edges for a lake — and Phase 6
## asks this question per buoy per physics tick, where it cost more than the wave solve did.
##
## Reading the MESHER's mask rather than a structure of its own is the point: a cell whose four
## corners are all inside is exactly a cell the mesher filled with a quad, so "contained" and
## "drawn" cannot disagree. Only cells the boundary crosses fall through to the exact test, and
## there are O(shore length) of those.
func _contains_local(p_local_xz: Vector2) -> bool:
	match _cell_state(p_local_xz):
		0:
			return false
		1:
			return true # every corner inside: the mesher drew a full quad here
	return Geometry2D.is_point_in_polygon(p_local_xz, _poly_cache)


func _shape_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	var src := _source_curve()
	if src == null:
		w.append("No source. Set source_spline to a brush's Path3D, or assign a Curve3D.")
	elif not src.closed:
		# The split's one behaviour change, so it names the class AND the button rather than
		# reporting a shape problem: water authored before it will land here, having silently
		# meshed itself as a ribbon for however long, and "3 points" would be the wrong diagnosis.
		w.append("This curve is OPEN, and a Pasture3DPool fills a CLOSED outline. An open curve "
			+ "is a river: press Convert to Stream to turn this into a Pasture3DStream, which "
			+ "follows the channel downhill and takes its surface from the banks.")
	elif src.point_count < 3:
		w.append("The source curve has fewer than 3 points, so there is no area to fill.")
	elif _local_polygon(_effective_spacing()).size() < 3:
		w.append("The source curve collapses to fewer than 3 usable points at this vertex "
			+ "spacing, so there is no area to fill.")

	# The vertex ceiling now has a way out that is not "raise the ceiling", and the build's own
	# message cannot say so because it is shared with Pasture3DStream, which has no masked path.
	if not _last_stats.is_empty() and not _last_stats.get("ok", false) \
			and str(_last_stats.get("reason", "")).contains("max_vertices") \
			and surface_mode != SurfaceMode.MASKED:
		w.append("This body is too large to mesh at its wave spacing. Set surface_mode to Masked "
			+ "(or lower mask_auto_span) to draw it as a sheet cut by a distance field, which "
			+ "makes the vertex count independent of the body's size. Raising max_vertices also "
			+ "works and costs a vertex per lattice point.")

	# A masked body whose material cannot carry the field draws an UNCUT sheet -- a square of water
	# over the whole padded bounds -- which looks like the mask silently doing nothing, because it is.
	if _masked and _runtime_material == null and material != null:
		w.append("Masked mode needs a ShaderMaterial it can copy, and this body's material is a "
			+ "%s. Assign one of the water presets, or switch surface_mode to Meshed."
			% material.get_class())
	# The sheet was coarsened past what the waves need. Not an error -- it is the alternative to
	# refusing -- but it is a visible change to the surface and the user did not ask for it.
	if _masked and _sheet_spacing_used > 0.0:
		var wanted := _sheet_spacing(_effective_spacing())
		if _sheet_spacing_used > wanted * 1.01:
			w.append(("The sheet was coarsened to %.2f m to fit max_vertices; the waves want "
				+ "%.2f m. The waterline is unaffected — it does not depend on the sheet's "
				+ "resolution — but crests within a few tens of metres of the camera will be cut "
				+ "flat. Raise max_vertices, or accept it: this is the gap the camera-centred "
				+ "clipmap closes.") % [_sheet_spacing_used, wanted])
	if mask_range <= _kill_margin(_sheet_spacing(_effective_spacing())):
		w.append(("mask_range (%.1f m) does not exceed the sheet's vertex kill margin (%.1f m), so "
			+ "no sheet vertex is ever culled and the whole sheet is trimmed by the fragment stage "
			+ "alone. Correct, but it pays for fragments it could have skipped: raise mask_range.")
			% [mask_range, _kill_margin(_sheet_spacing(_effective_spacing()))])
	return w


# ---- geometry ----------------------------------------------------------------

## The loop, in this node's LOCAL XZ, decimated to roughly the grid resolution.
## Returns an empty array when there is no usable closed curve.
func _local_polygon(p_spacing: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var src := _source_curve()
	if src == null or src.point_count < 3:
		return out
	# An OPEN curve is a river, not a lake. Filling one means closing it between its two
	# endpoints, which is a wedge the user never drew — so refuse and let the configuration
	# warning point at Pasture3DStream.
	if not src.closed:
		return out
	var to_local_xf := _source_to_local()

	var pts := src.get_baked_points()
	if pts.size() < 3:
		return out
	# The raw bake is ~0.2 m and far finer than the grid; decimating first makes the
	# scanline below O(rows x few) instead of O(rows x thousands).
	var step := maxf(p_spacing, 0.25)
	var last := Vector2.INF
	for p in pts:
		var lp: Vector3 = to_local_xf * p
		var v := Vector2(lp.x, lp.z)
		if last == Vector2.INF or last.distance_to(v) >= step:
			out.append(v)
			last = v
	if out.size() >= 2 and out[0].distance_to(out[out.size() - 1]) < step * 0.5:
		out.remove_at(out.size() - 1)
	return out


## Grown outward by edge_offset. Geometry2D returns a list because an offset can split
## or merge a polygon; the largest ring is the pool and the rest are slivers.
func _offset_polygon(p_poly: PackedVector2Array) -> PackedVector2Array:
	if is_zero_approx(edge_offset):
		return p_poly
	var rings := Geometry2D.offset_polygon(p_poly, edge_offset, Geometry2D.JOIN_MITER)
	var best := PackedVector2Array()
	var best_area := -1.0
	for r in rings:
		var a: float = absf(_polygon_area(r))
		if a > best_area:
			best_area = a
			best = r
	return best if not best.is_empty() else p_poly


func _polygon_area(p: PackedVector2Array) -> float:
	var a := 0.0
	for i in p.size():
		var q := p[(i + 1) % p.size()]
		a += p[i].x * q.y - q.x * p[i].y
	return a * 0.5


## Inside-mask over grid POINTS by scanline.
##
## Not Geometry2D.is_point_in_polygon per point: that is O(points x edges), which for a
## 500 m lake at 1.4 m spacing is 127k x ~200 = 25M operations in GDScript — seconds,
## not milliseconds. A scanline is O(rows x edges + points) and does the same job. The
## brushes reached the same conclusion for the same reason.
func _inside_mask(p_poly: PackedVector2Array, p_min: Vector2, p_spacing: float,
		p_gw: int, p_gh: int) -> PackedByteArray:
	var mask := PackedByteArray()
	mask.resize(p_gw * p_gh)
	var n := p_poly.size()
	for iz in p_gh:
		var z := p_min.y + iz * p_spacing
		var xs := PackedFloat32Array()
		for i in n:
			var a := p_poly[i]
			var b := p_poly[(i + 1) % n]
			# Half-open crossing test: a vertex exactly on the scanline counts once,
			# so spans never pair up wrongly at a horizontal tangent.
			if (a.y <= z) != (b.y <= z):
				xs.append(a.x + (z - a.y) / (b.y - a.y) * (b.x - a.x))
		if xs.is_empty():
			continue
		xs.sort()
		var row := iz * p_gw
		var k := 0
		while k + 1 < xs.size():
			var x0: float = xs[k]
			var x1: float = xs[k + 1]
			var i0 := int(ceil((x0 - p_min.x) / p_spacing))
			var i1 := int(floor((x1 - p_min.x) / p_spacing))
			for ix in range(maxi(i0, 0), mini(i1, p_gw - 1) + 1):
				mask[row + ix] = 1
			k += 2
	return mask


## Fill the loop with a flat sheet at this node's Y.
func _build_surface(p_spacing: float) -> void:
	var poly := _offset_polygon(_local_polygon(p_spacing))
	# Cache it. Every containment question — the camera poll, the Area3D re-filter, a buoy asking
	# which body it is in — needs this same polygon, and rebuilding it per query means re-baking the
	# curve, decimating it and running Geometry2D.offset_polygon several times a frame. It only
	# changes when the mesh does, so it is stored where the mesh is.
	_poly_cache = poly
	if poly.size() < 3:
		_build_failed("no usable closed curve")
		return

	# Bounds, snapped outward to the grid so the lattice is stable as the loop moves.
	var mn := poly[0]
	var mx := poly[0]
	for v in poly:
		mn = Vector2(minf(mn.x, v.x), minf(mn.y, v.y))
		mx = Vector2(maxf(mx.x, v.x), maxf(mx.y, v.y))
	mn = Vector2(floorf(mn.x / p_spacing) * p_spacing, floorf(mn.y / p_spacing) * p_spacing)
	mx = Vector2(ceilf(mx.x / p_spacing) * p_spacing, ceilf(mx.y / p_spacing) * p_spacing)
	# Local-space XZ bounds of the polygon: the broad phase for every containment query, and the
	# footprint the underwater volume spans.
	_poly_bounds = Rect2(mn, mx - mn)
	var gw := int(round((mx.x - mn.x) / p_spacing)) + 1
	var gh := int(round((mx.y - mn.y) / p_spacing)) + 1
	if gw < 2 or gh < 2:
		_build_failed("loop smaller than one grid cell")
		return

	# The mesher's inside mask, kept for containment queries (see _contains_local). Built BEFORE the
	# mode branch and at the same resolution either way, so a masked body answers is_point_underwater
	# from exactly what a meshed one would -- the surface changed, the water did not.
	if ClassDB.class_exists("Pasture3DUtil") \
			and ClassDB.class_has_method("Pasture3DUtil", "build_inside_mask", true):
		_mask = Pasture3DUtil.build_inside_mask(poly, mn, p_spacing, gw, gh)
	else:
		_mask = _inside_mask(poly, mn, p_spacing, gw, gh)
	_mask_gw = gw
	_mask_gh = gh
	_mask_spacing = p_spacing

	_masked = _wants_mask(gw * gh)
	_last_stats["masked"] = _masked
	if _masked:
		_build_masked(poly, mn, mx, p_spacing)
		return

	# The vertex ceiling is a MESHED-mode limit: it exists because that path emits a vertex per
	# interior lattice point, which is the thing that does not scale. The masked path above is
	# gated on its sheet instead, so a body that trips this has a second way out now and the
	# warning says so.
	if _budget_exceeded(gw * gh, p_spacing):
		return

	# The O(area) half. Native by default (spec §12 q1): the GDScript below is a faithful
	# transcription kept as the A/B oracle, exactly as the brushes keep force_gdscript_raster, and
	# `force_gdscript_mesh` switches between them on identical inputs.
	var mesh: ArrayMesh = null
	var native := false
	if not force_gdscript_mesh and ClassDB.class_exists("Pasture3DUtil") \
			and ClassDB.class_has_method("Pasture3DUtil", "build_pool_mesh", true):
		mesh = Pasture3DUtil.build_pool_mesh(poly, mn, p_spacing, gw, gh)
		native = mesh != null
	if not native:
		mesh = _build_mesh_gdscript(poly, mn, p_spacing, gw, gh, _mask)
	_last_stats["native"] = native
	if mesh == null:
		_build_failed("no cells inside the loop")
		return

	_ensure_surface()
	_surface.mesh = mesh
	_apply_material()
	_apply_cull_box(mn, mx)
	# The volume spans the polygon, so it is derived from the same build rather than tracked.
	_rebuild_volume()

	var counted := _count_mesh(mesh)
	_last_stats["ok"] = true
	_last_stats["vertices"] = counted.x
	_last_stats["triangles"] = counted.y


## Which path this build takes.
##
## AUTO masks a body ONLY when the meshed path will not fit, and that is a compatibility decision
## rather than a performance one. A size threshold was the first version, and at any threshold worth
## having it silently re-drew every large lake in an existing project: the rim moves a fraction of a
## metre, the body starts owning a material, the vertex count changes. Bodies that currently draw
## NOTHING are the only ones with nothing to lose, and they are exactly the ones over the ceiling --
## so those switch and the rest are untouched.
func _wants_mask(p_needed_vertices: int) -> bool:
	match surface_mode:
		SurfaceMode.MESHED:
			return false
		SurfaceMode.MASKED:
			return true
	return p_needed_vertices > max_vertices


## Metres between sheet vertices in MASKED mode.
func _sheet_spacing(p_wave_spacing: float) -> float:
	return mask_sheet_spacing if mask_sheet_spacing > 0.0 else p_wave_spacing


## How far outside a sheet vertex may be before its triangles are killed.
##
## The cell diagonal plus the half-feather that hangs past the outline. Anything less and the
## geometric cut eats into the band the fragment stage is there to resolve, which shows up as
## notches in the shore rather than as a performance difference.
func _kill_margin(p_sheet_spacing: float) -> float:
	return p_sheet_spacing * 1.5 + mask_feather


## Fill the loop by cutting an unaware sheet with a distance field.
##
## The sheet spans the outline plus a margin, and the margin is not cosmetic: the field is sampled
## with the UV clamped, so the border texel is what a vertex past the bake reads. Padding by more
## than mask_range means that border value is "well outside", and the sheet ends there instead of
## smearing the last texel outward forever.
func _build_masked(p_poly: PackedVector2Array, p_min: Vector2, p_max: Vector2,
		p_wave_spacing: float) -> void:
	if not (ClassDB.class_exists("Pasture3DUtil")
			and ClassDB.class_has_method("Pasture3DUtil", "build_shore_sdf", true)):
		_build_failed("the masked surface needs Pasture3DUtil.build_shore_sdf, which this build "
			+ "of the extension does not have — rebuild it, or set surface_mode to Meshed")
		return

	# THE SHEET AND THE FIELD ARE PADDED FOR DIFFERENT REASONS, and conflating them was a real bug:
	#
	#   the sheet only has to reach far enough past the outline that every triangle touching the
	#   shore survives the vertex kill, which is the kill margin and a couple of metres;
	#
	#   the FIELD has to be padded by mask_range, because the UV is clamped and the border texel is
	#   what a vertex past the bake reads -- pad it by less and that value is not "well outside" and
	#   the sheet never ends.
	#
	# An earlier draft padded the sheet by the field's range, which made it 60% wider than it needed
	# to be and, worse, pushed its geometry outside the cull box below.
	var spacing := _sheet_spacing(p_wave_spacing)
	var sheet := _pad(p_min, p_max, _kill_margin(spacing) + spacing)
	var nx := int(ceil(sheet.size.x / spacing)) + 1
	var nz := int(ceil(sheet.size.y / spacing)) + 1

	# COARSEN RATHER THAN REFUSE. The sheet spans the whole body, so at the wave spacing it costs
	# MORE vertices than the meshed path did -- which is why a masked sheet on its own is not the
	# answer to a large lake, and the camera-centred clipmap is. Until that lands, a body over the
	# ceiling gets a coarser sheet instead of no surface at all: the waterline does not depend on
	# the sheet's resolution (measured bit-identical from 1.27 m to 10 m), so what is being spent
	# is wave fidelity, and _shape_warnings says so rather than leaving it to be discovered.
	#
	# Doubling, not solving: it keeps the sheet on the wave lattice and matches how the clipmap's
	# rings will be spaced, so the coarsened sheet is a subset of the eventual LOD0 grid.
	while nx * nz > max_vertices and spacing < 512.0:
		spacing *= 2.0
		sheet = _pad(p_min, p_max, _kill_margin(spacing) + spacing)
		nx = int(ceil(sheet.size.x / spacing)) + 1
		nz = int(ceil(sheet.size.y / spacing)) + 1
	_sheet_spacing_used = spacing
	if _budget_exceeded(nx * nz, spacing):
		return

	# Square, because build_shore_sdf takes one texel count, and centred on the sheet so it covers
	# every corner of it.
	var field_extent: float = maxf(sheet.size.x, sheet.size.y) + (mask_range + mask_texel * 2.0) * 2.0
	var field_min: Vector2 = sheet.get_center() - Vector2(field_extent, field_extent) * 0.5
	var texels := int(ceil(field_extent / mask_texel))
	var sdf: Image = Pasture3DUtil.build_shore_sdf(p_poly, field_min, mask_texel, texels,
		mask_range, 2, true)
	if sdf == null:
		_build_failed("the distance field could not be baked")
		return
	_sdf_rect = Vector4(field_min.x, field_min.y, texels * mask_texel, texels * mask_texel)
	_sdf_texels = texels

	_ensure_surface()
	_surface.mesh = _build_sheet_mesh(sheet.position, nx, nz, spacing)
	_apply_material()
	_apply_shore_uniforms(ImageTexture.create_from_image(sdf), spacing)
	# THE DRAWN SHEET's bounds, not the outline's.
	#
	# The vertex kill runs on the GPU, so the CPU submitting this mesh has no idea that most of it
	# will be discarded. The first version of this box was drawn around the OUTLINE -- reasoning
	# that the rest was killed geometry anyway -- and the sheet is wider than the outline by
	# construction, so the box never contained what was being drawn and the lake rendered as
	# nothing at all. Taken from the vertex counts rather than from `sheet`, because nx and nz
	# round up and the last row sits a fraction of a cell past sheet.end.
	_apply_cull_box(sheet.position,
		sheet.position + Vector2(float(nx - 1) * spacing, float(nz - 1) * spacing))
	_rebuild_volume()

	var counted := _count_mesh(_surface.mesh)
	_last_stats["ok"] = true
	_last_stats["native"] = true
	_last_stats["vertices"] = counted.x
	_last_stats["triangles"] = counted.y
	_last_stats["sheet_spacing"] = spacing
	_last_stats["sdf_texels"] = texels
	_last_stats["sdf_bytes"] = texels * texels * 2


## A rect covering p_min..p_max grown by p_by on every side.
func _pad(p_min: Vector2, p_max: Vector2, p_by: float) -> Rect2:
	var lo := p_min - Vector2(p_by, p_by)
	return Rect2(lo, (p_max + Vector2(p_by, p_by)) - lo)


## A plain sheet, nx by nz vertices from p_origin. Knows nothing about the outline; that is the point.
##
## Takes the counts rather than deriving them from a rect, so the caller's cull box and this mesh
## cannot disagree about where the last row is.
func _build_sheet_mesh(p_origin: Vector2, nx: int, nz: int, p_spacing: float) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	verts.resize(nx * nz)
	uvs.resize(nx * nz)
	for iz in nz:
		for ix in nx:
			var x := p_origin.x + ix * p_spacing
			var z := p_origin.y + iz * p_spacing
			verts[iz * nx + ix] = Vector3(x, 0.0, z)
			# World XZ, matching the meshed path: the detail and foam layers are scaled in world
			# units, so a sheet with 0-1 UVs would texture at a different rate than a meshed body
			# of the same size and the two would not look like the same water.
			uvs[iz * nx + ix] = Vector2(x, z)
	for iz in nz - 1:
		for ix in nx - 1:
			var a := iz * nx + ix
			idx.append_array([a, a + nx, a + 1, a + 1, a + nx, a + nx + 1])
	var normals := PackedVector3Array()
	normals.resize(verts.size())
	normals.fill(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	arrays[Mesh.ARRAY_COLOR] = _neutral_colours(verts.size())
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Write the field and its framing onto this body's own material.
func _apply_shore_uniforms(p_texture: Texture2D, p_sheet_spacing: float) -> void:
	if _runtime_material == null:
		return
	_runtime_material.set_shader_parameter("_shore_sdf", p_texture)
	_runtime_material.set_shader_parameter("_shore_rect", _sdf_rect)
	_runtime_material.set_shader_parameter("_shore_texels",
		Vector2(_sdf_texels, _sdf_texels))
	_runtime_material.set_shader_parameter("_shore_range", mask_range)
	_runtime_material.set_shader_parameter("_shore_feather", mask_feather)
	# edge_offset is GEOMETRY on the meshed path -- the polygon is grown before it is meshed -- and
	# it stays that way here, because _build_surface offsets the loop before the field is baked from
	# it. So this is zero, not edge_offset: adding it again would apply the same rim twice.
	_runtime_material.set_shader_parameter("_shore_offset", 0.0)
	_runtime_material.set_shader_parameter("_shore_kill_margin",
		_kill_margin(p_sheet_spacing))


## Extended for MASKED mode: the shared material the base class resolves cannot carry this body's
## field, so a private duplicate is put in front of it.
##
## super() FIRST and unconditionally, so the resolution logic -- the manager's per-(material,
## profile) cache, the wave-table upload, the domain origin -- stays in one place and this only
## decides what finally lands on the surface.
func _apply_material() -> void:
	super()
	if _surface == null or not is_instance_valid(_surface):
		return
	if not _masked:
		# Dropped rather than kept: a body switched back to MESHED that held a stale duplicate
		# would keep drawing through it, mask and all, and the mode dial would look broken.
		_runtime_material = null
		_runtime_source = null
		return
	var resolved := _surface.material_override
	if resolved == null:
		return
	if _runtime_material == null or _runtime_source != resolved:
		_runtime_material = _masked_material(resolved)
		_runtime_source = resolved
	if _runtime_material != null:
		_surface.material_override = _runtime_material
		update_configuration_warnings()


## This body's own copy of the resolved material, on a shader that declares the shore uniforms.
##
## The parameters are carried across EXPLICITLY rather than trusted to survive assigning a new
## shader to a duplicate. The one that matters is `_waves`: the manager uploads the profile's table
## into the resolved material, and a duplicate that lost it falls back to the shader's compile-time
## table -- which is not obviously broken, it is a lake with slightly wrong waves whose CPU height
## query no longer matches what is drawn.
func _masked_material(p_base: Material) -> ShaderMaterial:
	var src := p_base as ShaderMaterial
	if src == null or src.shader == null:
		return null
	var dup: ShaderMaterial = src.duplicate()
	if _shader_has_shore(src.shader):
		return dup # the user already supplied a masked shader; leave it alone
	var masked: Shader = load(MASKED_SHADER)
	if masked == null:
		return null
	var carried := {}
	for u in src.shader.get_shader_uniform_list(true):
		var nm: String = str(u.get("name", ""))
		if nm == "":
			continue
		var v = src.get_shader_parameter(nm)
		if v != null:
			carried[nm] = v
	dup.shader = masked
	for nm in carried:
		dup.set_shader_parameter(nm, carried[nm])
	return dup


## Does this shader declare the shore mask at all? Asked of the SHADER rather than assumed from its
## path, for the reason Pasture3DOcean stopped guessing its wave count from a filename.
func _shader_has_shore(p_shader: Shader) -> bool:
	if p_shader == null:
		return false
	for u in p_shader.get_shader_uniform_list(true):
		if str(u.get("name", "")) == "_shore_sdf":
			return true
	return false


## The GDScript mesher: the A/B oracle for Pasture3DUtil.build_pool_mesh.
##
## Kept deliberately, and kept identical in structure to the C++ port, so a suspected meshing bug can
## be bisected by flipping one export rather than by rebuilding the extension. Returns null when the
## loop encloses no cells.
func _build_mesh_gdscript(poly: PackedVector2Array, mn: Vector2, spacing: float,
		gw: int, gh: int, mask: PackedByteArray) -> ArrayMesh:

	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	# Interior grid points are shared between the (up to) four cells that touch them.
	# Boundary triangles get their own vertices: they do not land on the lattice.
	var vert_of := {}

	for iz in gh - 1:
		for ix in gw - 1:
			var c00: int = mask[iz * gw + ix]
			var c10: int = mask[iz * gw + ix + 1]
			var c01: int = mask[(iz + 1) * gw + ix]
			var c11: int = mask[(iz + 1) * gw + ix + 1]
			var n_in := c00 + c10 + c01 + c11
			if n_in == 0:
				continue
			if n_in == 4:
				var a := _grid_vert(vert_of, verts, uvs, ix, iz, mn, spacing, gw)
				var b := _grid_vert(vert_of, verts, uvs, ix + 1, iz, mn, spacing, gw)
				var c := _grid_vert(vert_of, verts, uvs, ix, iz + 1, mn, spacing, gw)
				var d := _grid_vert(vert_of, verts, uvs, ix + 1, iz + 1, mn, spacing, gw)
				# CCW seen from above (+Y up, -Z forward).
				indices.append_array([a, c, b, b, c, d])
				continue
			# Partial cell: clip the square against the loop and fan the remainder.
			# Only ~perimeter/spacing cells reach here, so the expensive path is
			# bounded by the shore length rather than by the area.
			var x0 := mn.x + ix * spacing
			var z0 := mn.y + iz * spacing
			var cell := PackedVector2Array([
				Vector2(x0, z0), Vector2(x0 + spacing, z0),
				Vector2(x0 + spacing, z0 + spacing), Vector2(x0, z0 + spacing)])
			for piece in Geometry2D.intersect_polygons(cell, poly):
				if piece.size() < 3:
					continue
				var tri := Geometry2D.triangulate_polygon(piece)
				for i in range(0, tri.size(), 3):
					for j in range(3):
						var p: Vector2 = piece[tri[i + j]]
						indices.append(verts.size())
						verts.append(Vector3(p.x, 0.0, p.y))
						uvs.append(p)

	if verts.is_empty() or indices.is_empty():
		return null

	var normals := PackedVector3Array()
	normals.resize(verts.size())
	normals.fill(Vector3.UP)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	arrays[Mesh.ARRAY_COLOR] = _neutral_colours(verts.size())
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _grid_vert(p_map: Dictionary, p_verts: PackedVector3Array, p_uvs: PackedVector2Array,
		p_ix: int, p_iz: int, p_min: Vector2, p_spacing: float, p_gw: int) -> int:
	var key := p_iz * p_gw + p_ix
	if p_map.has(key):
		return p_map[key]
	var x := p_min.x + p_ix * p_spacing
	var z := p_min.y + p_iz * p_spacing
	var idx := p_verts.size()
	p_verts.append(Vector3(x, 0.0, z))
	p_uvs.append(Vector2(x, z))
	p_map[key] = idx
	return idx


## 0 = no corner of this cell is inside the loop, 1 = all four are, 2 = mixed (or no mask).
func _cell_state(p_local_xz: Vector2) -> int:
	if _mask.is_empty() or _mask_spacing <= 0.0:
		return 2
	var ix := int(floor((p_local_xz.x - _poly_bounds.position.x) / _mask_spacing))
	var iz := int(floor((p_local_xz.y - _poly_bounds.position.y) / _mask_spacing))
	if ix < 0 or iz < 0 or ix >= _mask_gw - 1 or iz >= _mask_gh - 1:
		return 2 # on the grid's outer edge; let the exact test decide
	var n := int(_mask[iz * _mask_gw + ix]) + int(_mask[iz * _mask_gw + ix + 1]) \
		+ int(_mask[(iz + 1) * _mask_gw + ix]) + int(_mask[(iz + 1) * _mask_gw + ix + 1])
	if n == 0:
		return 0
	return 1 if n == 4 else 2


## The pool's outline in local XZ, as the mesh was last built from it. Exposed so a gate — or a
## tool — can check containment against the same polygon the node uses rather than a re-derived one.
func get_polygon() -> PackedVector2Array:
	return _poly_cache


func _forget_surface() -> void:
	super()
	_poly_cache = PackedVector2Array()
	_mask = PackedByteArray()
	# The field goes too. A failed build that kept it would leave the surface cut to an outline
	# that no longer exists, which is the rendering half of the bug _build_failed exists to prevent.
	_runtime_material = null
	_runtime_source = null
	_masked = false
	_sdf_rect = Vector4.ZERO
	_sdf_texels = 0
	_sheet_spacing_used = 0.0


# ---- migration ---------------------------------------------------------------

## Replace this pool with an equivalent Pasture3DStream, in the same place in the scene.
##
## Before the split, a Pasture3DPool with an open curve meshed itself as a ribbon; scenes authored
## then hold rivers that are Pasture3DPool nodes, and after the split those build nothing. One
## press converts one. Returns the new node, or null when there was nothing to do.
##
## Deliberately NOT automatic. Swapping a node's class rewrites the scene, and doing that behind
## the user's back on load -- before they have seen the warning, saved anything, or had a chance to
## undo -- is how a migration turns into a bug report about a scene that changed on its own. The
## warning explains, the button acts.
func convert_to_stream() -> Node:
	var src := _source_curve()
	if src != null and src.closed:
		push_warning(("Pasture3DPool '%s': this curve is closed, so it is already a lake. "
			+ "Convert to Stream is for water whose curve is open.") % name)
		return null
	var parent := get_parent()
	if parent == null:
		push_warning("Pasture3DPool '%s': nothing to convert into — it has no parent." % name)
		return null

	var script: GDScript = load("res://addons/pasture_3d/connectors/stream.gd")
	if script == null:
		push_error("Pasture3D: could not load stream.gd — cannot convert.")
		return null
	var stream: Node3D = script.new()
	stream.name = name
	stream.transform = transform
	# The preset FIRST and the material last: setting water_preset loads whatever preset it names,
	# so the other order would quietly overwrite a material the user had tuned.
	stream.water_preset = stream._custom_preset()
	for p in ["source_spline", "curve", "edge_offset", "fill_offset", "max_vertices",
			"vertex_spacing", "force_gdscript_mesh", "wave_profile", "manager",
			"underwater_enabled", "volume_depth", "underwater_fog", "underwater_density_scale",
			"underwater_overlay", "overlay_canvas_layer", "overlay_transition"]:
		stream.set(p, get(p))
	stream.material = material

	var idx := get_index()
	var scene_owner := owner
	var ur := _editor_undo()
	if ur != null:
		ur.create_action("Convert %s to Pasture3DStream" % name)
		ur.add_do_method(self, "_apply_convert", stream, parent, idx, scene_owner)
		ur.add_undo_method(self, "_revert_convert", stream, parent, idx, scene_owner)
		ur.add_do_reference(stream)
		ur.add_undo_reference(self)
		ur.commit_action()
	else:
		_apply_convert(stream, parent, idx, scene_owner)
	return stream


## Put the stream in and take the pool out. Both nodes stay alive -- the undo action holds
## whichever one is outside -- so undo and redo move the SAME two instances rather than rebuilding.
func _apply_convert(p_stream: Node, p_parent: Node, p_index: int, p_owner: Node) -> void:
	if not is_instance_valid(p_stream) or not is_instance_valid(p_parent):
		return
	if get_parent() == p_parent:
		p_parent.remove_child(self)
	if p_stream.get_parent() == null:
		p_parent.add_child(p_stream)
		p_parent.move_child(p_stream, mini(p_index, p_parent.get_child_count() - 1))
		p_stream.owner = p_owner
	if Engine.is_editor_hint():
		var sel := EditorInterface.get_selection()
		sel.clear()
		sel.add_node(p_stream)


func _revert_convert(p_stream: Node, p_parent: Node, p_index: int, p_owner: Node) -> void:
	if is_instance_valid(p_stream) and p_stream.get_parent() == p_parent:
		p_parent.remove_child(p_stream)
	if get_parent() == null and is_instance_valid(p_parent):
		p_parent.add_child(self)
		p_parent.move_child(self, mini(p_index, p_parent.get_child_count() - 1))
		owner = p_owner


## The editor's undo manager, or null outside the editor -- a headless run, or a script driving the
## conversion. Same accessor Pasture3DTerrainBrush uses, and the null case is why _apply_convert is
## one method with an explicit inverse rather than a pile of do-steps: it has to be callable, and
## therefore testable, without an editor.
func _editor_undo() -> EditorUndoRedoManager:
	if not Engine.is_editor_hint():
		return null
	return EditorInterface.get_editor_undo_redo()


# ---- inspector ---------------------------------------------------------------

func _validate_property(property: Dictionary) -> void:
	super(property)
	# The mask dials are dead in MESHED mode. Shown greyed rather than hidden: a property that
	# vanishes reads as one that went missing, and these are the knobs the size warning points at.
	if property.name.begins_with("mask_") and surface_mode == SurfaceMode.MESHED:
		property.usage = PROPERTY_USAGE_NO_EDITOR | PROPERTY_USAGE_READ_ONLY
	if property.name == "_convert_btn":
		# Only on the water this is a migration FOR. A Convert to Stream button on every lake in
		# the project would be an invitation to break one.
		var src := _source_curve()
		if src == null or src.closed:
			property.usage = PROPERTY_USAGE_NONE
