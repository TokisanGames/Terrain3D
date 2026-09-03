# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadAlignmentSolver — solves a road's VERTICAL profile: given the terrain under a centreline,
# decide what height the road should be at every metre. See PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §7.
#
# ---- THE PROBLEM ----
#
#   minimise   w_earth  · Σ (z − ground)²                 cut and fill volume
#            + w_smooth · Σ (z[i+1] − z[i])²              ride comfort — no jitter, long steady grades
#            + w_balance· ( Σ (z − ground) )²             net import/export of material
#   subject to |z[i+1] − z[i]| ≤ max_grade · ds           the HARD constraint
#              z[i] = pin[i]                              where the designer said so
#
# The objective is a quadratic, so the unconstrained minimiser is a linear relaxation: each pass sets a
# sample to the weighted average of its neighbours' midpoint (the smoothness term) and the ground under
# it (the earth term). What makes it a road rather than a filtered heightfield are the two PROJECTIONS
# applied after each pass — pins, then the gradient limit.
#
# ---- WHY ALTERNATING PROJECTION, AND WHAT IT COSTS ----
#
# Pins and the gradient limit are both convex sets, so alternating between them converges (POCS) — but
# only if they INTERSECT. Two pins 3 m apart in height and 10 m apart along the road, on a road limited
# to 8%, do not: no profile satisfies both. That case is real (a designer pins a bridge deck and a
# junction), so the solver does not pretend.
#
# PINS WIN. The gradient sweeps never move a pinned sample, so a pin is always honoured exactly and an
# impossible pair surfaces as a GRADIENT BREACH — `feasible` goes false and `peak_grade` sits above the
# limit — rather than as a pin that quietly slid. That is the more useful failure: the designer asked
# for two heights and gets both, plus a report that no road can join them. (`pin_error` is the
# belt-and-braces check that a pin was applied at all; it stays at zero in normal operation.) The caller
# is expected to surface `feasible` rather than build a road that climbs a wall.
#
# The gradient projection is a forward then backward clamping sweep. One forward pass makes every
# consecutive pair legal; the backward pass can break a pair the forward pass fixed, so they alternate
# until the largest violation stops moving. In practice this is a handful of sweeps.
#
# ---- WHAT THE RESULT LOOKS LIKE, AND WHY THAT IS THE POINT ----
#
# The behaviour nobody has to author: the profile CUTS THROUGH A CREST and FILLS A DIP rather than
# following either, because following costs earth-term nothing but costs the smoothness term a great
# deal. It REFUSES A WALL, because the gradient projection is a hard constraint and not a penalty. And
# where the constraint binds against a hillside it produces a long steady climb — a switchback's worth
# of character out of one inequality.
#
# Pure GDScript and pure arithmetic: no terrain, no scene, no engine rebuild. That is deliberate — this
# is the piece most worth being able to test in isolation.
@tool
class_name Pasture3DRoadAlignmentSolver
extends RefCounted

## Default relaxation weights. `w_smooth` dominating `w_earth` is what makes the road a road: a profile
## that hugged the ground would score better on earth and worse on everything a driver notices.
const DEFAULT_W_EARTH: float = 1.0
const DEFAULT_W_SMOOTH: float = 12.0
const DEFAULT_W_BALANCE: float = 0.0
## Relaxation passes. The quadratic is well conditioned and the projections do most of the shaping, so
## this converges long before it matters; it is a cap, not a tuned number.
const DEFAULT_ITERATIONS: int = 240
## Sweeps of the forward/backward gradient projection per iteration.
const GRADE_SWEEPS: int = 4
## Over-relaxation factor for the SOR sweeps. 1.0 is plain Gauss-Seidel; above 1 overshoots each update
## deliberately so the low-frequency error (a long road's overall shape) drains in tens of passes rather
## than thousands. Below 2.0 for stability.
const SOR_OMEGA: float = 1.7
## A gradient violation below this counts as rounding rather than a breach, metres per metre.
const GRADE_EPSILON: float = 1e-5


