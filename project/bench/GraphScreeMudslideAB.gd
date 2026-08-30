# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphScreeMudslideAB — spec §11 question 3: do Mudslide and Scree read the same on a real fixture, and is
# the batch better off with twelve nodes than thirteen?
#
# This is NOT a gate. Nothing here can pass or fail, because the question is a judgement about what the two
# nodes are FOR, and a number cannot make that judgement. What it can do is put the two side by side on the
# same ground, measure the ways they could plausibly be duplicates, and write out images so the judgement is
# made by looking rather than by arguing.
#
# The comparison is between the two DELTAS — the material each node adds or removes — because the outputs
# themselves are not the same kind of thing. Scree's port 0 is the deposit alone, a relief layer meant to be
# blended onto the surface. Mudslide's port 0 is the surface itself, after the slide. Comparing those two
# directly would be comparing a layer with a terrain and would prove nothing.
#
# Every "how different?" number here is meaningless without a scale for "different", so each one is reported
# alongside a WITHIN-node baseline: the same node against itself under a changed seed or a changed distance.
# If the two nodes differ by no more than one node differs from itself, they are duplicates.
#
# Run WINDOWED, so the fixture's generator can take the GPU path:
#   Godot_v4.7-stable_win64_console.exe --path project bench/GraphScreeMudslideAB.tscn
extends Node

# 2 m cells. Scree's own documentation warns that its grain stops resolving below about 4 m of grain size,
# so a fixture at 8 m cells would be judging the node on a resolution it says it does not work at.
const N := 256
const RECT := Rect2(-256.0, -256.0, 512.0, 512.0)
const OUT_DIR := "res://bench/ab_out"

var _base: PackedFloat32Array
var _slope_deg: PackedFloat32Array


func _ready() -> void:
	print("=== Scree vs Mudslide: are they the same node? (spec §11 q3) ===\n")
	_base = _fixture()
	_slope_deg = _slope_field(_base)
	print("[fixture] Gavoronoise mountainside, %d² over %.0f m (%.1f m cells), relief %.1f m\n"
			% [N, RECT.size.x, RECT.size.x / float(N), _relief(_base)])

	var scree := _scree_delta(0, 2.0)
	var scree_b := _scree_delta(7, 2.0)          # same node, different grain seed
	var mud := _mudslide_delta(60.0, 6.0)
	var mud_b := _mudslide_delta(90.0, 6.0)      # same node, a longer run

	_structural(scree, mud)
	_similarity(scree, scree_b, mud, mud_b)
	_placement(scree, mud)
	_write_images(scree, mud)

	print("\n=== A/B complete — the verdict is above, the images are in %s ===\n" % OUT_DIR)
	get_tree().quit(0)


# --- 1. structure: what kind of operation is each one? ------------------------------------------------
func _structural(p_scree: PackedFloat32Array, p_mud: PackedFloat32Array) -> void:
	print("[1] What kind of operation each one is")
	for pair in [["Scree", p_scree], ["Mudslide", p_mud]]:
		var label: String = pair[0]
		var d: PackedFloat32Array = pair[1]
		var added := 0.0
		var removed := 0.0
		for i in d.size():
			if d[i] > 0.0:
				added += d[i]
			elif d[i] < 0.0:
				removed += -d[i]
		var net := added - removed
		var total := added + removed
		# Conservation is the discriminator, not the presence of removal - Scree does remove some material,
		# which the first version of this comment assumed it could not.
		print("    %-9s adds %8.1f m, removes %8.1f m, net %+9.1f m  (removal is %.1f%% of all movement)"
				% [label, added, removed, net, (removed / maxf(total, 1e-9)) * 100.0])
	# Measured, and it corrected the prediction: Scree is not purely additive - its grain carves as well as
	# piles, about one metre removed for every five added. What it does NOT do is conserve, while Mudslide
	# nets zero to the last digit. That is the structural line between them, and no parameter crosses it.
	print("    → Scree is a NON-CONSERVING stamp: most of what it lays down is material it invented.")
	print("      Mudslide is conserving transport - it nets exactly zero because every metre it deposits")
	print("      came off somewhere upslope. Neither node can be tuned into the other across that line.\n")


