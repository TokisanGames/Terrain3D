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
## Ids 0 and 11 are BURNED, not free. CONST (0) and CLAMP (11) were implemented in both evaluators and
## emitted by no material, so nothing could reach them and no gate could cover them — four holes in the
## 1e-4 m parity claim that no amount of running the gates would ever find (spec §16.6). Deleted 2026-08-22.
## The ids stay spent because they are a WIRE FORMAT: renumbering to close the gap would silently
## reinterpret every op in a program compiled by the other side of a mismatched build.
enum Op {
	FBM = 1, RIDGED = 2, BILLOW = 3, DUNES = 4, FURROWS = 5, CRATER = 6, SCREE = 7,
	WARP = 8, TERRACE = 9, STRATIFY = 10, CURVE = 12, DLA = 13,
}
## How an op's value combines into the accumulator. PROFILE ops ignore this.
enum Blend { ADD = 0, SUB = 1, MUL = 2, MAX = 3, MIN = 4, REPLACE = 5 }

## Wire format (spec §4.1). Mirrored by the C++ evaluator.
const OP_STRIDE := 5     # [op_type, blend, selector_id, flags, selector_id_2]
## Slot of an op's SECOND gate. An op is gated by the product of the two, so a material's own `selector`
## can narrow an op that already carries one of its own — which, before this slot existed, it could not:
## compile() assigned the material's selector only to ops holding NO_SELECTOR, and SCREE holds a real id.
## The property was therefore inert on a Pasture3DReliefScree, with no way round it (a stack's selector
## reaches the same test and skips the same op). See spec §16.3.
##
## TWO SLOTS AND NOT A CHAIN INSIDE THE SELECTOR TABLE. The stack already walks the ops rebasing slot 2,
## so a second slot rebases in the loop that exists; a chain field would need a new walk over a table the
## stack copies wholesale today. And "this op is gated by its own band AND by its material's" is what is
## actually true, which is worth more than one fewer int per op.
const OP_GATE_2 := 4
const PARAM_STRIDE := 12 # per-op float block
# Bits 0-1 are BURNED. They were FLAG_NEGATE and FLAG_CLAMP, set by nothing and therefore covered by no
# gate; see the note on Op above and spec §16.6. Deleted 2026-08-22, and left spent rather than reused,
# because the flags word is a wire format and Blend.SUB already expresses the only one of the two anybody
# reached for.
const FLAG_BAND_SHIFT := 2 # bits 2-3 — which coordinate a PROFILE band op quantises (BandSource)
const FLAG_BAND_MASK := 3 << FLAG_BAND_SHIFT
const NO_SELECTOR := -1  # op is ungated
## [filter_type, min, max, falloff_lo, falloff_hi, invert, strength, radius, field_source]. The stride was
## 8 until the host-profile phase added the last slot; widening it needs no migration because the block is
## never serialised — it is rebuilt from the selector resources on every compile.
const SELECTOR_STRIDE := 9
const SELECTOR_RADIUS := 7 # slot of measure_radius, in METRES; 0 = one cell (spec §21.6)
const SELECTOR_FIELD_SOURCE := 8 # slot of field_source, a Pasture3DReliefSelector.FieldSource