## Solve a vertical alignment.
##
## `p_ground` is the terrain height under the centreline, sampled every `p_ds` metres.
## `p_max_grade` is the gradient limit as rise/run (0.08 = 8%).
## `p_opts` may carry: `w_earth`, `w_smooth`, `w_balance`, `iterations` (floats/int), and `pins`, a
## Dictionary of {sample index: height} the solve must honour.
##
## ---- `p_force_gdscript` ----
##
## Skips the native delegation and runs the body below. It exists for ONE reason: this file is the
## reference the native solver was written against, and once `ClassDB.class_has_method` started
## answering yes, the body became unreachable in any session with the extension loaded. A parity gate
## that calls `solve` twice is then comparing the native path to itself and passes on any divergence,
## which is the failure mode a parity gate exists to prevent. Nothing in the plugin passes true; it is
## for gates, and for a developer bisecting a profile that looks wrong.
static func solve(p_ground: PackedFloat32Array, p_ds: float, p_max_grade: float,
		p_opts: Dictionary = {}, p_force_gdscript: bool = false) -> Pasture3DRoadAlignment:
	if not p_force_gdscript and ClassDB.class_has_method("Pasture3DUtil", "road_align_solve"):
		var res: Dictionary = Pasture3DUtil.road_align_solve(p_ground, p_ds, p_max_grade, p_opts)
		var out := Pasture3DRoadAlignment.new()
		out.ds = float(res.get("ds", p_ds))
		out.max_grade_used = float(res.get("max_grade_used", p_max_grade))
		out.ground = res.get("ground", p_ground)
		out.z = res.get("z", PackedFloat32Array())
		out.curvature = res.get("curvature", _zeros(p_ground.size()))
		out.bank = res.get("bank", _zeros(p_ground.size()))
		out.peak_grade = float(res.get("peak_grade", 0.0))
		out.feasible = bool(res.get("feasible", true))
		out.cut_volume = float(res.get("cut_volume", 0.0))
		out.fill_volume = float(res.get("fill_volume", 0.0))
		out.pin_error = float(res.get("pin_error", 0.0))
		out.pinned = res.get("pinned", PackedInt32Array())
		return out

	var out := Pasture3DRoadAlignment.new()
	var n := p_ground.size()
	var ds := maxf(p_ds, 1e-4)
	var g_max := maxf(p_max_grade, 1e-4)
	out.ds = ds
	out.max_grade_used = g_max
	out.ground = p_ground.duplicate()
	if n == 0:
		return out
	if n == 1:
		out.z = p_ground.duplicate()
		out.curvature = PackedFloat32Array([0.0])
		out.bank = PackedFloat32Array([0.0])
		return out

	var w_earth := float(p_opts.get("w_earth", DEFAULT_W_EARTH))
	var w_smooth := float(p_opts.get("w_smooth", DEFAULT_W_SMOOTH))
	var w_balance := float(p_opts.get("w_balance", DEFAULT_W_BALANCE))
	var iterations := int(p_opts.get("iterations", DEFAULT_ITERATIONS))
	var pins: Dictionary = p_opts.get("pins", {})
	var smooth_radius := float(p_opts.get("smooth_radius", 0.0))

	# Start from the ground: the feasible-ish starting point closest to the earth term's optimum.
	var z := p_ground.duplicate()
	_apply_pins(z, pins)
	_project_grade(z, ds, g_max, pins)

	for _it in iterations:
		# --- relaxation: a symmetric SOR sweep over the quadratic -----------------------------------
		# Gauss-Seidel IN PLACE, forward then backward, over-relaxed. The choice matters more than it
		# looks: a Jacobi pass moves information one sample per iteration, so a 4 km run would need
		# millions of passes to know its own ends and would quietly return a half-solved profile on long
		# roads while looking perfect on short test fixtures. A symmetric in-place sweep carries the ends
		# across in one pass, and over-relaxation collapses what is left.
		_sor_sweep(z, p_ground, pins, w_earth, w_smooth, true)
		_sor_sweep(z, p_ground, pins, w_earth, w_smooth, false)

		# --- balance: one global shift toward zero net earth movement ------------------------------
		# A shift, not a per-sample term, because moving the whole profile is the only change that
		# alters the net without touching gradient or smoothness at all. Skipped when pins exist: a
		# global shift would fight them, and a pinned profile is not free to float.
		if w_balance > 0.0 and pins.is_empty():
			var net := 0.0
			for i in n:
				net += z[i] - p_ground[i]
			var shift := (net / float(n)) * clampf(w_balance, 0.0, 1.0)
			for i in n:
				z[i] -= shift

		# --- projections: pins, then the hard gradient limit ---------------------------------------
		_apply_pins(z, pins)
		_project_grade(z, ds, g_max, pins)

	_smooth_profile(z, ds, g_max, pins, smooth_radius)

	out.z = z
	out.pinned = _pin_indices(pins)
	_fill_diagnostics(out, pins, ds, g_max)
	# No plan geometry was supplied, so there is no curvature and therefore no banking. A caller that
	# wants banking hands the centreline to `solve_with_plan`.
	out.curvature = _zeros(n)
	out.bank = _zeros(n)
	return out


