# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DReliefMaterial — abstract base for the Plow's "dynamic materials": saveable, reusable landform
# relief that the brush stamps into the height map. A material COMPILES to a flat op program (an ordered
# layer list, not a scripting language) which the native rasteriser evaluates per cell; this script also
# carries the GDScript evaluator, which is the A/B oracle the C++ path must match to 1e-4.
#
# This is deliberately separate from Pasture3DPlowMaterial (a single tiling height map). Assign one on a
# Pasture3DPlow with Source = RELIEF. See PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md.
@tool
class_name Pasture3DReliefMaterial
extends Resource

## Op ids — MUST stay in sync with ReliefOpType in src/pasture_3d_relief_ops.h.
enum Op {
	CONST = 0, FBM = 1, RIDGED = 2, BILLOW = 3, DUNES = 4, FURROWS = 5, CRATER = 6, SCREE = 7,
	WARP = 8, TERRACE = 9, STRATIFY = 10, CLAMP = 11, CURVE = 12,
}
## How an op's value combines into the accumulator. PROFILE ops ignore this.
enum Blend { ADD = 0, SUB = 1, MUL = 2, MAX = 3, MIN = 4, REPLACE = 5 }

## Wire format (spec §4.1). Mirrored by the C++ evaluator.
const OP_STRIDE := 4     # [op_type, blend, selector_id, flags]
const PARAM_STRIDE := 12 # per-op float block
const FLAG_NEGATE := 1   # bit0 — negate the op's value before blending
const FLAG_CLAMP := 2    # bit1 — clamp the accumulator to [-1,1] after blending
const NO_SELECTOR := -1  # op is ungated
const SELECTOR_STRIDE := 8 # [filter_type, min, max, falloff_lo, falloff_hi, invert, strength, radius]
const SELECTOR_RADIUS := 7 # slot of measure_radius, in METRES; 0 = one cell (spec §21.6)
const CURVE_LUT_N := 256 # samples per baked Curve, one contiguous block per CURVE op
## Depth of hollow, in metres over one cell, at which SCREE's toe deposition reaches full strength.
## Sync with RELIEF_SCREE_TOE_FULL_M in src/pasture_3d_relief_ops.h — see _scree.
const SCREE_TOE_FULL_M := 0.25

## Multiplier on top of the brush's Height Scale, so a saved material carries its own intensity.
@export_range(0.0, 4.0, 0.01, "or_greater") var strength: float = 1.0:
	set(v):
		strength = maxf(v, 0.0)
		_touch()
## How this material combines when it is a layer of a Pasture3DReliefStack. Ignored when the material is
## assigned directly on a brush (the accumulator starts at 0, so ADD and REPLACE are equivalent there).
@export var blend: Blend = Blend.ADD:
	set(v):
		blend = v
		_touch()
## Optional final shaping of the relief: the curve remaps the signed output, with the curve's X and Y both
## covering [-1,1] as [0,1]. Use it to flatten valleys, exaggerate peaks, or clip one side.
## NOTE: this is a PROFILE op, so it remaps the WHOLE accumulator. Inside a Pasture3DReliefStack that means
## it shapes everything up to and including this layer, not this layer alone.
@export var output_curve: Curve:
	set(v):
		if output_curve != null and output_curve.changed.is_connected(_touch):
			output_curve.changed.disconnect(_touch)
		output_curve = v
		if output_curve != null and not output_curve.changed.is_connected(_touch):
			output_curve.changed.connect(_touch)
		_touch()
## Optional terrain-aware gate: confine this material to steep ground, an altitude band, or hollows.
## Applied to every shape this material generates. See Pasture3DReliefSelector.
@export var selector: Pasture3DReliefSelector:
	set(v):
		if selector != null and selector.changed.is_connected(_touch):
			selector.changed.disconnect(_touch)
		selector = v
		if selector != null and not selector.changed.is_connected(_touch):
			selector.changed.connect(_touch)
		_touch()