## Which coordinate TERRACE / STRATIFY quantise into bands. Ids MUST stay in sync with ReliefBandSource
## in src/pasture_3d_relief_ops.h.
enum BandSource {
	ACCUMULATOR,      ## band the relief already in the accumulator — the historical behaviour
	HOST_PROFILE,     ## band the host brush's own shape, normalised by the divisor the brush measured
	GROUND_ALTITUDE,  ## band world height out of the below-layer composite, over BAND_RANGE
}
## Param slots carrying a GROUND_ALTITUDE band's world-metre range. 7 and 8 are the lowest pair free in
## BOTH TERRACE (uses 0-4) and STRATIFY (uses 0-6), so one rule covers both ops.
const BAND_RANGE_LO := 7
const BAND_RANGE_HI := 8
const CURVE_LUT_N := 256 # samples per baked Curve, one contiguous block per CURVE op
## Baked 2D FIELDS (spec section 9.1). The Curve LUT idea one dimension up: an op that cannot be
## point-evaluated grows its grid ONCE per compile in GDScript and stores a slot index, and both
## evaluators bilinear-sample the identical bytes. Unlike a LUT the blocks vary in size, so each slot
## carries a header: [offset into _fields, width, height].
const FIELD_META_STRIDE := 3
const DLA_FIELD_SLOT := 1 # param slot of a DLA op's field index (slot 0 is its amplitude)
## Param slot of an op's GAIN — a plain multiplier on the op's gate, defaulting to 1.0. The LAST slot,
## which is free in every op in the catalogue: the widest (STRATIFY) uses 9.
##
## It exists because a Pasture3DReliefStack layer's `strength` was not the operation a host applies. A
## host multiplies the material's whole output; the stack used to fold `strength` into its layers'
## GENERATOR amplitudes, which is exact for a layer of generators and wrong for one carrying a PROFILE op
## — a TERRACE remaps whatever is in the accumulator whether its layer's amplitude was scaled or not, so
## **a layer at `strength = 0` still terraced the stack.** Measured 0.225 apart at 0.5. Spec §16.5.
##
## GAIN MULTIPLIES THE GATE RATHER THAN THE VALUE, which is what makes one slot cover all three op
## categories: `sel` already scales a generator's contribution, a domain op's displacement and a profile
## op's lerp, so `sel == 0` already means "this op did nothing" whatever it is. Layer strength is exactly
## that statement with a number in it, and needed no new mechanism — only a way to say it per op.
const OP_GAIN := 11
## Depth of hollow, in metres over one cell, at which SCREE's toe deposition reaches full strength.
## Sync with RELIEF_SCREE_TOE_FULL_M in src/pasture_3d_relief_ops.h — see _scree.
const SCREE_TOE_FULL_M := 0.25

## Multiplier on top of the brush's Height Scale, so a saved material carries its own intensity.
@export_range(0.0, 4.0, 0.01, "or_greater") var strength: float = 1.0:
	set(v):
		strength = maxf(v, 0.0)
		_touch()
## How this material combines into the accumulator when it is a LAYER OF A Pasture3DReliefStack.
##
## HIDDEN WHEN THE MATERIAL IS NOT IN A STACK, because there it does nothing at all: a host — a
## Pasture3DModRelief, a Mound's relief, a Plow's — evaluates one material into an accumulator that
## starts at 0 and adds the result to the brush's amplitude, and no setting of this changes a single byte
## of that. Measured across all six modes on a directly-assigned material: identical output every time.
## The rule is Pasture3DBrushModifier's, and it is the same rule that hides Evaluation on the modifiers
## that cannot freeze — shipping a control that silently does nothing is worse than not shipping it.
##
## Whether it is in a stack is STRUCTURE, not a value, so flipping it may rebuild the inspector.
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
var _fields := PackedFloat32Array() # concatenated 2D field blocks, indexed through _field_meta
var _field_meta := PackedInt32Array() # stride-3 [offset, w, h], indexed by a field op's slot
var _selectors := PackedFloat32Array() # stride-8 blocks, indexed by an op's selector_id
var _noise: Array = []
var _dirty := true
var _building := false # cycle guard: a stack that (transitively) contains itself must not recurse forever


# Set by Pasture3DReliefStack as it connects and disconnects its layers. A Resource cannot see who holds
# it, so the holder has to say — and the stack is already walking its layers to wire up `changed`, so
# there is no new traversal here, only one more thing done in it. A material held by two stacks, or by a
# stack AND a brush, counts as in a stack: `blend` can act somewhere, which is the question being asked.
var _in_stack := 0


## Called by a Pasture3DReliefStack when this material joins or leaves its layer list.
func _set_stacked(p_yes: bool) -> void:
	var was := _in_stack > 0
	_in_stack = maxi(0, _in_stack + (1 if p_yes else -1))
	if was != (_in_stack > 0):
		notify_property_list_changed()


## Hide `blend` where it cannot act. See the property's own note for why this is not merely tidiness.
func _validate_property(property: Dictionary) -> void:
	if property.name == "blend" and _in_stack <= 0:
		property.usage = PROPERTY_USAGE_NO_EDITOR


## Invalidate the compiled program and notify the brush to re-bake. Every exported setter must call this.
func _touch() -> void:
	_dirty = true
	emit_changed()


