# Pasture3D Water — shore SDF baking and scoring. PROTOTYPE support code.
#
# Shared by the shore probes so they measure the same field with the same instrument.
# A plain script rather than a class_name: this is prototype scaffolding for three bench
# scenes and has no business in the project-wide type namespace. Load it with
#   const SDF := preload("res://bench/shore_sdf.gd")
# and call the statics.
#
# TWO BAKERS, and the difference is the whole point of the rebuild probe:
#
#   bake(..., banded = false)  exact distance to the polygon for EVERY texel. O(texels x
#                              segments). Simple enough to be obviously right, which is
#                              what makes it the oracle -- and far too slow to ship: a
#                              1.4 km lake at 1.5 m texels is 870 k texels against ~800
#                              segments, which is 700 M operations in GDScript.
#
#   bake(..., banded = true)   exact distance only within a few texels of the boundary,
#                              where the feather lives and sub-texel accuracy is the whole
#                              product; a chamfer sweep for the rest, where nothing reads
#                              the value except the vertex kill's threshold comparison.
#                              O(shore) + O(texels), no segments in the inner loop.
#
# The banded one is only worth having if it is INDISTINGUISHABLE from the oracle at the
# waterline. That is a criterion in the rebuild probe, not an assumption here.
extends RefCounted


## Inside-test over grid POINTS. Native scanline when the extension is loaded, with a
## GDScript transcription behind it so a run without the DLL measures the same truth.
static func inside_mask(p_poly: PackedVector2Array, p_origin: Vector2, p_spacing: float,
		p_gw: int, p_gh: int) -> PackedByteArray:
	if ClassDB.class_exists("Pasture3DUtil") \
			and ClassDB.class_has_method("Pasture3DUtil", "build_inside_mask", true):
		return Pasture3DUtil.build_inside_mask(p_poly, p_origin, p_spacing, p_gw, p_gh)
	var mask := PackedByteArray()
	mask.resize(p_gw * p_gh)
	var n := p_poly.size()
	for iz in p_gh:
		var z := p_origin.y + iz * p_spacing
		var xs := PackedFloat32Array()
		for i in n:
			var a := p_poly[i]
			var b := p_poly[(i + 1) % n]
			if (a.y <= z) != (b.y <= z):
				xs.append(a.x + (z - a.y) / (b.y - a.y) * (b.x - a.x))
		if xs.is_empty():
			continue
		xs.sort()
		var row := iz * p_gw
		var k := 0
		while k + 1 < xs.size():
			var i0 := int(ceil((xs[k] - p_origin.x) / p_spacing))
			var i1 := int(floor((xs[k + 1] - p_origin.x) / p_spacing))
			for ix in range(maxi(i0, 0), mini(i1, p_gw - 1) + 1):
				mask[row + ix] = 1
			k += 2
	return mask


## A uniform-grid index over the outline's segments, so a near-shore texel tests five
## segments instead of eight hundred.
static func _segment_index(p_poly: PackedVector2Array, p_cell: float) -> Dictionary:
	var idx := {}
	var n := p_poly.size()
	for i in n:
		var a := p_poly[i]
		var b := p_poly[(i + 1) % n]
		var x0 := int(floor(minf(a.x, b.x) / p_cell))
		var x1 := int(floor(maxf(a.x, b.x) / p_cell))
		var y0 := int(floor(minf(a.y, b.y) / p_cell))
		var y1 := int(floor(maxf(a.y, b.y) / p_cell))
		for cy in range(y0, y1 + 1):
			for cx in range(x0, x1 + 1):
				var key := Vector2i(cx, cy)
				if not idx.has(key):
					idx[key] = PackedInt32Array()
				idx[key].append(i)
	return idx


## Exact distance from a point to the outline, using the index.
##
## Widens the search a ring at a time and stops as soon as the best distance found is
## within the radius the search has actually covered. A k-ring around the point's own cell
## is guaranteed to contain everything closer than k * cell -- the point sits somewhere
## inside its cell, so the nearest unexamined ground is at least k cells away on every
## side -- so accepting at that bound is exact and not an approximation.
static func _exact_distance(p: Vector2, p_poly: PackedVector2Array, p_idx: Dictionary,
		p_cell: float) -> float:
	var cx := int(floor(p.x / p_cell))
	var cy := int(floor(p.y / p_cell))
	var best := INF
	var k := 1
	while k <= 64:
		for gy in range(cy - k, cy + k + 1):
			for gx in range(cx - k, cx + k + 1):
				# Only the newly added ring; the interior was covered by a smaller k.
				if k > 1 and absi(gx - cx) < k and absi(gy - cy) < k:
					continue
				var cell: PackedInt32Array = p_idx.get(Vector2i(gx, gy), PackedInt32Array())
				for i in cell:
					var d: float = p.distance_squared_to(
						Geometry2D.get_closest_point_to_segment(
							p, p_poly[i], p_poly[(i + 1) % p_poly.size()]))
					if d < best:
						best = d
		if best <= float(k * k) * p_cell * p_cell:
			return sqrt(best)
		k += 1
	# Nothing within 64 cells. Only reachable for a point far outside every segment, where
	# the value is clamped anyway -- return what was found rather than pretending.
	return sqrt(best) if best < INF else 1e9