# Compiled program, rebuilt lazily. _noise is parallel to the op index (one entry per op): the
# FastNoiseLite instance(s) that op needs, or null. The C++ path rebuilds these from `params` using the
# SAME rules (_configure_noise below) — that identity is what makes the A/B gate meaningful.
var _ops := PackedInt32Array()
var _params := PackedFloat32Array()
var _luts := PackedFloat32Array() # concatenated CURVE_LUT_N blocks, indexed by a CURVE op's slot
var _selectors := PackedFloat32Array() # stride-8 blocks, indexed by an op's selector_id
var _noise: Array = []
var _dirty := true
var _building := false # cycle guard: a stack that (transitively) contains itself must not recurse forever


## Invalidate the compiled program and notify the brush to re-bake. Every exported setter must call this.
func _touch() -> void:
	_dirty = true
	emit_changed()


## Compile to the flat op program, memoised until _touch(). Returns [ops, params, luts, selectors].
## Called ONCE per bake by the plow, never per cell.
func compile() -> Array:
	if _dirty:
		if _building:
			push_warning("Pasture3DReliefMaterial: cycle detected in a relief stack; skipping '%s'." % resource_path)
			return [PackedInt32Array(), PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array()]
		_ops.clear()
		_params.clear()
		_luts.clear()
		_selectors.clear()
		_noise.clear()
		_building = true
		_build()
		# This material's own selector gates EVERY op it emitted, not just the generators. An earlier
		# version gated only generators, which left PROFILE ops (TERRACE / STRATIFY) remapping a
		# gated-to-zero accumulator into a non-zero constant — so a fully excluded area still got stepped
		# relief. Ops that already carry a selector (Scree gates its own) keep theirs.
		if selector != null:
			var sid := _emit_selector(selector)
			for i in range(_ops.size() / OP_STRIDE):
				var o := i * OP_STRIDE
				if _ops[o + 2] == NO_SELECTOR:
					_ops[o + 2] = sid
		# The output curve is emitted last so it shapes the finished relief.
		if output_curve != null:
			_emit(Op.CURVE, Blend.ADD, [_bake_curve(output_curve)])
		_building = false
		_dirty = false
	return [_ops, _params, _luts, _selectors]


## Compiled program plus the parallel noise table. Only Pasture3DReliefStack needs the noise table (to
## splice a child's program into its own); the plow uses compile() and lets C++ rebuild the noise.
func _program() -> Array:
	compile()
	return [_ops, _params, _luts, _selectors, _noise]


## Every Pasture3DSimResult this material's selectors read, in compile order and possibly with repeats.
## Empty for the ordinary terrain-shape Filter Types, which is the common case and costs nothing.
##
## The brush needs these because a Sim Result is a whole grid with its own extent and cannot travel in
## the flat stride-8 selector block (see Pasture3DReliefSelector.to_params). Composites — the stack —
## override this to include their children's.
func sim_results() -> Array:
	if selector != null and selector.is_sim_filter_type() and selector.sim_result != null:
		return [selector.sim_result]
	return []


## Every Pasture3DReliefSelector this material gates on, in compile order. Only the assignable one lives
## here; composites override to add their children's, and an op that carries its own gate (Scree's slope
## band) does not appear — that one is generated from the op's own properties and cannot be misconfigured
## the way an assigned selector can. Drives the host's band-shape warnings (§21.5).
func selectors() -> Array:
	return [selector] if selector != null else []


## True when any selector in this material reads a Sim Result, whether or not one is assigned. Drives
## the brush's "a sim Filter Type is in use with no Sim Result" warning, which must fire precisely when
## the reference is MISSING — so this cannot be `not sim_results().is_empty()`.
func wants_sim_result() -> bool:
	return selector != null and selector.is_sim_filter_type()