## Compile to the flat op program, memoised until _touch().
## Returns [ops, params, luts, selectors, fields, field_meta]. Called ONCE per bake by the plow, never
## per cell - which is what lets a field op (DLA) grow a whole grid in here.
func compile() -> Array:
	if _dirty:
		if _building:
			push_warning("Pasture3DReliefMaterial: cycle detected in a relief stack; skipping '%s'." % resource_path)
			return [PackedInt32Array(), PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array(),
					PackedFloat32Array(), PackedInt32Array()]
		_ops.clear()
		_params.clear()
		_luts.clear()
		_fields.clear()
		_field_meta.clear()
		_selectors.clear()
		_noise.clear()
		_building = true
		_build()
		# This material's own selector gates EVERY op it emitted, not just the generators. An earlier
		# version gated only generators, which left PROFILE ops (TERRACE / STRATIFY) remapping a
		# gated-to-zero accumulator into a non-zero constant — so a fully excluded area still got stepped
		# relief.
		#
		# An op that already carries a gate of its own KEEPS IT AND TAKES THIS ONE TOO, in the second
		# slot, so the two multiply. It used to keep its own and drop this one, which made `selector`
		# silently inert on the one material that gates itself — see OP_GATE_2 and spec §16.3. The second
		# slot is free by construction: nothing but this line ever writes it.
		if selector != null:
			var sid := _emit_selector(selector)
			for i in range(_ops.size() / OP_STRIDE):
				var o := i * OP_STRIDE
				if _ops[o + 2] == NO_SELECTOR:
					_ops[o + 2] = sid
				else:
					_ops[o + OP_GATE_2] = sid
		# The output curve is emitted last so it shapes the finished relief.
		if output_curve != null:
			_emit(Op.CURVE, Blend.ADD, [_bake_curve(output_curve)])
		_building = false
		_dirty = false
	return [_ops, _params, _luts, _selectors, _fields, _field_meta]


## Compiled program plus the parallel noise table, APPENDED so every index compile() defines still
## holds. Only Pasture3DReliefStack needs the noise table (to splice a child's program into its own);
## the plow uses compile() and lets C++ rebuild the noise.
func _program() -> Array:
	return compile() + [_noise]


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


## True when anything here reads the HOST BRUSH'S OWN generated profile: a selector whose Field Source is
## Host Profile, or — on Terraces and Strata, which override this — a Band Source of the same name.
##
## Only a landform brush has a profile to offer. Every other host turns this into a configuration warning
## rather than silently substituting the below-layer fields, so a Field Source set on the wrong kind of
## brush is visible instead of merely disappointing.
func wants_host_profile() -> bool:
	return selector != null and selector.uses_host_profile()


## Hand this material the LOOP'S ORIENTED HALF-EXTENTS, in metres, before compile() is called. A no-op
## for every point-evaluated material, and it has to be: those read `nu,nv` and the host has already
## divided by these two numbers by the time they arrive, so the shape of the loop is not theirs to know.
##
## A material with a BAKED FIELD is the exception, and the reason this hook exists. Its field is a grid
## stretched once over the whole rectangle, so a square grid on a 3:1 loop is a mountain whose every ridge
## is three times wider one way than the other. The field has to be GROWN to the loop's proportions, the
## growth happens inside compile(), and so the proportions have to arrive before it. Only
## Pasture3DReliefDLA overrides this; Pasture3DReliefStack forwards it to its layers.
##
## Handing over `1.0, 1.0` means "isotropic", which is what a host whose frame is a disc (Plow's SCATTER
## mapping, where every instance is radius-normalised) must do.
##
## RETURNS true when the frame actually invalidated something, the way set_seed_surface does. A composite
## needs that answer: its own compiled program is memoised, and a child quietly regrowing its field
## underneath it would leave the composite handing out the bytes it spliced last time. The base is a
## no-op and returns false.
func set_host_frame(_p_ex: float, _p_ez: float) -> bool:
	return false