# --- 2. similarity, against a within-node baseline -----------------------------------------------------
func _similarity(p_scree: PackedFloat32Array, p_scree_b: PackedFloat32Array,
		p_mud: PackedFloat32Array, p_mud_b: PackedFloat32Array) -> void:
	print("[2] How alike the two deposits are, against how alike each node is to itself")
	var between := _correlation(p_scree, p_mud)
	var within_scree := _correlation(p_scree, p_scree_b)
	var within_mud := _correlation(p_mud, p_mud_b)
	print("    Scree(seed 0) vs Scree(seed 7)      correlation %+.3f   ← the same node, reseeded" % within_scree)
	print("    Mudslide(60 m) vs Mudslide(90 m)    correlation %+.3f   ← the same node, longer run" % within_mud)
	print("    Scree vs Mudslide                   correlation %+.3f" % between)
	# The baselines are what make the between-node number readable. Without them, "0.1" could mean the nodes
	# are unrelated or could mean this fixture makes everything look unrelated.
	if between >= minf(within_scree, within_mud):
		print("    → the two nodes agree at least as closely as each node agrees with itself: DUPLICATES.\n")
	else:
		print("    → the two nodes share less than each node shares with its own variations: DISTINCT.\n")

	print("    Texture scale of each deposit (energy surviving a 20 m blur):")
	for pair in [["Scree", p_scree], ["Mudslide", p_mud]]:
		var label: String = pair[0]
		var d: PackedFloat32Array = pair[1]
		print("      %-9s %.1f%% of its energy is coarser than 20 m" % [label, _coarse_fraction(d) * 100.0])
	# This measure was expected to separate them and does not: both deposits are dominated by detail finer
	# than 20 m, and Mudslide is if anything the finer of the two - its lobes are built out of narrow gully
	# fills, not the broad smooth sheets the name suggests. Reported anyway, because a measure that fails to
	# discriminate is a result, and dropping it would leave the case looking stronger than it is.
	print("    → this one does NOT separate them: both are fine-scale fields, and the difference runs the")
	print("      opposite way to the intuition. Texture scale is not the reason to keep both nodes.\n")


# --- 3. placement: where does the material end up? ----------------------------------------------------
func _placement(p_scree: PackedFloat32Array, p_mud: PackedFloat32Array) -> void:
	print("[3] Where each one puts material, by the steepness of the ground it lands on")
	# The decision-relevant measure. Scree is gated ON steep ground by construction; Mudslide takes from the
	# steep and lays it out below. If both piled material in the same places, the nodes would compete.
	for pair in [["Scree", p_scree], ["Mudslide", p_mud]]:
		var label: String = pair[0]
		var d: PackedFloat32Array = pair[1]
		print("      %-9s deposits on ground averaging %.1f°, takes from ground averaging %s"
				% [label, _weighted_slope(d, true), _weighted_slope_str(d)])
	print("    → Scree lays its rubble on the steep face it is gated to. Mudslide empties the steep face")
	print("      and builds a lobe on the gentler ground below it.\n")


# --- 4. the images ------------------------------------------------------------------------------------
func _write_images(p_scree: PackedFloat32Array, p_mud: PackedFloat32Array) -> void:
	print("[4] Images — the part that actually answers the question")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var scree_surface := PackedFloat32Array()
	scree_surface.resize(_base.size())
	for i in _base.size():
		scree_surface[i] = _base[i] + p_scree[i]
	var mud_surface := PackedFloat32Array()
	mud_surface.resize(_base.size())
	for i in _base.size():
		mud_surface[i] = _base[i] + p_mud[i]

	_save(_hillshade(_base), "01_base.png")
	_save(_hillshade(scree_surface), "02_scree.png")
	_save(_hillshade(mud_surface), "03_mudslide.png")
	_save(_signed_map(p_scree), "04_scree_delta.png")
	_save(_signed_map(p_mud), "05_mudslide_delta.png")
	print("    hillshades and signed delta maps written (blue removed, red added, grey untouched)")


