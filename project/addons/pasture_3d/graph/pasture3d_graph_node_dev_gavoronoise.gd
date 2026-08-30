# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevGavoronoise — the GDScript oracle twin for Gavoronoise (spec §7.2).
#
# The algorithm is defined once, in src/pasture_3d_gavoronoise.h. This is one of its three
# implementations; the others are the C++ kernel and the mode-18 shader. It exists because a generator
# with derivative feedback has no closed form to check against — the only way to know the kernel computes
# what was specified is to write the specification out a second time, slowly, and compare.
#
# The hash below is integer arithmetic masked to 32 bits at every step. GDScript ints are 64-bit, so the
# masks are not decoration: without them the multiplies keep their high bits, the values diverge from
# uint32 wraparound, and the oracle disagrees with both other implementations for reasons that look like
# an algorithm bug.
@tool
class_name Pasture3DGraphNodeDevGavoronoise
extends Pasture3DGraphNode

const U32 := 0xffffffff

@export var amplitude: float = 60.0
@export var frequency: float = 0.002
@export var octaves: int = 4
@export var seed: int = 0
@export var angle_deg: float = 0.0
@export_range(0.0, 1.0, 0.01) var angle_spread: float = 1.0
@export var slope_strength: float = 1.0
@export var branch_strength: float = 2.0
@export_range(0.0, 1.0, 0.01) var z_cut_min: float = 0.2
@export_range(0.0, 1.0, 0.01) var z_cut_max: float = 1.0


func op() -> StringName:
	return &"dev_gavoronoise"


func role() -> Role:
	return Role.GENERATOR


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 0


func input_names() -> PackedStringArray:
	return PackedStringArray()


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array()


func eval_grid(_p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return solve(p_gw, p_gh, p_rect)


func solve(p_gw: int, p_gh: int, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var out := PackedFloat32Array()
	out.resize(n)
	if is_zero_approx(amplitude) or octaves <= 0 or frequency <= 0.0:
		out.fill(0.0)
		return out

	var theta := deg_to_rad(angle_deg)
	var cs := cos(theta)
	var sn := sin(theta)
	# Never exactly 0 — see the kernel header.
	var aniso := maxf(clampf(angle_spread, 0.0, 1.0), 0.02)
	# Fixed, and not exposed — see the kernel header.
	var lacunarity := 2.0
	var gain := 0.5

	for iz in p_gh:
		for ix in p_gw:
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, p_gw, p_gh, p_rect)
			var sx := w.x * cs + w.y * sn
			var sz := -w.x * sn + w.y * cs

			var total := 0.0
			var max_amp := 0.0
			var amp := 1.0
			var freq := frequency
			var grad_x := 0.0
			var grad_z := 0.0

			for o in octaves:
				var qx := (sx * freq + grad_x * branch_strength) * aniso
				var qz := sz * freq + grad_z * branch_strength
				var bx := int(floor(qx))
				var bz := int(floor(qz))

				var best := 1.0e30
				var best_dx := 0.0
				var best_dz := 0.0
				for oz in range(-1, 2):
					for ox in range(-1, 2):
						var cx := bx + ox
						var cz := bz + oz
						var h0 := _hash_cell(cx, cz, seed + o * 7919, 0x1)
						var h1 := _hash_cell(cx, cz, seed + o * 7919, 0x2)
						var fx := float(cx) + _rnd01(h0)
						var fz := float(cz) + _rnd01(h1)
						var dx := qx - fx
						var dz := qz - fz
						var d2 := dx * dx + dz * dz
						if d2 < best:
							best = d2
							best_dx = dx
							best_dz = dz

				var dist := sqrt(best)
				var v := clampf(1.0 - dist, 0.0, 1.0)

				var gx := 0.0
				var gz := 0.0
				if dist > 1e-12 and v > 0.0:
					gx = -best_dx / dist
					gz = -best_dz / dist

				var gl2 := grad_x * grad_x + grad_z * grad_z
				var damp := 1.0 / (1.0 + slope_strength * gl2)

				total += amp * v * damp
				grad_x += gx * amp * damp
				grad_z += gz * amp * damp
				max_amp += amp

				amp *= gain
				freq *= lacunarity

			var t := total / maxf(max_amp, 1e-4)
			if z_cut_max - z_cut_min > 1e-9:
				t = clampf((t - z_cut_min) / (z_cut_max - z_cut_min), 0.0, 1.0)
			else:
				t = 1.0 if t >= z_cut_max else 0.0
			out[iz * p_gw + ix] = float(t * amplitude)
	return out


## uint32 multiply-xor-shift. Every step is masked back to 32 bits so this wraps the way C++ and GLSL do.
func _hash_u32(p_x: int) -> int:
	var x := p_x & U32
	x = (x ^ (x >> 16)) & U32
	x = (x * 0x7feb352d) & U32
	x = (x ^ (x >> 15)) & U32
	x = (x * 0x846ca68b) & U32
	x = (x ^ (x >> 16)) & U32
	return x


func _hash_cell(p_cx: int, p_cz: int, p_seed: int, p_salt: int) -> int:
	var h := _hash_u32((p_cx * 0x9e3779b1) & U32)
	h = _hash_u32(h ^ ((p_cz * 0x85ebca6b) & U32))
	h = _hash_u32(h ^ (p_seed & U32))
	return _hash_u32(h ^ p_salt)


## 24 bits into [0,1) — the float mantissa width, so this conversion is exact on the GPU too.
func _rnd01(p_h: int) -> float:
	return float(p_h & 0x00ffffff) / 16777216.0