## True when this material needs the working surface the modifiers ABOVE it produced, before it can
## compile to anything. The host asks before every bake and captures only when something says yes, so a
## material that does not want one costs nothing to ask.
##
## Declared on the base rather than left to `has_method`, which is what the host used to do. A duck-typed
## check answers "did anyone implement this" and the question actually being asked is "does anything in
## this material, at any depth, want a surface" — and those two differ exactly at a composite, which
## implements nothing itself and holds a layer that wants one. That gap is why a stacked DLA's Ridge
## Seeding did nothing. Pasture3DReliefStack overrides both of these to ask its layers.
func wants_seed_surface() -> bool:
	return false


## Hand over the captured surface. RETURNS true when it differs from the one already held, which is the
## host's signal to regrow and bake again — see Pasture3DTerrainBrush._commit_modifier_caches, which
## schedules exactly one more pass on a true and converges because the capture EXCLUDES the material
## reading it.
##
## Unlike set_host_frame this one may call _touch(): the host calls it AFTER the bake, not during, so the
## `changed` it emits is a re-bake request rather than reentrancy.
func set_seed_surface(_p_surface: Dictionary) -> bool:
	return false


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
	_ops.append(NO_SELECTOR) # the second gate; only compile() ever fills it
	var base := _params.size()
	_params.resize(base + PARAM_STRIDE)
	for i in range(mini(p.size(), PARAM_STRIDE)):
		_params[base + i] = float(p[i])
	# Written AFTER the copy, so slot OP_GAIN is reserved: an op may use at most PARAM_STRIDE - 1 params.
	# The widest today uses 9 of 12. A material that needed the twelfth would have to take another slot.
	_params[base + OP_GAIN] = 1.0
	_noise.append(_make_noise(op, _params, base))


## Bake a Curve into the LUT table and return its slot index (the value a CURVE op stores in param 0).
func _bake_curve(c: Curve) -> int:
	var slot := _luts.size() / CURVE_LUT_N
	var base := _luts.size()
	_luts.resize(base + CURVE_LUT_N)
	for i in range(CURVE_LUT_N):
		_luts[base + i] = c.sample_baked(float(i) / float(CURVE_LUT_N - 1))
	return slot


## Append a baked 2D field and return its slot index (the value a field op stores in DLA_FIELD_SLOT).
## `p_data` is row-major, w*h, and is expected to be normalised by its producer - nothing here rescales
## it, because a field whose meaning depended on where it was spliced would be untestable.
func _bake_field(p_data: PackedFloat32Array, w: int, h: int) -> int:
	var slot := _field_meta.size() / FIELD_META_STRIDE
	_field_meta.append(_fields.size())
	_field_meta.append(w)
	_field_meta.append(h)
	_fields.append_array(p_data)
	return slot