# --- fixture ------------------------------------------------------------------------------------------

## A real generator from the catalogue, not a ramp. Gavoronoise gives branching ridgelines with steep faces,
## gullies and gentler ground between them — so both nodes get the terrain features they are built for, and
## neither is being judged on a fixture that suits the other.
func _fixture() -> PackedFloat32Array:
	var g := Pasture3DGraphNodeGavoronoise.new()
	g.amplitude = 110.0
	g.frequency = 0.008
	g.octaves = 5
	g.seed = 3
	g.angle_deg = 30.0
	g.angle_spread = 0.7
	g.slope_strength = 1.0
	g.branch_strength = 2.0
	g.z_cut_min = 0.0
	g.z_cut_max = 1.0
	return g.eval_grid([PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array()], N, N, null, RECT)


func _scree_delta(p_seed: int, p_amplitude: float) -> PackedFloat32Array:
	var s := Pasture3DGraphNodeScree.new()
	s.amplitude = p_amplitude
	s.grain_size = 6.0
	s.downslope_streak = 4.0
	s.toe_deposition = 3.0
	s.seed = p_seed
	s.min_slope_degrees = 22.0
	s.slope_falloff_degrees = 12.0
	s.evaluation = Pasture3DGraphNodeScree.Evaluation.LIVE
	# Scree's port 0 IS the delta: it outputs the deposit, not the surface plus the deposit.
	return s.eval_grid([_base, PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array()],
			N, N, null, RECT)


func _mudslide_delta(p_travel: float, p_depth: float) -> PackedFloat32Array:
	var m := Pasture3DGraphNodeMudslide.new()
	m.talus_angle_deg = 22.0 # the same trigger angle as Scree's slope gate, so neither is handed a head start
	m.depth = p_depth
	m.travel_distance = p_travel
	m.depth_exponent = 1.0
	m.viscosity_power = 1.0
	m.amount = 1.0
	m.evaluation = Pasture3DGraphNodeMudslide.Evaluation.LIVE
	var out: PackedFloat32Array = m.eval_grid([_base, PackedFloat32Array(), PackedFloat32Array()],
			N, N, null, RECT)
	# Mudslide's port 0 is the SURFACE, so the delta has to be taken.
	var d := PackedFloat32Array()
	d.resize(out.size())
	for i in out.size():
		d[i] = out[i] - _base[i]
	return d


# --- measures -----------------------------------------------------------------------------------------