## Append a selector to the table and return its index (the value an op stores in its selector slot).
func _emit_selector(s: Pasture3DReliefSelector) -> int:
	var id := _selectors.size() / SELECTOR_STRIDE
	for f in s.to_params():
		_selectors.append(f)
	return id


## Subclasses override and emit their ops here via _emit(). Composites call _program on their children.
func _build() -> void:
	pass


## Append one op. `p` holds up to PARAM_STRIDE floats; the remainder is zero-filled.
func _emit(op: int, blend_mode: int, p: Array, flags: int = 0, selector: int = NO_SELECTOR) -> void:
	_ops.append(op)
	_ops.append(blend_mode)
	_ops.append(selector)
	_ops.append(flags)
	var base := _params.size()
	_params.resize(base + PARAM_STRIDE)
	for i in range(mini(p.size(), PARAM_STRIDE)):
		_params[base + i] = float(p[i])
	_noise.append(_make_noise(op, _params, base))


## Bake a Curve into the LUT table and return its slot index (the value a CURVE op stores in param 0).
func _bake_curve(c: Curve) -> int:
	var slot := _luts.size() / CURVE_LUT_N
	var base := _luts.size()
	_luts.resize(base + CURVE_LUT_N)
	for i in range(CURVE_LUT_N):
		_luts[base + i] = c.sample_baked(float(i) / float(CURVE_LUT_N - 1))
	return slot


## GENERATOR ops (ids 0..7) compute a value and blend it into the accumulator, and by invariant carry
## their amplitude in param slot 0. DOMAIN (WARP) and PROFILE ops do neither. Mirrored in C++.
static func _is_generator(op: int) -> bool:
	return op >= Op.CONST and op <= Op.SCREE


## Does this material predominantly RAISE the ground? Drives the plow's Add Water raise check
## (PASTURE3D_WATER_BODIES_SPEC.md §7.8). Craters override to false.
func _raises() -> bool:
	return true


## Empty when the material is usable; otherwise a one-liner the plow surfaces as a configuration warning.
func _configuration_warning() -> String:
	return ""


# ---- Noise construction (mirrored exactly by relief_build in C++) ----

## Build the FastNoiseLite instance(s) an op needs, or null. Ops that need none return null so the
## evaluator can index _noise by op position without a second table. Ops whose noise is optional still
## build it unconditionally (the amount parameter scales it to nothing), because a conditional here would
## have to be mirrored exactly in C++ to keep the paths identical — and that is a bug waiting to happen.
static func _make_noise(op: int, params: PackedFloat32Array, base: int) -> Variant:
	match op:
		Op.FBM, Op.RIDGED, Op.BILLOW:
			return _configure_noise(params[base + 1], int(params[base + 2]), params[base + 3],
					params[base + 4], int(params[base + 5]), op == Op.RIDGED)
		Op.DUNES: # wander field
			return _configure_noise(params[base + 5], 2, 2.0, 0.5, int(params[base + 7]), false)
		Op.FURROWS: # wobble field
			return _configure_noise(params[base + 4], 2, 2.0, 0.5, int(params[base + 6]), false)
		Op.TERRACE: # step jitter field
			return _configure_noise(params[base + 4], 2, 2.0, 0.5, int(params[base + 3]), false)
		Op.STRATIFY: # lateral break-up field
			return _configure_noise(params[base + 4], 3, 2.0, 0.5, int(params[base + 6]), false)
		Op.SCREE: # grain field
			return _configure_noise(params[base + 1], 3, 2.0, 0.5, int(params[base + 4]), false)
		Op.WARP:
			# Two decorrelated fields offset the domain. Godot's FastNoiseLite applies its own
			# domain_warp_* settings internally to get_noise_2d and exposes no standalone warp call, so
			# the offset is computed explicitly here — which is also what lets subsequent ops see it.
			var amp_freq := params[base + 1]
			var oct := int(params[base + 2])
			var sd := int(params[base + 3])
			return [
				_configure_noise(amp_freq, oct, 2.0, 0.5, sd, false),
				_configure_noise(amp_freq, oct, 2.0, 0.5, sd + 1013, false),
			]
		_:
			return null