## Solve, and also derive plan curvature and banking from the centreline. `p_plan` is the centreline in
## world XZ, sampled at the SAME `p_ds` spacing as `p_ground` — one point per height sample.
##
## `p_force_gdscript` is threaded through to `solve`, `plan_curvature` AND `superelevation`, not only to
## the outer call. A forced solve whose curvature and bank still came from the native path would be a
## half-oracle, and the two fields it would silently leave native are exactly the ones a banking bug
## lives in.
static func solve_with_plan(p_plan: PackedVector2Array, p_ground: PackedFloat32Array, p_ds: float,
		p_max_grade: float, p_design_speed: float, p_max_superelevation: float,
		p_opts: Dictionary = {}, p_force_gdscript: bool = false) -> Pasture3DRoadAlignment:
	if not p_force_gdscript and ClassDB.class_has_method("Pasture3DUtil", "road_align_solve_with_plan"):
		var res: Dictionary = Pasture3DUtil.road_align_solve_with_plan(p_plan, p_ground, p_ds,
				p_max_grade, p_design_speed, p_max_superelevation, p_opts)
		var out := Pasture3DRoadAlignment.new()
		out.ds = float(res.get("ds", p_ds))
		out.max_grade_used = float(res.get("max_grade_used", p_max_grade))
		out.ground = res.get("ground", p_ground)
		out.z = res.get("z", PackedFloat32Array())
		out.curvature = res.get("curvature", _zeros(p_ground.size()))
		out.bank = res.get("bank", _zeros(p_ground.size()))
		out.peak_grade = float(res.get("peak_grade", 0.0))
		out.feasible = bool(res.get("feasible", true))
		out.cut_volume = float(res.get("cut_volume", 0.0))
		out.fill_volume = float(res.get("fill_volume", 0.0))
		out.pin_error = float(res.get("pin_error", 0.0))
		out.pinned = res.get("pinned", PackedInt32Array())
		return out

	var out := solve(p_ground, p_ds, p_max_grade, p_opts, p_force_gdscript)
	out.curvature = plan_curvature(p_plan, p_force_gdscript)
	out.bank = superelevation(out.curvature, p_design_speed, p_max_superelevation, p_ds,
			float(p_opts.get("bank_transition_length", 25.0)), p_force_gdscript)
	return out


