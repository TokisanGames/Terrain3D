# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3D brush-erosion PROBE — a diagnostic, not a gate. It prints nothing but numbers and never
# fails, in the same spirit as bench/SimFieldProbe.tscn.
#
# It answers "what magnitudes does the brush-hosted solver actually produce on a mound-sized craggy
# dome", which is what bench/BrushErosionGate.tscn's fixtures are calibrated against. Two of that gate's
# criteria were originally written against guesses and both were wrong by an order of magnitude:
#
#   * a FLOW band of 2000 m2, when the field on this fixture tops out around 600 and has a 90th
#     percentile of 46. It matched nothing and the gate measured 0%.
#   * "the cut is concentrated in channels", which is FALSE of the height delta at this scale. Both the
#     top-decile share and the connectivity of the deep cut refuse to separate a routed solve from an
#     unrouted one — the tail is in the drainage field, not in the metres removed.
#
# Re-run this before moving a band or a threshold in that gate.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/BrushErosionProbe.tscn
extends Node

func _ready() -> void:
	var terrain = ClassDB.instantiate("Pasture3D")
	add_child(terrain)
	var gw := 121
	var gh := 121
	var vs := 1.0
	var n := gw * gh
	var noise := FastNoiseLite.new()
	noise.seed = 5
	noise.frequency = 1.0 / 22.0
	var z := PackedFloat32Array()
	z.resize(n)
	for iz in range(gh):
		for ix in range(gw):
			var dx := (ix - 60) / 60.0
			var dz := (iz - 60) / 60.0
			var d := sqrt(dx * dx + dz * dz)
			if d >= 1.0:
				z[iz * gw + ix] = NAN
				continue
			var pr := 1.0 - d
			pr = pr * pr * (3.0 - 2.0 * pr)
			z[iz * gw + ix] = 55.0 * pr + 8.0 * noise.get_noise_2d(ix, iz) * pr

	for case in [[60, 0.09, 0.02, 0.45], [60, 0.09, 0.02, 0.0], [30, 0.09, 0.15, 0.45]]:
		var params := {
			"gw": gw, "gh": gh, "cell_size": vs, "time_step": 1.0,
			"iterations": case[0], "erosion_rate": case[1], "area_exponent": case[3],
			"diffusion": case[2], "deposition": 0.0, "want_diagnostics": true,
		}
		var res: Dictionary = terrain.data.erode_heightfield(z, params, PackedFloat32Array())
		if not bool(res.get("ok", false)):
			print("case %s: solver said no" % [case])
			continue
		var zo: PackedFloat32Array = res["z"]
		var flow: PackedFloat32Array = res["flow"]
		var cut: Array[float] = []
		var fin: Array[float] = []
		for i in range(n):
			if not is_finite(z[i]):
				continue
			cut.append(maxf(z[i] - zo[i], 0.0))
			fin.append(flow[i])
		var above := 0
		for f in fin:
			if f >= 150.0:
				above += 1
		# Connectivity of the deeply-cut cells: a channel network is a few long connected structures, a
		# crag-by-crag lowering is many small blobs.
		var mark := PackedByteArray()
		mark.resize(n)
		var thresh := _pct(cut, 0.80)
		for i in range(n):
			mark[i] = 1 if (is_finite(z[i]) and maxf(z[i] - zo[i], 0.0) >= thresh and thresh > 0.0) else 0
		var comps := _components(mark, gw, gh)
		print("        deep-cut cells: %d in %d components, largest holds %.0f%%"
			% [comps[0], comps[1], comps[2] * 100.0])
		print("iter=%d rate=%.2f diff=%.2f m=%.2f | cut mean %.2f max %.2f decile %.0f%% | flow p90 %.0f p99 %.0f max %.0f | %.1f%% of cells over 150 m2"
			% [case[0], case[1], case[2], case[3], _mean(cut), _max(cut), _top_share(cut, 0.10) * 100.0,
				_pct(fin, 0.90), _pct(fin, 0.99), _max(fin), 100.0 * above / float(fin.size())])
	get_tree().quit(0)


## [marked, components, largest share] over a 4-connected mask.
func _components(p_mark: PackedByteArray, p_gw: int, p_gh: int) -> Array:
	var seen := PackedByteArray()
	seen.resize(p_mark.size())
	var marked := 0
	var comps := 0
	var largest := 0
	for i in range(p_mark.size()):
		if p_mark[i] == 1:
			marked += 1
	for start in range(p_mark.size()):
		if p_mark[start] == 0 or seen[start] == 1:
			continue
		comps += 1
		var size := 0
		var stack: Array[int] = [start]
		seen[start] = 1
		while not stack.is_empty():
			var cur: int = stack.pop_back()
			size += 1
			var cx := cur % p_gw
			var cz := cur / p_gw
			for d in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
				var nx: int = cx + d[0]
				var nz: int = cz + d[1]
				if nx < 0 or nz < 0 or nx >= p_gw or nz >= p_gh:
					continue
				var ni := nz * p_gw + nx
				if p_mark[ni] == 1 and seen[ni] == 0:
					seen[ni] = 1
					stack.append(ni)
		largest = maxi(largest, size)
	return [marked, comps, float(largest) / float(marked) if marked > 0 else 0.0]


func _mean(a: Array[float]) -> float:
	var s := 0.0
	for v in a:
		s += v
	return s / float(a.size()) if a.size() > 0 else 0.0

func _max(a: Array[float]) -> float:
	var m := -INF
	for v in a:
		m = maxf(m, v)
	return m

func _pct(a: Array[float], p: float) -> float:
	var s: Array[float] = a.duplicate()
	s.sort()
	return s[clampi(int(s.size() * p), 0, s.size() - 1)]

func _top_share(a: Array[float], f: float) -> float:
	var s: Array[float] = a.duplicate()
	s.sort()
	s.reverse()
	var tot := 0.0
	for v in s:
		tot += v
	if tot <= 0.0:
		return 0.0
	var k := maxi(1, int(round(s.size() * f)))
	var top := 0.0
	for i in range(k):
		top += s[i]
	return top / tot