## The one place noise settings are decided. Any change here must be mirrored in C++ relief_build.
static func _configure_noise(freq: float, octaves: int, lacunarity: float, gain: float, seed: int,
		ridged: bool) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.seed = seed
	n.frequency = maxf(freq, 0.000001)
	n.fractal_type = FastNoiseLite.FRACTAL_RIDGED if ridged else FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = clampi(octaves, 1, 8)
	n.fractal_lacunarity = lacunarity
	n.fractal_gain = gain
	n.fractal_weighted_strength = 0.0
	return n


# ---- GDScript evaluator (the A/B oracle) ----

## Evaluate the compiled program at one cell. `u,v` are metres in the active mapping frame; `nu,nv` are
## the same point normalised to the loop's half-extents (±1 at the fitted rect edge); `inv_ex,inv_ez`
## convert a metre offset into that normalised space so WARP can displace both consistently.
## `alt / slope_deg / curv / gx,gz` describe the ground BELOW this brush's layer at this cell: height,
## steepness, concavity — METRES this cell sits below its one-cell ring, positive for a hollow (§21.6) —
## and the height gradient. Selectors and SCREE read them; every other op ignores them, and the brush only
## bothers computing them when the program needs them.
## Returns the signed accumulator, nominally [-1,1] but deliberately not hard-clamped (spec §4.4).
## `flow / ero / dep / wet` describe what the erosion sim did at this cell, for the four sim Filter Types,
## arrive ALREADY CONVERTED to the units a selector band is written in: flow in m² of catchment (the
## resource stores its log), erosion as a positive depth (the resource stores a negative delta). The
## brush does that conversion once per cell — see Pasture3DPlow._sim_fields and relief_fields_add_sim,
## which must agree. Defaulted so every existing caller and every non-sim material is unaffected.
## `measured` / `fi` carry the wider slope and curvature grids a selector's `measure_radius` asks for
## (§21.6): `measured[sid]` is `[slope_grid, curv_grid]` for the radius selector `sid` set, or `[]` when it
## left the radius at 0 and reads the one-cell `slope_deg` / `curv` above. They are GRIDS plus a cell index
## rather than two more floats because the radius is per SELECTOR, not per cell, and a program can hold
## several — the same shape ReliefFields uses in C++. Defaulted, so every caller that has no radius in play
## passes nothing and behaves exactly as before.
func eval(u: float, v: float, nu: float, nv: float, inv_ex: float, inv_ez: float,
		alt: float = 0.0, slope_deg: float = 0.0, curv: float = 0.0,
		gx: float = 0.0, gz: float = 0.0,
		flow: float = 0.0, ero: float = 0.0, dep: float = 0.0, wet: float = 0.0,
		measured: Array = [], fi: int = -1) -> float:
	# Compile on demand. Callers in the bake path always compile first, but an uncompiled material used
	# to evaluate to a silent 0 — which reads exactly like "correctly gated out" and cost a gate its
	# meaning once already. One bool test per cell is not worth that trap.
	if _dirty:
		compile()
	var acc := 0.0
	var count := _ops.size() / OP_STRIDE
	for i in range(count):
		var o := i * OP_STRIDE
		var op := _ops[o]
		var blend_mode := _ops[o + 1]
		var flags := _ops[o + 3]
		var p := i * PARAM_STRIDE

		# Terrain-aware gate for this op, if any. A GENERATOR scales its contribution by it, a DOMAIN op
		# scales its displacement, and a PROFILE op lerps between the un-remapped and remapped
		# accumulator — so `sel == 0` always means "this op did nothing", smoothly, whatever its category.
		var sid := _ops[o + 2]
		var sel := 1.0
		if sid >= 0:
			sel = _selector_value(sid, alt, slope_deg, curv, flow, ero, dep, wet, measured, fi)

		# --- DOMAIN: rewrites the sample point for every op that follows; never touches acc.
		if op == Op.WARP:
			var pair: Array = _noise[i]
			var wamp := _params[p] * sel
			var du: float = pair[0].get_noise_2d(u, v) * wamp
			var dv: float = pair[1].get_noise_2d(u, v) * wamp
			u += du
			v += dv
			nu += du * inv_ex
			nv += dv * inv_ez
			continue

		# --- PROFILE: remaps acc in place; ignores blend.
		if op == Op.TERRACE:
			var tx := clampf(acc * 0.5 + 0.5, 0.0, 1.0)
			var jit := _params[p + 2]
			if jit != 0.0:
				tx = clampf(tx + _noise[i].get_noise_2d(u, v) * jit, 0.0, 1.0)
			acc = lerpf(acc, _band(tx, _params[p], _params[p + 1]) * 2.0 - 1.0, sel)
			continue
		if op == Op.STRATIFY:
			# Bands are horizontal in the accumulator, then tilted by a linear ramp across the ground
			# (dip, in normalised units per 100 m) and broken up laterally so they are not dead straight.
			var dipdir := _params[p + 3]
			var w := acc + _params[p + 2] * (u * cos(dipdir) + v * sin(dipdir)) * 0.01
			w += _noise[i].get_noise_2d(u, v) * _params[p + 5]
			acc = lerpf(acc, _band(clampf(w * 0.5 + 0.5, 0.0, 1.0), _params[p], _params[p + 1]) * 2.0 - 1.0, sel)
			continue
		if op == Op.CLAMP:
			acc = lerpf(acc, clampf(acc, _params[p], _params[p + 1]), sel)
			continue
		if op == Op.CURVE:
			acc = lerpf(acc, _sample_lut(int(_params[p]), clampf(acc * 0.5 + 0.5, 0.0, 1.0)) * 2.0 - 1.0, sel)
			continue

		# --- GENERATOR: computes a value and blends it in.
		var val := 0.0
		match op:
			Op.CONST:
				val = _params[p]
			Op.FBM, Op.RIDGED, Op.BILLOW:
				var raw: float = _noise[i].get_noise_2d(u, v)
				if op == Op.BILLOW:
					raw = absf(raw) * 2.0 - 1.0
				elif op == Op.RIDGED:
					var sharp := _params[p + 6]
					if sharp != 1.0 and sharp > 0.0:
						raw = signf(raw) * pow(absf(raw), sharp)
				val = raw * _params[p]
			Op.DUNES:
				val = _dunes(u, v, _params, p, _noise[i])
			Op.FURROWS:
				val = _furrows(u, v, _params, p, _noise[i])
			Op.CRATER:
				val = _crater(nu, nv, _params, p)
			Op.SCREE:
				val = _scree(u, v, curv, gx, gz, _params, p, _noise[i])
			_:
				continue

		val *= sel

		if flags & FLAG_NEGATE:
			val = -val
		match blend_mode:
			Blend.ADD: acc += val
			Blend.SUB: acc -= val
			Blend.MUL: acc *= val
			Blend.MAX: acc = maxf(acc, val)
			Blend.MIN: acc = minf(acc, val)
			Blend.REPLACE: acc = val
		if flags & FLAG_CLAMP:
			acc = clampf(acc, -1.0, 1.0)
	return acc