## GENERATOR ops compute a value and blend it into the accumulator, and by invariant carry
## their amplitude in param slot 0. DOMAIN (WARP) and PROFILE ops do neither. Mirrored in C++.
##
## DLA is listed separately rather than folded into the range: the ids are a WIRE FORMAT shared with
## src/pasture_3d_relief_ops.h, so a new generator appends at the end and the predicate widens, rather
## than every id shifting to keep one comparison tidy.
static func _is_generator(op: int) -> bool:
	return (op >= Op.FBM and op <= Op.SCREE) or op == Op.DLA


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
## `host_*` are the same three measurements over the HOST BRUSH'S OWN generated shape, for selectors whose
## `field_source` is Host Profile and for a TERRACE / STRATIFY band source of the same name.
## `host_alt` is the brush's own contribution in METRES (the delta it adds, not the absolute world
## height); `host_norm` is that already divided by the divisor the brush measured, so 0 is the rim and 1
## the crest. `host_measured` mirrors `measured` for host-source radius selectors. Defaulted, and
## `has_host` stays false for every caller that passes nothing — a host-source selector then reads a
## defined zero rather than falling back to the below-layer numbers, which would hide a mis-set source.
func eval(u: float, v: float, nu: float, nv: float, inv_ex: float, inv_ez: float,
		alt: float = 0.0, slope_deg: float = 0.0, curv: float = 0.0,
		gx: float = 0.0, gz: float = 0.0,
		flow: float = 0.0, ero: float = 0.0, dep: float = 0.0, wet: float = 0.0,
		measured: Array = [], fi: int = -1,
		host_alt: float = 0.0, host_slope_deg: float = 0.0, host_curv: float = 0.0,
		host_norm: float = 0.0, has_host: bool = false, host_measured: Array = []) -> float:
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
		# TWO gates, multiplied: the op's own (SCREE's slope band) and the material's `selector`. Both
		# read the same cell, so the product is "in the band AND on the slope" — see OP_GATE_2.
		var sid := _ops[o + 2]
		var sel := 1.0
		if sid >= 0:
			sel = _selector_value(sid, alt, slope_deg, curv, flow, ero, dep, wet, measured, fi,
					host_alt, host_slope_deg, host_curv, has_host, host_measured)
		var sid2 := _ops[o + OP_GATE_2]
		if sid2 >= 0:
			sel *= _selector_value(sid2, alt, slope_deg, curv, flow, ero, dep, wet, measured, fi,
					host_alt, host_slope_deg, host_curv, has_host, host_measured)
		# ...and the op's own gain, which is how a stack layer's `strength` reaches every category of op
		# rather than only its generators. 1.0 on everything a material emits directly.
		sel *= _params[p + OP_GAIN]
		var band_source := (flags & FLAG_BAND_MASK) >> FLAG_BAND_SHIFT

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
			var tx := _band_coord(band_source, acc, host_norm, alt, p)
			var jit := _params[p + 2]
			if jit != 0.0:
				tx = clampf(tx + _noise[i].get_noise_2d(u, v) * jit, 0.0, 1.0)
			acc = lerpf(acc, _band(tx, _params[p], _params[p + 1]) * 2.0 - 1.0, sel)
			continue
		if op == Op.STRATIFY:
			# Bands are horizontal in the banded coordinate, then tilted by a linear ramp across the
			# ground (dip, in normalised units per 100 m) and broken up laterally so they are not dead
			# straight.
			var dipdir := _params[p + 3]
			var tilt := _params[p + 2] * (u * cos(dipdir) + v * sin(dipdir)) * 0.01
			tilt += _noise[i].get_noise_2d(u, v) * _params[p + 5]
			# The ACCUMULATOR path folds dip and break-up in BEFORE the -1..1 -> 0..1 remap, exactly as it
			# always did — that expression is what gate BP holds to the byte. The other band sources are
			# already in 0..1, so the same tilt is halved to land at the same visual magnitude, not twice it.
			var w := 0.0
			if band_source == BandSource.ACCUMULATOR:
				w = clampf((acc + tilt) * 0.5 + 0.5, 0.0, 1.0)
			else:
				w = clampf(_band_coord(band_source, acc, host_norm, alt, p) + tilt * 0.5, 0.0, 1.0)
			acc = lerpf(acc, _band(w, _params[p], _params[p + 1]) * 2.0 - 1.0, sel)
			continue
		if op == Op.CURVE:
			acc = lerpf(acc, _sample_lut(int(_params[p]), clampf(acc * 0.5 + 0.5, 0.0, 1.0)) * 2.0 - 1.0, sel)
			continue

		# --- GENERATOR: computes a value and blends it in.
		var val := 0.0
		match op:
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
			Op.DLA:
				# Loop-normalised, exactly like CRATER: the cluster maps once onto the oriented rectangle.
				val = _sample_field(int(_params[p + DLA_FIELD_SLOT]), nu, nv) * _params[p]
			Op.SCREE:
				val = _scree(u, v, curv, gx, gz, _params, p, _noise[i])
			_:
				continue

		val *= sel

		match blend_mode:
			Blend.ADD: acc += val
			Blend.SUB: acc -= val
			Blend.MUL: acc *= val
			Blend.MAX: acc = maxf(acc, val)
			Blend.MIN: acc = minf(acc, val)
			Blend.REPLACE: acc = val
	return acc


## The 0..1 coordinate a PROFILE band op quantises. Mirrors relief_band_coord in C++.
##
## ACCUMULATOR is deliberately spelled as the exact expression it always was, not as a special case of a
## more general one: it is the default on every material authored so far, and gate BP compares it to the
## byte.
func _band_coord(band_source: int, acc: float, host_norm: float, alt: float, p: int) -> float:
	if band_source == BandSource.HOST_PROFILE:
		# Already divided by the host's measured divisor, so 0 is the rim and 1 the crest. Reads a flat 0
		# when the caller built no host fields, which is what makes a Host Profile band on a Plow do
		# visibly nothing rather than something arbitrary.
		return clampf(host_norm, 0.0, 1.0)
	if band_source == BandSource.GROUND_ALTITUDE:
		var lo := _params[p + BAND_RANGE_LO]
		var hi := _params[p + BAND_RANGE_HI]
		var d := hi - lo
		return clampf((alt - lo) / d, 0.0, 1.0) if absf(d) > 1.0e-9 else 0.0
	return clampf(acc * 0.5 + 0.5, 0.0, 1.0)