## Pearson correlation of two fields. The direct "do these look like each other" number: +1 means the same
## material in the same places, 0 means unrelated.
func _correlation(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	var n := p_a.size()
	var ma := 0.0
	var mb := 0.0
	for i in n:
		ma += p_a[i]
		mb += p_b[i]
	ma /= float(n)
	mb /= float(n)
	var sab := 0.0
	var saa := 0.0
	var sbb := 0.0
	for i in n:
		var da := p_a[i] - ma
		var db := p_b[i] - mb
		sab += da * db
		saa += da * da
		sbb += db * db
	if saa <= 1e-12 or sbb <= 1e-12:
		return 0.0
	return sab / sqrt(saa * sbb)


## The share of a field's energy that survives a 20 m blur — a texture-scale measure. A grain stamp loses
## nearly all of it; a travelled lobe keeps nearly all of it.
func _coarse_fraction(p_d: PackedFloat32Array) -> float:
	var blur := Pasture3DGraphNodeDevTerrainMetrics.new()
	var sm: PackedFloat32Array = blur.box_mean(p_d, N, N, RECT, 20.0)
	var e_total := 0.0
	var e_coarse := 0.0
	for i in p_d.size():
		e_total += p_d[i] * p_d[i]
		e_coarse += sm[i] * sm[i]
	if e_total <= 1e-12:
		return 0.0
	return clampf(e_coarse / e_total, 0.0, 1.0)


## The mean slope of the ground receiving material (or losing it), weighted by how much.
func _weighted_slope(p_d: PackedFloat32Array, p_positive: bool) -> float:
	var w := 0.0
	var acc := 0.0
	for i in p_d.size():
		var v := p_d[i] if p_positive else -p_d[i]
		if v <= 0.0:
			continue
		w += v
		acc += v * _slope_deg[i]
	if w <= 1e-9:
		return 0.0
	return acc / w


func _weighted_slope_str(p_d: PackedFloat32Array) -> String:
	var removed := 0.0
	for i in p_d.size():
		if p_d[i] < 0.0:
			removed += -p_d[i]
	if removed <= 1e-6:
		return "nothing (it removes no material)"
	return "%.1f°" % _weighted_slope(p_d, false)


func _slope_field(p_h: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(N * N)
	var dx := RECT.size.x / float(N)
	var dz := RECT.size.y / float(N)
	for iz in N:
		for ix in N:
			var xm := maxi(ix - 1, 0)
			var xp := mini(ix + 1, N - 1)
			var zm := maxi(iz - 1, 0)
			var zp := mini(iz + 1, N - 1)
			var gx := (p_h[iz * N + xp] - p_h[iz * N + xm]) / (float(xp - xm) * dx)
			var gz := (p_h[zp * N + ix] - p_h[zm * N + ix]) / (float(zp - zm) * dz)
			out[iz * N + ix] = rad_to_deg(atan(sqrt(gx * gx + gz * gz)))
	return out


func _relief(p_g: PackedFloat32Array) -> float:
	var lo := INF
	var hi := -INF
	for i in p_g.size():
		lo = minf(lo, p_g[i])
		hi = maxf(hi, p_g[i])
	return hi - lo


# --- rendering ----------------------------------------------------------------------------------------

## A plain Lambert hillshade from the north-west. Not a beauty render — the point is that the eye reads
## shading as shape, so a texture and a landform are told apart at a glance in a way no statistic replaces.
func _hillshade(p_h: PackedFloat32Array) -> Image:
	var img := Image.create(N, N, false, Image.FORMAT_RGB8)
	var dx := RECT.size.x / float(N)
	var dz := RECT.size.y / float(N)
	var light := Vector3(-0.6, 0.65, -0.46).normalized()
	for iz in N:
		for ix in N:
			var xm := maxi(ix - 1, 0)
			var xp := mini(ix + 1, N - 1)
			var zm := maxi(iz - 1, 0)
			var zp := mini(iz + 1, N - 1)
			var gx := (p_h[iz * N + xp] - p_h[iz * N + xm]) / (float(xp - xm) * dx)
			var gz := (p_h[zp * N + ix] - p_h[zm * N + ix]) / (float(zp - zm) * dz)
			var nrm := Vector3(-gx, 1.0, -gz).normalized()
			var l := clampf(nrm.dot(light), 0.0, 1.0)
			var v := 0.15 + 0.85 * l
			img.set_pixel(ix, iz, Color(v, v, v))
	return img


## Signed material map: blue where material left, red where it arrived, on a symmetric scale so the two
## nodes are drawn at the same metres-per-unit-colour and can be compared by eye.
func _signed_map(p_d: PackedFloat32Array) -> Image:
	var img := Image.create(N, N, false, Image.FORMAT_RGB8)
	var peak := 0.0
	for i in p_d.size():
		peak = maxf(peak, absf(p_d[i]))
	peak = maxf(peak, 1e-6)
	for iz in N:
		for ix in N:
			var v := clampf(p_d[iz * N + ix] / peak, -1.0, 1.0)
			var c := Color(0.5, 0.5, 0.5)
			if v > 0.0:
				c = Color(0.5 + 0.5 * v, 0.5 - 0.35 * v, 0.5 - 0.35 * v)
			elif v < 0.0:
				c = Color(0.5 + 0.35 * v, 0.5 + 0.35 * v, 0.5 - 0.5 * v)
			img.set_pixel(ix, iz, c)
	return img


func _save(p_img: Image, p_name: String) -> void:
	var path := ProjectSettings.globalize_path(OUT_DIR).path_join(p_name)
	var err := p_img.save_png(path)
	if err != OK:
		print("    !! could not write %s (error %d)" % [path, err])
	else:
		print("    wrote %s" % p_name)