## Encode a signed distance the way water_common.gdshaderinc decodes it.
##
## LINEAR by default, matching the shader's default branch. The sqrt variant is reachable only
## because it is the control that must fail: interpolating in sqrt space and squaring afterwards is
## not interpolating the distance, and it measured nearly twice as bad. Kept as one function so
## these two bakers and the C++ one cannot drift into three conventions, which would show up as a
## waterline in the wrong place and be blamed on the geometry.
static func encode(p_signed_d: float, p_range: float, p_sqrt: bool) -> float:
	if not p_sqrt:
		return clampf(p_signed_d / p_range * 0.5 + 0.5, 0.0, 1.0)
	var mag := sqrt(minf(absf(p_signed_d) / p_range, 1.0))
	return clampf((-mag if p_signed_d < 0.0 else mag) * 0.5 + 0.5, 0.0, 1.0)


## Bake the outline into a signed distance texture. Negative inside.
##
## Returns the texture plus everything the shader needs to map world XZ through it, and the
## timings the rebuild probe reads.
static func bake(p_poly: PackedVector2Array, p_view_min: Vector2, p_view_size: float,
		p_texel: float, p_format: int, p_range: float,
		p_banded: bool = true, p_exact_band: int = 2, p_sqrt: bool = false) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var n := int(ceil(p_view_size / p_texel))
	var origin := p_view_min + Vector2(0.5, 0.5) * p_texel
	var inside := inside_mask(p_poly, origin, p_texel, n, n)
	var t_mask := Time.get_ticks_usec()

	var dist := PackedFloat32Array()
	dist.resize(n * n)
	var exact_count := 0

	if not p_banded:
		# The oracle. Every texel against every segment.
		var seg := p_poly.size()
		for iy in n:
			var wz := origin.y + iy * p_texel
			for ix in n:
				var p := Vector2(origin.x + ix * p_texel, wz)
				var best := INF
				for i in seg:
					var d: float = p.distance_squared_to(
						Geometry2D.get_closest_point_to_segment(
							p, p_poly[i], p_poly[(i + 1) % seg]))
					if d < best:
						best = d
				dist[iy * n + ix] = sqrt(best)
		exact_count = n * n
	else:
		dist.fill(INF)
		var cell: float = maxf(p_texel * 8.0, 8.0)
		var idx := _segment_index(p_poly, cell)
		# Texels the boundary passes between. Everything within p_exact_band of one of
		# these gets the real distance; the chamfer below fills in from them.
		var band := PackedInt32Array()
		for iy in n:
			for ix in n:
				var here := inside[iy * n + ix]
				var edge := false
				if ix + 1 < n and inside[iy * n + ix + 1] != here:
					edge = true
				elif iy + 1 < n and inside[(iy + 1) * n + ix] != here:
					edge = true
				if edge:
					band.append(iy * n + ix)
		var seen := {}
		for b in band:
			var by := b / n
			var bx := b % n
			for oy in range(maxi(by - p_exact_band, 0), mini(by + p_exact_band, n - 1) + 1):
				for ox in range(maxi(bx - p_exact_band, 0), mini(bx + p_exact_band, n - 1) + 1):
					var k := oy * n + ox
					if seen.has(k):
						continue
					seen[k] = true
					dist[k] = _exact_distance(
						Vector2(origin.x + ox * p_texel, origin.y + oy * p_texel),
						p_poly, idx, cell)
		exact_count = seen.size()

		# Chamfer sweep, seeded from the exact band. Two passes over the grid with the
		# 3-4 style neighbourhood, scaled to metres. Its error is a few percent of the
		# distance, which matters nowhere: past the band the only consumer is the vertex
		# kill comparing against a threshold metres away from anything it decides.
		var d_ortho := p_texel
		var d_diag := p_texel * 1.41421356
		for iy in n:
			for ix in n:
				var i := iy * n + ix
				var v := dist[i]
				if iy > 0:
					v = minf(v, dist[i - n] + d_ortho)
					if ix > 0:
						v = minf(v, dist[i - n - 1] + d_diag)
					if ix + 1 < n:
						v = minf(v, dist[i - n + 1] + d_diag)
				if ix > 0:
					v = minf(v, dist[i - 1] + d_ortho)
				dist[i] = v
		for iy in range(n - 1, -1, -1):
			for ix in range(n - 1, -1, -1):
				var i := iy * n + ix
				var v := dist[i]
				if iy + 1 < n:
					v = minf(v, dist[i + n] + d_ortho)
					if ix > 0:
						v = minf(v, dist[i + n - 1] + d_diag)
					if ix + 1 < n:
						v = minf(v, dist[i + n + 1] + d_diag)
				if ix + 1 < n:
					v = minf(v, dist[i + 1] + d_ortho)
				dist[i] = v

	var t_dist := Time.get_ticks_usec()

	var img := Image.create(n, n, false, p_format)
	for iy in n:
		for ix in n:
			var i := iy * n + ix
			var signed_d: float = dist[i] * (-1.0 if inside[i] == 1 else 1.0)
			img.set_pixel(ix, iy, Color(encode(signed_d, p_range, p_sqrt), 0.0, 0.0))

	var bytes := n * n * (1 if p_format == Image.FORMAT_R8 else 4)
	return {
		"texture": ImageTexture.create_from_image(img),
		"image": img,
		"texels": n,
		"texel_size": p_texel,
		"range": p_range,
		"banded": p_banded,
		"sqrt": p_sqrt,
		"exact_texels": exact_count,
		"format": "R8" if p_format == Image.FORMAT_R8 else "RF",
		"bytes": bytes,
		# Size is texels x texel size and NOT the view size, so texel centres land on
		# (i + 0.5) / n in UV and the bake and the sampler agree about where a texel is.
		"rect": Vector4(p_view_min.x, p_view_min.y, n * p_texel, n * p_texel),
		"ms": float(Time.get_ticks_usec() - t0) / 1000.0,
		"ms_mask": float(t_mask - t0) / 1000.0,
		"ms_dist": float(t_dist - t_mask) / 1000.0,
		"ms_encode": float(Time.get_ticks_usec() - t_dist) / 1000.0,
	}