## Evaluate one selector against this cell's terrain, returning the multiplier to apply to a gated op.
## Strength lerps between "ungated" (1.0) and the band value, so a selector fades a material out rather
## than deleting it unless you ask for the full gate.
func _selector_value(sid: int, alt: float, slope_deg: float, curv: float,
		flow: float = 0.0, ero: float = 0.0, dep: float = 0.0, wet: float = 0.0,
		measured: Array = [], fi: int = -1,
		host_alt: float = 0.0, host_slope_deg: float = 0.0, host_curv: float = 0.0,
		has_host: bool = false, host_measured: Array = []) -> float:
	var b := sid * SELECTOR_STRIDE
	if b < 0 or b + SELECTOR_STRIDE > _selectors.size():
		return 1.0
	# Which of the two parallel field sets the three SHAPE filter types read. Decided before anything is
	# measured, because it picks the grids every read below comes out of. A host-source selector on a host
	# that built no host fields reads zeros — not the below-layer values under another name.
	var host := int(_selectors[b + SELECTOR_FIELD_SOURCE]) == Pasture3DReliefSelector.FieldSource.HOST_PROFILE
	var src_measured: Array = host_measured if host else measured
	# SLOPE and CURVATURE are the two filter types a measure_radius applies to (§21.6) — the same
	# measurement over a wider stencil. Everything else reads the one value it always did.
	var wide: Array = []
	if _selectors[b + SELECTOR_RADIUS] > 0.0 and fi >= 0 and sid < src_measured.size():
		wide = src_measured[sid]
	var base_slope := (host_slope_deg if has_host else 0.0) if host else slope_deg
	var x := float(wide[0][fi]) if not wide.is_empty() else base_slope
	var ft := int(_selectors[b])
	if ft == 1: # ALTITUDE
		x = ((host_alt if has_host else 0.0) if host else alt)
	elif ft == 2: # CURVATURE
		var base_curv := (host_curv if has_host else 0.0) if host else curv
		x = float(wide[1][fi]) if not wide.is_empty() else base_curv
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


## Bilinear read out of a baked 2D field block, in LOOP-NORMALISED coordinates: nu,nv are +/-1 at the
## fitted rect's edge, so they map onto the field's [0,1]x[0,1] extent. Outside that, and for a slot
## that does not exist, the field reads 0 - a defined nothing, so a mis-spliced slot shows up as the op
## contributing nothing rather than as garbage.
## Mirrors relief_sample_field in C++; gate CR holds the two to 1e-4.
func _sample_field(slot: int, nu: float, nv: float) -> float:
	var m := slot * FIELD_META_STRIDE
	if slot < 0 or m + FIELD_META_STRIDE > _field_meta.size():
		return 0.0
	var base := _field_meta[m]
	var w := _field_meta[m + 1]
	var h := _field_meta[m + 2]
	if w < 2 or h < 2 or base < 0 or base + w * h > _fields.size():
		return 0.0
	var fx := (nu * 0.5 + 0.5) * float(w - 1)
	var fy := (nv * 0.5 + 0.5) * float(h - 1)
	if fx < 0.0 or fy < 0.0 or fx > float(w - 1) or fy > float(h - 1):
		return 0.0
	var x0 := int(fx)
	var y0 := int(fy)
	var x1 := mini(x0 + 1, w - 1)
	var y1 := mini(y0 + 1, h - 1)
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	var a := _fields[base + y0 * w + x0]
	var b := _fields[base + y0 * w + x1]
	var c := _fields[base + y1 * w + x0]
	var d := _fields[base + y1 * w + x1]
	return (a * (1.0 - tx) + b * tx) * (1.0 - ty) + (c * (1.0 - tx) + d * tx) * ty


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