## Evaluate one selector against this cell's terrain, returning the multiplier to apply to a gated op.
## Strength lerps between "ungated" (1.0) and the band value, so a selector fades a material out rather
## than deleting it unless you ask for the full gate.
func _selector_value(sid: int, alt: float, slope_deg: float, curv: float,
		flow: float = 0.0, ero: float = 0.0, dep: float = 0.0, wet: float = 0.0,
		measured: Array = [], fi: int = -1) -> float:
	var b := sid * SELECTOR_STRIDE
	if b < 0 or b + SELECTOR_STRIDE > _selectors.size():
		return 1.0
	# SLOPE and CURVATURE are the two filter types a measure_radius applies to (§21.6) — the same
	# measurement over a wider stencil. Everything else reads the one value it always did.
	var wide: Array = []
	if _selectors[b + SELECTOR_RADIUS] > 0.0 and fi >= 0 and sid < measured.size():
		wide = measured[sid]
	var x := float(wide[0][fi]) if not wide.is_empty() else slope_deg
	var ft := int(_selectors[b])
	if ft == 1: # ALTITUDE
		x = alt
	elif ft == 2: # CURVATURE
		x = float(wide[1][fi]) if not wide.is_empty() else curv
	elif ft == 3: # FLOW — m² of catchment, already un-logged by the brush
		x = flow
	elif ft == 4: # EROSION — metres removed, already positive
		x = ero
	elif ft == 5: # DEPOSITION
		x = dep
	elif ft == 6: # WETNESS
		x = wet
	var lo := _selectors[b + 1]
	var hi := _selectors[b + 2]
	var f_lo := maxf(_selectors[b + 3], 0.0)
	var f_hi := maxf(_selectors[b + 4], 0.0)
	# Fade in below the band's floor and out above its ceiling; a zero falloff is a hard cut.
	var rise := 1.0 if x >= lo else (smoothstep(lo - f_lo, lo, x) if f_lo > 0.0 else 0.0)
	var fall := 1.0 if x <= hi else (1.0 - smoothstep(hi, hi + f_hi, x) if f_hi > 0.0 else 0.0)
	var s := clampf(minf(rise, fall), 0.0, 1.0)
	if _selectors[b + 5] != 0.0: # invert
		s = 1.0 - s
	return lerpf(1.0, s, clampf(_selectors[b + 6], 0.0, 1.0))