## The C++ baker, wrapped to return the same dictionary the GDScript ones do.
##
## Same shape on purpose: a probe can put this and bake() through identical code and compare the
## rendered waterlines, which is the only check that catches a port that is fast and wrong.
static func bake_native(p_poly: PackedVector2Array, p_view_min: Vector2, p_view_size: float,
		p_texel: float, p_range: float, p_exact_band: int = 2, p_half_float: bool = true,
		p_sqrt: bool = false) -> Dictionary:
	if not (ClassDB.class_exists("Pasture3DUtil")
			and ClassDB.class_has_method("Pasture3DUtil", "build_shore_sdf", true)):
		return {}
	var t0 := Time.get_ticks_usec()
	var n := int(ceil(p_view_size / p_texel))
	var img: Image = Pasture3DUtil.build_shore_sdf(p_poly, p_view_min, p_texel, n, p_range,
		p_exact_band, p_half_float, p_sqrt)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	if img == null:
		return {}
	return {
		"texture": ImageTexture.create_from_image(img),
		"image": img,
		"texels": n,
		"texel_size": p_texel,
		"range": p_range,
		"banded": true,
		"sqrt": p_sqrt,
		"native": true,
		"exact_texels": -1, # not reported across the binding
		"format": "R8",
		"bytes": n * n,
		"rect": Vector4(p_view_min.x, p_view_min.y, n * p_texel, n * p_texel),
		"ms": ms, "ms_mask": 0.0, "ms_dist": ms, "ms_encode": 0.0,
	}


## Distance, in metres, from each pixel where a render and the truth disagree to the true
## outline -- which is exactly how far the waterline moved at that point.
##
## Distances are computed only for disagreeing pixels. They are all within a pixel or two
## of the boundary by construction, so this is O(shore length) and not O(area), and it is
## also why an exact-clip reference can score near zero rather than near the pixel size.
static func score(p_img: Image, p_truth: PackedByteArray, p_poly: PackedVector2Array,
		p_view_min: Vector2, p_mpp: float, p_size: int, p_truth_area: int) -> Dictionary:
	var covered_total := 0
	var errs := PackedFloat32Array()
	var seg := p_poly.size()
	var spill := 0.0
	var shortfall := 0.0
	for y in p_size:
		for x in p_size:
			var covered := p_img.get_pixel(x, y).r > 0.5
			if covered:
				covered_total += 1
			if covered == (p_truth[y * p_size + x] == 1):
				continue
			var p := p_view_min + Vector2(x + 0.5, y + 0.5) * p_mpp
			var best := INF
			for i in seg:
				var d: float = p.distance_squared_to(Geometry2D.get_closest_point_to_segment(
					p, p_poly[i], p_poly[(i + 1) % seg]))
				if d < best:
					best = d
			var e := sqrt(best)
			errs.append(e)
			if covered:
				spill = maxf(spill, e)
			else:
				shortfall = maxf(shortfall, e)

	errs.sort()
	var mean := 0.0
	for e in errs:
		mean += e
	mean = mean / float(maxi(errs.size(), 1))
	var p99 := 0.0
	var worst := 0.0
	if errs.size() > 0:
		p99 = errs[mini(int(float(errs.size()) * 0.99), errs.size() - 1)]
		worst = errs[errs.size() - 1]
	return {
		"mean": mean, "p99": p99, "max": worst, "spill": spill, "shortfall": shortfall,
		"disagree": errs.size(), "covered": covered_total,
		"area_err_pct": 100.0 * float(errs.size()) / float(maxi(p_truth_area, 1)),
	}