## Signed plan curvature at each point, 1/metres, POSITIVE TURNING RIGHT — toward +u, the same side the
## grader's `side` and the lane offsets call positive. (The comment here said LEFT until an inverted
## stop line in the editor made someone derive it: in the (x, z) plane the cross below is positive when
## the road turns toward +Z, and right of a +X heading is +Z.) Menger curvature of each
## consecutive triple — the circumscribed circle's reciprocal radius — which is exact for a circular arc
## and stable on a nearly straight run where a finite-difference second derivative is all noise.
##
## PRECISION. The formula is exact; the arithmetic is not. `p_plan` is Vector2 (32-bit), and a curvature
## built from differences of large coordinates loses digits to cancellation — about 1% on a 200 m radius
## sampled at world coordinates of the same order, and worse the further the road sits from the origin.
## Good enough for banking, which is clamped and then smoothed over tens of metres. When P2 feeds this
## from real world-space splines it should hand in plan points RE-CENTRED on the run, which costs
## nothing and removes the cancellation entirely.
static func plan_curvature(p_plan: PackedVector2Array,
		p_force_gdscript: bool = false) -> PackedFloat32Array:
	if not p_force_gdscript and ClassDB.class_has_method("Pasture3DUtil", "road_plan_curvature"):
		return Pasture3DUtil.road_plan_curvature(p_plan)

	var n := p_plan.size()
	var out := _zeros(n)
	if n < 3:
		return out
	for i in range(1, n - 1):
		var a := p_plan[i - 1]
		var b := p_plan[i]
		var c := p_plan[i + 1]
		var v1 := b - a
		var v2 := c - b
		var l1 := v1.length()
		var l2 := v2.length()
		var l3 := (c - a).length()
		if l1 < 1e-6 or l2 < 1e-6 or l3 < 1e-6:
			continue
		var cross := v1.x * v2.y - v1.y * v2.x
		out[i] = float(2.0 * cross / (l1 * l2 * l3))
	# The ends have no triple of their own; copying the neighbour keeps a corner that starts at the
	# very first sample from reading as straight.
	out[0] = out[1]
	out[n - 1] = out[n - 2]
	return out


## Superelevation from curvature: bank = clamp(-v²·κ/g, ±max), then smoothed over `p_transition_length`
## metres so the road rolls into a corner instead of snapping. Physics, not styling — and the same
## number a racing track wants, which is why one formula serves the environment artist and the driver.
static func superelevation(p_curvature: PackedFloat32Array, p_design_speed: float,
		p_max_superelevation: float, p_ds: float, p_transition_length: float = 25.0,
		p_force_gdscript: bool = false) -> PackedFloat32Array:
	if not p_force_gdscript and ClassDB.class_has_method("Pasture3DUtil", "road_superelevation"):
		return Pasture3DUtil.road_superelevation(p_curvature, p_design_speed, p_max_superelevation,
				p_ds, p_transition_length)

	var n := p_curvature.size()
	var out := _zeros(n)
	if n == 0:
		return out
	var v2 := p_design_speed * p_design_speed
	var cap := maxf(p_max_superelevation, 0.0)
	for i in n:
		# NEGATIVE of v²κ/g, and the sign is the whole physics. `bank` is a rise per metre toward +u, and
		# κ > 0 is a turn TOWARD +u — so the centre of that turn is on the +u side and the OUTSIDE of the
		# corner is on -u. Raising the outside therefore means banking negative. The magnitude is v²κ/g
		# either way, which is why this read as correct for so long: the formula was right and the road
		# was tilted into the corner instead of out of it.
		out[i] = clampf(-v2 * p_curvature[i] / 9.81, -cap, cap)
	var half := int(round(maxf(p_transition_length, 0.0) / maxf(p_ds, 1e-4) * 0.5))
	if half <= 0:
		return out
	var smoothed := _zeros(n)
	for i in n:
		var acc := 0.0
		var cnt := 0.0
		for k in range(i - half, i + half + 1):
			acc += out[clampi(k, 0, n - 1)]
			cnt += 1.0
		smoothed[i] = acc / cnt
	return smoothed


# ---- internals ----------------------------------------------------------------------------------