## Loose rock shed off steep ground: a granular field smeared downhill, piling up where the surface turns
## concave (the toe of a slope, the floor of a gully). Meant to be used WITH a slope selector — the op
## supplies the texture and the deposition, the selector decides where rock is being shed at all.
## p: [0]=amplitude [1]=grain frequency [2]=downslope streak (m) [3]=toe deposition [4]=seed
##
## `curv` is metres of deviation over one cell (§21.6), so the toe ramp is written in metres too. At 1 m
## vertex spacing SCREE_TOE_FULL_M is the ramp the old `clamp(curvature, 0, 1)` was — the two definitions
## differ by exactly vs²/4 there — and at every other spacing it is the one that stays put.
static func _scree(u: float, v: float, curv: float, gx: float, gz: float,
		params: PackedFloat32Array, p: int, n: FastNoiseLite) -> float:
	var su := u
	var sv := v
	var glen := sqrt(gx * gx + gz * gz)
	if glen > 0.000001:
		# Offset the sample downhill so the grain reads as material that has travelled, not as static noise.
		var streak := params[p + 2]
		su = u - (gx / glen) * streak
		sv = v - (gz / glen) * streak
	var val := n.get_noise_2d(su, sv) * params[p]
	var toe := params[p + 3]
	if toe != 0.0:
		val += toe * clampf(curv / SCREE_TOE_FULL_M, 0.0, 1.0)
	return val


## Linear read out of a baked Curve LUT block.
func _sample_lut(slot: int, x: float) -> float:
	var base := slot * CURVE_LUT_N
	if base < 0 or base + CURVE_LUT_N > _luts.size():
		return x
	var f := x * float(CURVE_LUT_N - 1)
	var i0 := int(f)
	if i0 >= CURVE_LUT_N - 1:
		return _luts[base + CURVE_LUT_N - 1]
	var frac := f - float(i0)
	return _luts[base + i0] * (1.0 - frac) + _luts[base + i0 + 1] * frac