## Bring the profile inside the gradient limit, WITHOUT a direction bias.
##
## The obvious implementation — clamp forward, then clamp backward, repeat — is not a projection. Each
## cascade anchors on the end it starts from and drags the whole profile into a ramp hanging off that
## anchor, so which end the sweep began at leaks into the answer. On a 100 m step it left the road
## sitting on the low side for 2 km and then cutting 74 m out of the high side: feasible, and about four
## times the earthworks of the correct profile, with nothing to indicate anything was wrong.
##
## The fix uses the one property the constraint set has for free — it is CONVEX. A single forward
## cascade produces a feasible profile; so does a single backward cascade; and the average of two
## feasible profiles is feasible. Averaging the two therefore lands inside the set with the direction
## bias cancelled, which is what the alternating version was trying and failing to do. Repeating tightens
## it toward the true nearest point.
##
## Pinned samples are skipped by both cascades, so they are never averaged away — which is what makes an
## impossible pin pair surface as a residual gradient breach rather than as a pin that quietly slid.
static func _project_grade(p_z: PackedFloat32Array, p_ds: float, p_max_grade: float,
		p_pins: Dictionary) -> void:
	var n := p_z.size()
	if n < 2:
		return
	var step := p_max_grade * p_ds
	for _sweep in GRADE_SWEEPS:
		var fwd := p_z.duplicate()
		for i in range(1, n):
			if p_pins.has(i):
				_relax_toward_pin(fwd, p_pins, i, -1, step)
			else:
				fwd[i] = clampf(fwd[i], fwd[i - 1] - step, fwd[i - 1] + step)
		var bwd := p_z.duplicate()
		for i in range(n - 2, -1, -1):
			if p_pins.has(i):
				_relax_toward_pin(bwd, p_pins, i, 1, step)
			else:
				bwd[i] = clampf(bwd[i], bwd[i + 1] - step, bwd[i + 1] + step)
		for i in n:
			if not p_pins.has(i):
				p_z[i] = (fwd[i] + bwd[i]) * 0.5


## Push the constraint back out of a pin, against the direction the cascade is running in.
##
## A cascade only ever checks the pair it is moving INTO, so the pair arriving at a pinned sample is
## never looked at — the cascade skips the pin and carries on. Without this the cascade result is not
## feasible whenever pins are present, and averaging two infeasible profiles is just a smaller breach:
## a satisfiable pin pair came back at nine times its gradient limit and flagged infeasible.
##
## So on reaching a pin, walk `p_dir` away from it clamping as we go, and stop at the first sample that
## already fits — or at the next pin, which is precisely the case where the designer has asked for
## something the limit forbids, and the breach that survives is how they find out.
static func _relax_toward_pin(p_z: PackedFloat32Array, p_pins: Dictionary, p_at: int, p_dir: int,
		p_step: float) -> void:
	var j := p_at + p_dir
	while j >= 0 and j < p_z.size() and not p_pins.has(j):
		var anchor := p_z[j - p_dir]
		var fixed := clampf(p_z[j], anchor - p_step, anchor + p_step)
		if is_equal_approx(fixed, p_z[j]):
			return
		p_z[j] = fixed
		j += p_dir


## One in-place Gauss-Seidel pass with over-relaxation, forward or backward. Each sample moves toward
## the weighted average of its neighbours' midpoint (smoothness) and the ground beneath it (earth) —
## the stationary point of the quadratic in §7. An END sample has one neighbour and is therefore pulled
## half as hard toward smoothness, which is correct rather than a special case: there is nothing beyond
## it to be smooth WITH, and weighting it as if there were curls the ends of every road.
static func _sor_sweep(p_z: PackedFloat32Array, p_ground: PackedFloat32Array, p_pins: Dictionary,
		p_w_earth: float, p_w_smooth: float, p_forward: bool) -> void:
	var n := p_z.size()
	var order := range(n) if p_forward else range(n - 1, -1, -1)
	for i: int in order:
		if p_pins.has(i):
			continue
		var neighbour_sum := 0.0
		var neighbour_count := 0.0
		if i > 0:
			neighbour_sum += p_z[i - 1]
			neighbour_count += 1.0
		if i < n - 1:
			neighbour_sum += p_z[i + 1]
			neighbour_count += 1.0
		var smooth_w := p_w_smooth * neighbour_count * 0.5
		var denom := smooth_w + p_w_earth
		if denom <= 1e-9:
			continue
		var target := (smooth_w * (neighbour_sum / maxf(neighbour_count, 1.0)) + p_w_earth * p_ground[i]) / denom
		p_z[i] = p_z[i] + SOR_OMEGA * (target - p_z[i])


static func _apply_pins(p_z: PackedFloat32Array, p_pins: Dictionary) -> void:
	for k: Variant in p_pins:
		var i := int(k)
		if i >= 0 and i < p_z.size():
			p_z[i] = float(p_pins[k])


static func _pin_indices(p_pins: Dictionary) -> PackedInt32Array:
	var out := PackedInt32Array()
	for k: Variant in p_pins:
		out.append(int(k))
	out.sort()
	return out


static func _fill_diagnostics(p_out: Pasture3DRoadAlignment, p_pins: Dictionary, p_ds: float,
		p_max_grade: float) -> void:
	var n := p_out.z.size()
	var peak := 0.0
	for i in range(1, n):
		peak = maxf(peak, absf(p_out.z[i] - p_out.z[i - 1]) / p_ds)
	p_out.peak_grade = peak
	p_out.feasible = peak <= p_max_grade + GRADE_EPSILON

	var cut := 0.0
	var fill := 0.0
	for i in n:
		var d := p_out.z[i] - p_out.ground[i]
		if d < 0.0:
			cut += -d * p_ds
		else:
			fill += d * p_ds
	p_out.cut_volume = cut
	p_out.fill_volume = fill

	var err := 0.0
	for k: Variant in p_pins:
		var i := int(k)
		if i >= 0 and i < n:
			err = maxf(err, absf(p_out.z[i] - float(p_pins[k])))
	p_out.pin_error = err
	if err > 1e-3:
		p_out.feasible = false


## Conditioning pass on the SOLVED profile: removes bumps shorter than `p_radius` metres. See §3 of
## PASTURE3D_ROAD_JUNCTION_PAINT_AND_SMOOTHING_SPEC.md.
##
## This is NOT the objective's `w_smooth`. That weight trades against the EARTH term, so raising it
## makes the road stop paying for cut and fill and float off the ground — a different road, not a
## smoother one. This runs afterwards and changes only the conditioning, at the elevation the solve
## already chose.
##
## The radius is in METRES, not samples, because `ds` is authorable: a sample-count parameter would
## silently rescale every road the moment the alignment step changed.
##
## Three box passes rather than a Gaussian. They approximate one closely enough that nothing downstream
## can tell, cost O(n) each with a running sum, and have an EXACTLY stated support — which is what lets
## RoadSmoothGate [B] assert the attenuation of each wavelength band against the kernel's own transfer
## function rather than against a guessed threshold.
##
## Ends are clamped (the end sample extends), not wrapped and not zero-padded: a road is not periodic,
## and zero-padding would drag both ends toward zero elevation.
##
## ---- THE RE-PROJECTION IS THE POINT, NOT A TIDY-UP ----
##
## `p_z` arriving here is the output of alternating projection — pins, then the gradient limit. A filter
## over it moves PINNED SAMPLES, so a bridge deck or a junction elevation slides silently and the
## junction resolve loop re-pins against a road that moved; and it can breach the gradient limit next to
## a pin, where the filter pulls a sample toward a neighbour the pin is holding away. So the filter is
## followed by the same two projections the solve itself ends on. `_fill_diagnostics` therefore runs
## AFTER this, or `peak_grade` and `feasible` would describe a profile that is not the one being graded.
##
## Mirrors the native stage in `road_align_solve` (src/pasture_3d_road_grade.cpp) sample for sample.
## RoadSmoothGate [G] compares the two; a change here that is not made there shows up there.
static func _smooth_profile(p_z: PackedFloat32Array, p_ds: float, p_max_grade: float,
		p_pins: Dictionary, p_radius: float) -> void:
	var n := p_z.size()
	var half := int(round(p_radius / p_ds))
	if half < 1 or n < 3:
		return
	var w := float(2 * half + 1)
	var src := p_z.duplicate()
	var dst := p_z.duplicate()
	for _pass in 3:
		# Running sum over the clamped window: sample 0 sees `half + 1` real samples and `half` copies
		# of src[0].
		var sum := float(src[0]) * float(half + 1)
		for i in range(1, half + 1):
			sum += src[mini(i, n - 1)]
		for i in n:
			dst[i] = sum / w
			sum += src[mini(i + half + 1, n - 1)] - src[maxi(i - half, 0)]
		var t := src
		src = dst
		dst = t
	for i in n:
		if not p_pins.has(i):
			p_z[i] = src[i]
	_apply_pins(p_z, p_pins)
	_project_grade(p_z, p_ds, p_max_grade, p_pins)


static func _zeros(p_n: int) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(p_n)
	a.fill(0.0)
	return a