## Quantise x in [0,1] into `steps` bands. `hardness` 0 = untouched (identity), 1 = flat benches with
## near-vertical risers. Shared by TERRACE and STRATIFY, which differ only in the coordinate they band.
static func _band(x: float, steps: float, hardness: float) -> float:
	var s := maxf(steps, 1.0)
	var xs := x * s
	var q := floorf(xs)
	var f := xs - q
	return (q + pow(f, 1.0 + clampf(hardness, 0.0, 1.0) * 15.0)) / s


## Asymmetric dune ridges running perpendicular to `direction`: a long windward slope, a short slip face.
## p: [0]=amplitude [1]=wavelength [2]=direction [3]=asymmetry [4]=crest sharpness [5]=wander frequency
##    [6]=wander amount [7]=seed
static func _dunes(u: float, v: float, params: PackedFloat32Array, p: int, n: FastNoiseLite) -> float:
	var dir := params[p + 2]
	var d := u * cos(dir) + v * sin(dir)
	d += n.get_noise_2d(u, v) * params[p + 6]
	var phase := fposmod(d / maxf(params[p + 1], 0.001), 1.0)
	var a := clampf(params[p + 3], 0.01, 0.99)
	var t := (phase / a) if phase < a else (1.0 - (phase - a) / (1.0 - a))
	return (pow(clampf(t, 0.0, 1.0), maxf(params[p + 4], 0.01)) * 2.0 - 1.0) * params[p]


## Parallel corrugation — plough rows, ploughed fields, rice terracing ridges.
## p: [0]=amplitude [1]=spacing [2]=direction [3]=profile(0=V,1=U,2=square) [4]=wobble frequency
##    [5]=wobble amount [6]=seed
static func _furrows(u: float, v: float, params: PackedFloat32Array, p: int, n: FastNoiseLite) -> float:
	var dir := params[p + 2]
	var d := u * cos(dir) + v * sin(dir)
	d += n.get_noise_2d(u, v) * params[p + 5]
	var phase := fposmod(d / maxf(params[p + 1], 0.001), 1.0)
	var a := absf(phase * 2.0 - 1.0) # 0 at the furrow floor, 1 at the ridge
	var profile := int(params[p + 3])
	var f := a
	if profile == 1:
		f = smoothstep(0.0, 1.0, a)
	elif profile == 2:
		f = smoothstep(0.42, 0.58, a)
	return (f * 2.0 - 1.0) * params[p]


## Radial crater profile in normalised loop space: a flattenable bowl, a rim at `1 - rim_width`, and
## ejecta decaying to zero at r = 1. The two branches meet continuously at the rim (both give rim_height).
## p: [0]=amplitude [1]=floor_depth [2]=rim_height [3]=rim_width [4]=ejecta_falloff [5]=floor_flatness
##    [6]=terrace_steps  ([7] reserved for rim wobble)
static func _crater(nu: float, nv: float, params: PackedFloat32Array, p: int) -> float:
	var r := sqrt(nu * nu + nv * nv)
	if r >= 1.0:
		return 0.0
	var floor_depth := params[p + 1]
	var rim_height := params[p + 2]
	var rim_pos := clampf(1.0 - params[p + 3], 0.05, 0.98)
	var val: float
	if r <= rim_pos:
		var t := r / rim_pos
		# Higher exponent = flatter floor and steeper walls; 0 at the rim, -floor_depth at the centre.
		val = -floor_depth * (1.0 - pow(t, 2.0 + 6.0 * params[p + 5]))
		var steps := int(params[p + 6])
		if steps >= 1:
			val = floor(val * steps) / float(steps)
		val += rim_height * smoothstep(0.7, 1.0, t)
	else:
		var s := (r - rim_pos) / (1.0 - rim_pos)
		val = rim_height * pow(1.0 - s, maxf(params[p + 4], 0.01))
	return val * params[p]
