# Pasture3DBuoy Remediation Spec

Authored 2026-08-06, from the code review of `src/pasture_3d_buoy.cpp` against its collaborators
(`Pasture3DPoolManager`, `Pasture3DOcean`, `Pasture3DWaterBody`) and `bench/WaterBodiesPhase6Gate.gd`.

Subordinate to [PASTURE3D_WATER_BODIES_SPEC.md](PASTURE3D_WATER_BODIES_SPEC.md) §9 and §11.9. Where
the two disagree, this document is the newer one and the water bodies spec is amended by Phase 5.

---

## 1. Goal

Phase 6 shipped and its gate passed. The gate was not wrong, but it measured one body implementation
out of two, on a fixture that could not express three of the force model's failure modes. Everything
below is a defect that survived a green gate, which is why every phase here ends by **adding the
criterion that would have caught it** rather than only by fixing the code.

### 1.1 Goals

- The §9.3 budget (64 buoys ≤ 0.5 ms/tick) is true on the body a boat actually floats on — the
  ocean — and not only on a `Pasture3DPool`.
- `sample_interval` reduces cost proportionally, as §9.3 promises, or is removed.
- The force model agrees with the engine's rigid body: its centre of mass, its gravity, its sleep
  state.
- Cost claims are settled by **counting solves**, not by timing. A count is reproducible on a busy
  machine; a millisecond figure is not.

### 1.2 Non-goals

- Hull mesh integration, waterline solving, or any per-buoy shape. `Pasture3DBuoy` stays a sample
  point (§9.1).
- Batched `solve_domain`. §9.3 already declines to build it speculatively and nothing here changes
  that judgement.
- A multi-entry height memo. §2.1 argues one entry per body is the right granularity.
- Steam Deck figures. Same standing caveat as everywhere else in this project.

### 1.3 The defects, and why the gate missed each

| # | Defect | Why Phase 6 passed anyway | Phase |
|---|---|---|---|
| 1 | Two full Gerstner solves per buoy per tick on `Pasture3DOcean` | Criterion E measures a `Pasture3DPool`, which memoises | **1** |
| 2 | `sample_interval` saves nothing now that the pool memoises | Criterion E prints the ratio and asserts nothing on it | **2** |
| 3 | Point velocity uses the body origin as the lever arm, not the centre of mass | The fixture's `BoxShape3D` is centred on the origin, so they coincide | **3** |
| 6 | `gravity_scale` and area gravity overrides are ignored | Every fixture leaves `gravity_scale` at 1 | **3** |
| ~~5~~ | ~~`apply_force` does not wake a sleeping body~~ — **not a defect, retracted §4.4** | The fixture sets `can_sleep = false`, which the review misread as a workaround; it is the gate keeping its measurements clean | **3** |
| 4 | An explicit `water_body` is never checked for tree membership | No criterion sets `water_body` at all | **4** |
| 7 | Angular damping uses the coefficient of whichever buoy runs first | Criterion B gives every buoy the same `angular_drag` | **4** |
| 7b | A frozen body keeps a stale `frac_prev` across the freeze | No criterion freezes anything | **4** |
| 8 | `get_body_displacement()` descends into nested `RigidBody3D`s | No fixture nests a body | **4** |
| — | Property hints disagree with setter clamps; `set_sample_interval` does not refresh warnings | Not gateable as written; Phase 5 makes it gateable | **5** |

---

## 2. Phase 1 — the ocean stops paying twice

### 2.1 The defect

[`pasture_3d_buoy.cpp:38-43`](src/pasture_3d_buoy.cpp:38) claims the containment re-check in
`_resolve_body()` is free:

> *"the second one is free, but only because that memo is there"*

The memo is [`water_body.gd:958`](project/addons/pasture_3d/connectors/water_body.gd:958), keyed on
`(world XZ, physics frame)`. It is GDScript, and it belongs to `Pasture3DWaterBody`.
[`Pasture3DOcean::get_water_height()`](src/pasture_3d_ocean.cpp:379) has no memo, and
[`contains_point()`](src/pasture_3d_ocean.cpp:407) calls straight into it. So on the ocean:

```
_resolve_body()  -> cached->call("contains_point")  -> get_water_height()  -> solve_domain()   #1
apply_buoyancy() -> body->call("get_water_height")  -> get_water_height()  -> solve_domain()   #2
```

Two 16-iteration Gerstner inversions, per buoy, per tick, in open water — the case §9.3's budget
exists for. `body_at()` is not the culprit: it deliberately skips `contains_point` on oceans
([`pasture_3d_pool_manager.cpp:478-490`](src/pasture_3d_pool_manager.cpp:478)). The culprit is the
cached-body fast path, which asks the ocean directly.

### 2.2 The fix

Give `Pasture3DOcean` the same frame-keyed single-entry memo the GDScript body has.

```cpp
// pasture_3d_ocean.h, private
// One entry, keyed on (world XZ, physics frame). See Pasture3DWaterBody.get_water_height():
// this is the same memo, on the other body implementation, for the same reason -- a buoy asks
// this question TWICE per tick at the same position and the second ask is invisible from here.
mutable Vector2 _height_memo_xz;
mutable uint64_t _height_memo_frame = UINT64_MAX;
mutable real_t _height_memo_y = 0.f;
mutable bool _height_memo_valid = false;
```

`get_water_height()` is `const`, hence `mutable`. `UINT64_MAX` as the initial frame is a sentinel the
counter cannot reach; `_height_memo_valid` covers explicit invalidation, so the two are not
redundant.

**Invalidation.** The answer depends on the frame *and* on two pieces of node state. Drop the memo
(`_height_memo_valid = false`) in exactly three places:

- `NOTIFICATION_TRANSFORM_CHANGED` — sea level *is* the node's Y (§6.1).
- `set_domain_origin()` — it is subtracted before the solve.
- `set_wave_profile()` — a different table is a different surface.

This mirrors `water_body.gd`'s `_height_cache_frame = -1` on transform change, which exists for the
identical reason and is the precedent to point at.

**One entry, not a map.** Each body's two queries are *adjacent within one buoy's
`apply_buoyancy()`*, so interleaving 64 buoys still hits: buoy *n* populates, buoy *n* reads, buoy
*n+1* overwrites. A per-position map would cost a hash per query to serve a pattern that a single
slot already serves perfectly, and would then need eviction. Rejected.

**Not a memo in the manager.** Caching inside `solve_domain()` would fix every caller at once and is
the tempting version. Rejected: `solve_domain` takes *domain*-space coordinates that differ per body,
so serving interleaved bodies needs a multi-entry cache with the eviction problem above, and the
manager would be caching on behalf of callers it knows nothing about. One entry per body is the right
granularity because the adjacency that makes it work is a property of the body's own API.

### 2.3 Behavioural consequence, stated on purpose

The manager advances `water_time` in its own `NOTIFICATION_PHYSICS_PROCESS`. If it ticks *after* some
buoys in a frame, those buoys currently see the pre-advance clock and later ones see the post-advance
clock. With the memo, the whole frame sees whichever value was captured first.

This is strictly better — a frame becomes internally consistent where it was not — but it is a
change, and it means a buoy can lag the drawn surface by up to one frame depending on node order.
Criterion H below pins it: parity must not move.

### 2.4 Files

| File | Change |
|---|---|
| `src/pasture_3d_ocean.h` | Four `mutable` members |
| `src/pasture_3d_ocean.cpp` | Memo in `get_water_height()`; invalidation in three places |
| `src/pasture_3d_pool_manager.h/.cpp` | `get_solve_count()` / `reset_solve_count()` — see §2.5 |
| `src/pasture_3d_buoy.cpp` | Rewrite the `:38-43` comment: name *which* body memoises, and that both now do |
| `project/bench/WaterBodiesPhase6Gate.gd` | Criteria F, G, H; ocean fixture |

### 2.5 The instrument: count solves, don't time them

Add to `Pasture3DPoolManager`, bound:

```cpp
int  get_solve_count() const { return _solve_count; }   // cumulative solve_domain() entries
void reset_solve_count() { _solve_count = 0; }
```

`_solve_count` increments on entry to `solve_domain()`. This is the same reasoning that produced
`get_upload_count()` in Phase 1 — *"'how many uploads did that inspector drag cost' is the question
this class exists to answer"* ([`pasture_3d_pool_manager.h:109`](src/pasture_3d_pool_manager.h:109)) —
and it turns every cost claim in this document from a millisecond measurement into an integer
assertion. Keep it after the gate passes, for the same reason `_upload_count` was kept.

### 2.6 Gate criteria (appended to `WaterBodiesPhase6Gate.gd`)

**F. One buoy over an ocean costs one solve per tick.**
Reset the counter, run `apply_buoyancy()` once on a single buoy over a `Pasture3DOcean`, read the
counter. Must be exactly **1**.
*Control:* immediately call `ocean.get_water_height()` at a **different** XZ and require the counter
to read **2**. A counter stuck at 1 would pass the criterion while measuring nothing.

**G. The §9.3 budget holds on the ocean.**
Criterion E's body, re-run against a `Pasture3DOcean` instead of a `Pasture3DPool`: 64 buoys
≤ 0.5 ms/tick, and 64 buoys ≤ **64 solves** per tick.
*Control:* 256 buoys must cost > 2× the time **and** exactly 4× the solves. The solve control is the
load-bearing one; the timing control is inherited from E and is advisory on a shared machine.

**H. The memo does not move the answer.**
Over 200 pseudo-random XZ within 2 km of the origin, across two consecutive physics frames, the
memoised `get_water_height()` must equal a freshly computed
`sea_level + manager.evaluate_height(profile, manager.solve_domain(profile, xz - domain_origin))` —
exact equality, not a tolerance, because it is the same arithmetic.
*Control 1:* move the ocean node in Y **within a frame** and require the next query to change by that
amount — proving invalidation fires.
*Control 2:* perturb `sea_level` between the two halves of the comparison and require the comparison
to **fail** — proving it can detect a mismatch at all.

### 2.7 Risk

Low. The memo is additive and the invalidation set is small and enumerable. The one thing that would
make it wrong is a fourth piece of node state entering `get_water_height()` later without being added
to the invalidation list — criterion H's control 1 is the standing guard against that.

### 2.8 Phase 1 results — measured 2026-08-06 ✅

Godot 4.7-stable, `--headless`, correctness only (`RUN_TIMING` unset). Gate:
[bench/WaterBodiesPhase6Gate.tscn](project/bench/WaterBodiesPhase6Gate.tscn), criteria A–H,
**PASS**.

|  | pre-fix | post-fix |
|---|---|---|
| F — 1 buoy over an ocean | **2** solves/tick | **1** solve/tick |
| G — 64 buoys | **128** solves/tick | **64** solves/tick |
| G — 256 buoys (control) | 512 (exactly 4×) | 256 (exactly 4×) |
| H — memo vs fresh solve, 200 positions | n/a | 0 mismatches, worst **0.000000000 m** |

**The pre-fix column was measured, not inferred.** The memo hit was disabled with a one-word edit,
the extension rebuilt, and the gate re-run: F read 2, G read 128/512, and the gate reported
`FAIL (2)`. Without that run the claim "the ocean pays twice" would have rested on reading the code,
and the whole reason this phase exists is that reading the code is what produced the wrong answer
last time.

Three things worth carrying forward:

- **Criterion H passes on a build with no memo at all** — it tests transparency and invalidation, not
  presence. F and G are what fail when the memo is missing. Noted in the gate so nobody reads H as
  proof the cache is there.
- **Parity was exact**, not merely within the 1e-5 m tolerance the criterion allows. The tolerance is
  there because the reconstruction sums two float32s as doubles across the language boundary and
  could legitimately differ in the last bit; on this profile it does not. Keep the tolerance —
  passing exactly is luck about rounding, not a property worth asserting.
- **The gate now runs headless.** `_settle()` awaited `RenderingServer.frame_post_draw`, which the
  dummy renderer never emits, so `--headless` hung at criterion A with no message — which is why the
  file documented a windowed run. It now awaits `process_frame` when `DisplayServer` is headless.
  Same beat, no GPU, and every correctness criterion can be run without taking the machine.

---

## 3. Phase 2 — `sample_interval` means something again

Depends on Phase 1: the saving is only visible once the ocean is on the same footing, and the
criteria below are written in solve counts, which Phase 1 introduces.

### 3.1 The defect

`sample_interval` is documented in §9.3 as the relief valve for crowds of buoys, and the node repeats
it in a configuration warning ([`pasture_3d_buoy.cpp:333`](src/pasture_3d_buoy.cpp:333)). It throttles
[`apply_buoyancy`'s height read](src/pasture_3d_buoy.cpp:238) only. `_resolve_body()` runs first,
unconditionally, and its `contains_point` call is the query that populates the memo — so the read
being skipped is the one that was already free.

| | interval 1 | interval 2 |
|---|---|---|
| Before the pool memo | 2 solves/tick | 1.5 solves/tick (−25%) |
| Today | 1 solve/tick | **1 solve/tick (−0%)** |

The memo did not make `sample_interval` less useful; it made it useless, by taking its saving for
itself at every interval. That is a good trade and nobody noticed it had happened.

### 3.2 The fix

Make the sample tick and the resolve tick **the same tick**. On a held tick the buoy touches no wave
query at all: it keeps its cached body and its held height, and still recomputes `frac` from its own
current position — the "held height, not held force" principle at
[`:234-237`](src/pasture_3d_buoy.cpp:234) is preserved and is what makes this safe.

```cpp
void Pasture3DBuoy::apply_buoyancy(const double p_delta) {
    RigidBody3D *parent = _parent_body;
    if (!parent) { return; }

    // Physics ticks, not sampling ticks. The counter has to advance even on a held tick or
    // RESOLVE_INTERVAL would silently become RESOLVE_INTERVAL * sample_interval -- four seconds
    // at N=8 -- and a boat leaving a lake would wait that long to notice.
    _ticks_since_resolve++;

    const bool sampling = !_held_valid || _ticks_since_sample >= _sample_interval - 1;
    Node *body = sampling ? _resolve_body() : _get_body();
    if (!body || !body->has_method("get_water_height")) {
        _held_valid = false;   // the next tick samples, so losing a body self-heals immediately
        return;
    }
    const Vector3 pos = get_global_position();
    if (sampling) {
        _held_height = (real_t)(double)body->call("get_water_height", Vector2(pos.x, pos.z));
        _held_valid = true;
        _ticks_since_sample = 0;
    } else {
        _ticks_since_sample++;
    }
    // ... frac, per-body bookkeeping and force application unchanged
}
```

`_ticks_since_resolve++` moves **out of** `_resolve_body()` and into the caller;  `_resolve_body()`
only tests it. Otherwise the forced re-resolve counts sampling ticks and stretches by a factor of N.
The freeze check moves below the per-body bookkeeping — see §5.3.

### 3.3 The contract this changes

`sample_interval` now throttles **body resolution as well as height sampling**. A buoy leaving its
body is noticed within `sample_interval` ticks rather than on the tick it happens. At N = 2 that is
33 ms; at N = 8, 133 ms. §9.2's "on the tick it happens" claim becomes "within `sample_interval`
ticks", and Phase 5 amends the spec to say so.

This is the honest cost of the knob and it is the right trade: the knob exists for *crowds* of buoys,
and a crowd is exactly the population for which a third of a second of handoff latency does not
matter. A hero boat leaves it at 1 and loses nothing — which is already what the warning text says.

### 3.4 Files

| File | Change |
|---|---|
| `src/pasture_3d_buoy.cpp` | Restructure `apply_buoyancy()`; move the tick counter out of `_resolve_body()` |
| `src/pasture_3d_buoy.h` | Comment on `_ticks_since_resolve`: physics ticks, not sampling ticks |
| `project/bench/WaterBodiesPhase6Gate.gd` | Criteria I, J, K |

### 3.5 Gate criteria

**I. The knob buys what it claims.**
Over 8 physics ticks, one buoy over an ocean: interval 1 → **8** solves, interval 2 → **4**,
interval 4 → **2**.
*Control:* interval 1 reading anything other than 8 fails the criterion outright — a counter that
reads 4 at interval 1 is not counting ticks, and would make the 2:1 ratio meaningless.

**J. A held tick still responds to the buoy's own motion.**
A boat at `sample_interval = 4` must settle at the same equilibrium depth as the same boat at
interval 1, within 2% — the criterion A arithmetic, unchanged. This is what proves the *height* is
held and not the *force*.
*Control:* a build that holds the force instead (the boat's Y at interval 4 must diverge) — emulated
in the gate by holding `frac` constant across held ticks and requiring the settle depth to miss.

**K. Handoff latency is bounded by `sample_interval`, and only by it.**
Criterion C's pool → ocean crossing, re-run at interval 4: `get_resolved_body()` must change within
4 ticks of the crossing, and submersion must never read 0 during it.
*Control:* the same crossing at interval 1 must resolve within 1 tick. If both read the same latency,
the test is not sensitive to the interval and proves nothing.

### 3.6 Risk

Medium — this is the only phase that changes when a buoy notices the world changed. The mitigations
are that N defaults to 1 (where behaviour is bit-identical to today), the hint caps N at 8, and
criterion K bounds the worst case in ticks rather than trusting the argument.

### 3.7 Phase 2 results — measured 2026-08-06 ✅

Same harness and conditions as §2.8. Criteria A–K, **PASS**.

| | pre-fix | post-fix |
|---|---|---|
| I — 1 buoy, 8 ticks, N = 1 | 8 solves | 8 solves |
| I — same at N = 2 | **8** solves | **4** solves |
| I — same at N = 4 | **8** solves | **2** solves |
| J — settle depth at N = 4 (predicted −0.333 m) | −0.334 m, 0.0068 m/s residual | unchanged |
| K — handoff latency, N = 1 | 1 tick | 1 tick |
| K — handoff latency, N = 4 | **1** tick | **4** ticks |

The pre-fix column was measured the same way Phase 1's was: `_resolve_body()` restored to every tick,
rebuilt, re-run. `sample_interval` cost the same 8 solves at every N — it saved nothing, at any
setting, exactly as claimed.

Two things the run taught that the spec did not anticipate:

- **Criterion K's bound passed on the broken build.** A latency of 1 tick satisfies "≤ 4", so the
  assertion this phase is nominally about could not detect the defect at all — only the control
  (N = 1 and N = 4 must *differ*) caught it. That is the house rule earning its keep in the most
  literal way available, and it is worth remembering the next time a criterion looks like it can
  stand without one.
- **Criterion J passes on both builds**, and should: what is held between samples did not change in
  this phase. J is a regression net for the restructure, not a test of it. Stated here so a future
  reader does not mistake it for the phase's evidence.

`_ticks_since_resolve` counting physics ticks rather than sampling ticks is load-bearing and is
untested — nothing here runs long enough to reach `RESOLVE_INTERVAL`. If it regressed, the forced
re-resolve would stretch to 30 × N ticks and no criterion would notice. Added to §7.

---

## 4. Phase 3 — the force model against the real body

Three defects, one theme: the model is written against an idealised rigid body and the engine ships a
more specific one. All three are fixed at the same site and share one new mechanism (§4.1), so
splitting them would mean writing that mechanism three times.

### 4.1 The mechanism: `PhysicsDirectBodyState3D`, once per body per frame

The centre of mass under `CENTER_OF_MASS_MODE_AUTO` and the effective gravity including area
overrides are both only available from the body's direct state:

```cpp
PhysicsDirectBodyState3D *st =
        PhysicsServer3D::get_singleton()->body_get_direct_state(parent->get_rid());
```

Both are body-wide and frame-constant, and `BodyTick` is already a per-body-per-frame record that
rotates at [`:258-274`](src/pasture_3d_buoy.cpp:258). Extend it rather than adding a second cache:

```cpp
struct BodyTick {
    uint64_t frame = 0;
    real_t frac_now = 0.f;
    real_t frac_prev = 0.f;
    real_t drag_now = 0.f;      // Phase 4
    real_t drag_prev = 0.f;     // Phase 4
    Vector3 com_offset;         // global-space offset from the body ORIGIN to its centre of mass
    Vector3 gravity;            // total gravity vector: project + gravity_scale + area overrides
    bool    state_valid = false;
};
```

Refreshed in the existing `tick->frame != frame` block, so the cost is one server call per **body**
per frame, not per buoy. The block already runs before the force application, so the first buoy of
the frame both fills and uses it.

`body_get_direct_state()` returns null outside the physics step and for a body the server does not
simulate. On null: `state_valid = false`, `com_offset = Vector3()`, `gravity = Vector3(0, -_gravity()
* parent->get_gravity_scale(), 0)` — i.e. fall back to exactly today's behaviour plus the scale.
`_refresh_gravity()` and `_gravity_cached` stay for this path and no other.

### 4.2 Defect 3 — the lever arm

[`:287-289`](src/pasture_3d_buoy.cpp:287) computes one offset and uses it for two different
conventions:

```cpp
const Vector3 offset = pos - parent->get_global_position();
const Vector3 point_velocity = parent->get_linear_velocity() + parent->get_angular_velocity().cross(offset);
parent->apply_force(buoyant + drag, offset);
```

`apply_force`'s second argument is **origin-relative** — that use is correct and must not change.
`get_linear_velocity()` returns the velocity of the **centre of mass**, so the rigid-body identity is
`v_point = v_com + ω × (pos − com)`. The lever arm must be COM-relative. Under
`CENTER_OF_MASS_MODE_AUTO` Godot derives the COM from the collision shapes, and a hull shape sitting
below its node origin is the ordinary case for a boat — so the drag torque is wrong by `ω × (com −
origin)` on real geometry and right only on the gate's origin-centred box.

```cpp
const Vector3 force_offset = pos - parent->get_global_position();   // apply_force convention
const Vector3 lever        = force_offset - tick->com_offset;       // velocity convention
const Vector3 point_velocity = parent->get_linear_velocity() + parent->get_angular_velocity().cross(lever);
const Vector3 drag = -point_velocity * _linear_drag * frac;
parent->apply_force(buoyant + drag, force_offset);
```

Two names, because one name for two conventions is what caused this.

### 4.3 Defect 6 — gravity

`_refresh_gravity()` reads `physics/3d/default_gravity` and its docstring justifies it as *"buoyancy
has to balance the same gravity the body is falling under"*. `RigidBody3D::gravity_scale` is
precisely that, per body, and appears nowhere in the codebase; nor do `Area3D` gravity overrides.
`st->get_total_gravity()` returns all three composed.

```cpp
const Vector3 g_vec  = tick->gravity;
const real_t  g_mag  = g_vec.length();
const Vector3 up     = g_mag > CMP_EPSILON ? -g_vec / g_mag : Vector3(0.f, 1.f, 0.f);
const Vector3 buoyant = up * (WATER_DENSITY * g_mag * _displacement * frac);
```

**Two decisions worth stating.**

*Buoyancy opposes gravity, rather than always pointing at world up.* Under ordinary gravity the two
are identical, so nothing observable changes; under a tilted area override the physical answer is
`-ĝ`. The class comment at [`:282`](src/pasture_3d_buoy.cpp:282) — *"Up is world up, not the body's
up — a capsized hull is still pushed toward the sky"* — is about the **body's** up, and stays true:
the hull's orientation still does not enter. Rewrite it to say "opposite the gravity the body is
actually under, not the body's own up".

*`get_required_displacement()` does not change.* At equilibrium `ρ·g·V·frac = m·g`, and `g` cancels —
so scaled gravity moves neither the required displacement nor the settling depth. The configuration
warning is already correct and the fix is confined to the force term. This is also criterion M's
whole assertion, which is why it is a sharp test.

### 4.4 Defect 5 — sleeping. ❌ **RETRACTED 2026-08-06: the premise was false.**

**`apply_force()` does wake a sleeping `RigidBody3D` on Godot 4.7.** Measured directly: a body with
`can_sleep = true` and `gravity_scale = 0`, left 300 ticks until `sleeping == true`, then pushed with
`apply_force(0, 4000, 0)` for 60 ticks — it woke and travelled 1968 m. There is no defect here, there
never was, and the `keep_awake` export designed below was built, measured, and removed the same day.

How the error was made, since that is the part worth keeping: the Phase 6 fixture sets
`can_sleep = false` with the comment *"a sleeping body stops integrating, and every criterion here
watches it"*, and the review read that as a workaround for a buoyancy failure. It is not — it is the
gate keeping its own measurements clean, and the comment says so. A plausible mechanism plus a
suggestive comment produced a confident finding about behaviour nobody had run.

What caught it was criterion N's control refusing to fire. The criterion was written expecting to
fail; instead the boat that was supposed to be stuck rose 1.989 m with the water, which is
uninterpretable unless the premise is wrong. Had N been written without a control — as "the
`keep_awake` boat rises", which passes trivially — the export would have shipped, and it would have
looked like it was working.

**Criterion N is kept**, reframed: a boat that has settled and gone to sleep still rises when the
water does. It asserts a real user-facing property that nothing else covers, it now rests on engine
behaviour this plugin does not control, and its control (the boat must actually have been asleep
first) is what stops it from measuring nothing. The original design follows for the record.

---

**Original text, superseded:**

`apply_force` does not wake a sleeping `RigidBody3D`; a settled boat stops responding to the water
entirely. The Phase 6 fixture sets `can_sleep = false`
([`WaterBodiesPhase6Gate.gd:441`](project/bench/WaterBodiesPhase6Gate.gd:441)) with the comment *"a
sleeping body stops integrating"* — the gate works around the defect and neither the guide nor the
spec mentions it.

Add an export:

```cpp
// Keep the parent awake while any of its buoys is in the water.
//
// apply_force() does not wake a sleeping RigidBody3D, so a boat that settles stops responding to
// the water -- it will not rise on the next swell, and nothing indicates why. Godot's sleep
// threshold exists to stop bodies at rest from costing anything, and a floating body is never
// truly at rest, so this is the buoy declining an optimisation that does not apply to it.
//
// Off is legitimate for scenery: a moored barge that may freeze mid-bob costs nothing, and the
// configuration warning says which trade is in force.
@export var keep_awake: bool = true
```

Applied once per body per frame in the `BodyTick` roll, and only when it would do something:

```cpp
if (_keep_awake && tick->frac_prev > 0.f && parent->is_sleeping()) {
    parent->set_sleeping(false);
}
```

Gated on `is_sleeping()` so the common path is a read and not a server write. It deliberately does
**not** touch `can_sleep`: that is the user's property on the user's node, and a helper child
silently rewriting it is worse than the bug.

Configuration warning when `keep_awake` is off and `parent->is_able_to_sleep()` is true:

> `'%s' can sleep and keep_awake is off, so once it settles it will stop responding to the water
> entirely — including to a rising swell. Turn keep_awake on, or set can_sleep = false on the body.`

### 4.5 Files

| File | Change |
|---|---|
| `src/pasture_3d_buoy.h` | `BodyTick` gains `com_offset`, `gravity`, `state_valid`; `_keep_awake`; two includes |
| `src/pasture_3d_buoy.cpp` | Direct-state refresh in the frame roll; lever arm split; gravity vector; wake; warning; bind `keep_awake` |
| `project/bench/WaterBodiesPhase6Gate.gd` | Criteria L, M, N; `_make_boat()` gains COM/gravity_scale/sleep parameters |

### 4.6 Gate criteria

**L. An offset centre of mass does not turn spin into drift.**
A boat with `center_of_mass_mode = CUSTOM`, `center_of_mass = (0, -1.5, 0)`, four buoys, given a pure
spin about Y at 2 rad/s and no linear velocity, must not acquire linear speed above 0.02 m/s over
2 s. With the origin lever arm the `ω × offset` terms no longer cancel about the true COM and the
drag sums to a net force.
*Control:* the same boat with `center_of_mass = (0, 0, 0)` must pass **both** before and after the
fix — proving the criterion is sensitive to the offset and not to something else. And the gate
computes the pre-fix lever arm alongside the new one and requires the two predicted drag sums to
differ by ≥ 10%, so a fixture where they happen to coincide cannot read as a pass.

**M. `gravity_scale` does not move the waterline.**
Two identical boats, `gravity_scale` 1.0 and 2.0. Both must settle at the same predicted depth
`f * full_depth`, within 2%.
*Control:* a third boat whose buoyancy term is deliberately left unscaled (a test-only flag, or
`gravity_scale = 4` against the pre-fix build) must sink — otherwise the criterion cannot distinguish
"scaling is correct" from "scaling is irrelevant here".

**N. A settled boat keeps floating.**
On a real profile (amplitude 0.42), let a boat settle for 5 s with `can_sleep = true` and
`keep_awake = true`. Its Y must still be changing over the final second by more than 1 mm.
*Control:* the same boat with `keep_awake = false` must go static (Y change < 0.1 mm over the final
second). If the control also keeps moving, the body never slept and the criterion measured nothing.

### 4.7 Risk

Low, as built. The `keep_awake` behaviour change that made this phase medium-risk was retracted
(§4.4), so nothing here changes what an existing scene does except to correct two force terms that
were wrong. The direct-state call is the remaining risk — null handling is specified in §4.1 and the
fallback is today's behaviour exactly.

### 4.8 Phase 3 results — measured 2026-08-06 ✅

Same harness and conditions as §2.8. Criteria A–N, **PASS**.

| | pre-fix | post-fix |
|---|---|---|
| L — net drag on a spinning hull, COM at (0, −1.5, 0) | **(0, 0, 0) N** — the origin-arm prediction exactly | **(0, 160, −4797) N** — 160 N from the COM-arm prediction of (0, 0, −4800) |
| M — settle depth at `gravity_scale` 2 (predicted −0.333 m) | **−10.953 m** — it sank | **−0.334 m** |
| M — settle depth at `gravity_scale` 1 | −0.333 m | −0.333 m |
| N — sleeping boat under a 2 m rise | rose 1.991 m | rose 1.991 m (no change; see §4.4) |

Pre-fix column measured by restoring the origin lever arm and the project-gravity buoyant term,
rebuilding, and re-running. Both defects were real and both were large: the lever arm was not a
rounding error but the difference between 4800 N and nothing, and a `gravity_scale = 2` hull sank
outright rather than floating low.

Notes on the numbers:

- **L's 160 N of residual Y** is the fixture, not the model: the hull rotates 0.033 rad during the
  step being measured, so the buoy positions used for the prediction are a third of a degree stale.
  It is 3.3% of the signal against a 25% threshold.
- **L is the criterion this phase turns on**, and it is worth noting why it is a one-tick force
  comparison rather than a simulated behaviour. The first design — "a pure spin must not become
  drift" — was wrong: with a COM below the origin a rolling hull genuinely does sweep its buoys
  sideways, so the correct model produces drift and the buggy one produces less. There was no
  behavioural assertion available without an oracle, so the oracle became the arithmetic itself.
- **`get_required_displacement()` was not touched**, and M is what confirms that was right: `g`
  cancels out of `ρ·g·V·frac = m·g`, so the equilibrium is scale-invariant and the sinking warning
  was already correct.

---

## 5. Phase 4 — resolution and lifecycle

Four independent defects, none of them hot-path, grouped because they all concern the buoy's
bookkeeping rather than its physics.

### 5.1 Defect 4 — an explicit `water_body` is never validated

[`_get_body()`](src/pasture_3d_buoy.cpp:64) resolves an instance id and stops. A body removed from the
tree still answers `has_method("get_water_height")`, and `Pasture3DWaterBody._resolve_manager()`
returns null when not inside the tree — so the query returns the still level with **zero wave
offset** and the boat floats on a phantom flat plane instead of losing its body and falling.

The project already has the guard, in `TargetNode3D::is_valid()`
([`target_node_3d.h:37`](src/target_node_3d.h:37)): inside-tree *and* not queued for deletion.
`Pasture3DPoolManager` uses it for `_sun_light`. The buoy hand-rolls the same instance-id pattern
three times and skips both checks.

**Fix.** Template the existing helper so there is one implementation and no call-site churn:

```cpp
template <typename T>
class TargetNodeT { /* body of today's TargetNode3D, with Node3D -> T */ };

using TargetNode3D = TargetNodeT<Node3D>;   // every existing user, unchanged
using TargetNode   = TargetNodeT<Node>;     // Pasture3DBuoy
```

`_water_body_id` and `_body_id` become `TargetNode _water_body` / `TargetNode _resolved_body`.
`_get_body()` returns `_water_body.is_valid() ? _water_body.ptr() : ...`.

Keep `set_water_body(Node *)` / `get_water_body()` bound with `Node`, unchanged — narrowing to
`Node3D` would be a signature break for no gain, and `TargetNode` is `Node`-typed precisely so it is
not needed.

Add a configuration warning when `water_body` is set to a node without `get_water_height`:

> `water_body is set to '%s', which has no get_water_height() — this buoy will never float. A water
> body is a Pasture3DPool, a Pasture3DStream or a Pasture3DOcean.`

### 5.2 Defect 7 — the angular drag coefficient is child-order dependent

[`:270-273`](src/pasture_3d_buoy.cpp:270) applies `_angular_drag` from whichever buoy happened to run
first that frame, while `frac_prev` is correctly the max across the body's buoys. Buoys on one hull
with different `angular_drag` values therefore give **child-order-dependent physics** — the precise
failure the block's own comment says it exists to prevent:

> *"a hull with two buoys in the water and two in the air damps or does not damp depending on child
> order — the bug this whole block exists to avoid"*

**Fix.** Accumulate the coefficient the same way the fraction is accumulated — as a max, rotated with
the frame:

```cpp
tick->drag_now = MAX(tick->drag_now, _angular_drag);
```

and apply `drag_prev` paired with `frac_prev`. Max, not first-wins and not an average: it is
order-independent, it is the same rule already in force for `frac`, and "the strongest-damping buoy
on the hull sets the hull's damping" is a sentence a user can predict from.

`p_delta` is left as the applying buoy's — the physics delta is uniform within a frame by
construction, and storing it would imply otherwise.

Add a configuration warning when a body's buoys disagree, because the rule is only predictable if you
know it is in force:

> `This body's buoys have different angular_drag values (%.2f … %.2f). Angular damping is applied
> once per body using the largest, so the others have no effect on it.`

That warning makes `set_angular_drag()` need `update_configuration_warnings()` — see Phase 5.

### 5.3 Defect 7b — a freeze carries stale damping across it

The frozen-body early return at [`:223`](src/pasture_3d_buoy.cpp:223) skips the bookkeeping entirely,
so `frac_prev` survives the freeze and the first tick after unfreezing damps against a submersion
from before it.

**Fix.** Reorder: parent guard → tick lookup → freeze check → reset and return.

```cpp
BodyTick *tick = _body_ticks.getptr(body_key);
if (!tick) { _body_ticks.insert(body_key, BodyTick()); tick = _body_ticks.getptr(body_key); }
if (parent->is_freeze_enabled()) {
    tick->frame = frame;
    tick->frac_prev = 0.f;  tick->frac_now = 0.f;
    tick->drag_prev = 0.f;  tick->drag_now = 0.f;
    return;                 // a frozen body integrates nothing; it must also remember nothing
}
```

This inserts an entry for frozen bodies. Harmless: `NOTIFICATION_EXIT_TREE` already erases it, and
that erase is the Phase 6 leak fix which must not regress.

### 5.4 Defect 8 — `get_body_displacement()` counts other bodies' buoys

The traversal at [`:193-203`](src/pasture_3d_buoy.cpp:193) walks the parent's whole subtree without
stopping at a nested `RigidBody3D`. A boat with a dinghy or a turret as a child body counts the
child's buoys toward the parent's total, so the configuration warning reports more displacement than
the hull has. It is asymmetric, too: the dinghy's own buoys correctly find the dinghy via
`_find_parent_body()`.

**Fix.** Do not descend into another `RigidBody3D`:

```cpp
for (int i = 0; i < n->get_child_count(); i++) {
    Node *c = n->get_child(i);
    if (Object::cast_to<RigidBody3D>(c)) { continue; }   // that body's buoys are its own
    stack.push_back(c);
}
```

The invariant, and the thing the gate asserts: **the traversal visits exactly the set of buoys for
which `_find_parent_body()` returns this body.** Stated that way it is one property, checkable
directly, and it stays true if a third kind of body is added later.

### 5.5 Files

| File | Change |
|---|---|
| `src/target_node_3d.h` | Template `TargetNodeT<T>`; `TargetNode3D` and `TargetNode` aliases |
| `src/pasture_3d_buoy.h` | `TargetNode` members replace the two ids; `BodyTick` gains `drag_now`/`drag_prev` |
| `src/pasture_3d_buoy.cpp` | Validity guards; drag max; freeze reset; traversal stop; two warnings |
| `project/bench/WaterBodiesPhase6Gate.gd` | Criteria O, P, Q, R |

### 5.6 Gate criteria

**O. A `water_body` out of the tree is no body.**
Set `water_body` explicitly, tick once and confirm force is applied; `remove_child()` the body, tick
again: `get_resolved_body()` must be null and the boat must be in free fall (Y velocity within 5% of
`-g * delta` over 10 ticks).
*Control:* the same buoy with the body still in the tree must not free-fall. Without it, a boat that
falls for an unrelated reason reads as a pass.

**P. Angular damping is child-order independent.**
Two identical hulls, each with four buoys of `angular_drag` 2, 2, 8, 8 — one hull adds them in that
order, the other reversed. Spun at 2 rad/s, ω after 2 s must agree within 1%.
*Control:* a third hull with all four at `angular_drag = 2` must differ from both by ≥ 20%. If it
does not, the fixture cannot detect a coefficient change and the 1% agreement is vacuous.

**Q. A freeze leaves no residue.**
Spin a submerged boat, freeze it for 30 ticks, unfreeze. ω on the first tick after unfreezing must
equal ω at the moment of freezing within 0.1%.
*Control:* the pre-fix behaviour, emulated by seeding `frac_prev` from before the freeze, must show
a ≥ 2% drop. Without the control, a boat whose ω barely decays reads as a pass.

**R. Nested bodies are not counted.**
A boat with four buoys (0.15 m³ each) and a child `RigidBody3D` dinghy with two buoys (0.30 m³
each). `boat_buoy.get_body_displacement()` must read 0.600, and `dinghy_buoy.get_body_displacement()`
must read 0.600 — and the gate asserts the invariant directly by walking every `Pasture3DBuoy` under
the boat and comparing against the set whose parent body is the boat.
*Control:* the dinghy's total must be non-zero, or nothing was excluded and the criterion is
measuring an empty set.

### 5.7 Risk

Low. Each fix is local and each has a criterion that fails without it. `TargetNodeT` touches an
existing header used by `Pasture3DPoolManager`; the alias keeps every call site identical, and a
clean build is the proof.

### 5.8 Phase 4 results — measured 2026-08-06 ✅

Same harness and conditions as §2.8. Criteria A–R, **PASS**.

| | pre-fix | post-fix |
|---|---|---|
| O — explicit `water_body` removed from the tree | still resolved it; boat fell at **0.00 m/s** on a phantom plane, with `get_global_transform` errors spamming the log | no body; boat falls at 4.78 m/s |
| P — spin left after 0.5 s, buoys `[2,2,8,8]` | **1.0521** | **0.1652** |
| P — same hull, child order `[8,8,2,2]` | **0.1651** | **0.1651** |
| P — all buoys at 2 (reference) | 1.0519 | 1.0519 |
| Q — spin lost on the first tick out of a freeze | **2.458%** (an ordinary tick costs 2.45%) | 0.167% |
| R — hull displacement with a dinghy attached | **1.200 m³** (it owns 0.600) | 0.600 m³ |

**P was much worse than the review estimated.** Reversing child order changed the remaining spin by
**84.3%** — and the `[2,2,8,8]` hull read 1.0521 against the all-2 reference's 1.0519, i.e. the
hull's damping was *exactly* the first buoy's coefficient and the other three were inert. The review
called this "child-order dependent"; it is more precisely "three of four buoys do nothing".

**O's defect announced itself once the fixture existed.** The pre-fix run filled the log with
`Condition "!is_inside_tree()" is true. Returning: Transform3D()` from
`Pasture3DWaterBody._still_surface_y` — the out-of-tree body was being asked for its global
transform every tick, returning identity, and reporting a water level of y = 0. That error was
reachable before this phase and nobody had run the case; the post-fix run logs zero errors.

Two fixture notes, both caught by controls rather than by inspection:

- **Criterion O's first draft settled for 120 ticks** and its control failed: the boat was still
  moving at 0.112 m/s, so "it floats" could not be asserted. Criterion A's 420 ticks fixed it. The
  code was never wrong.
- **Criterion P's first draft ran for 2 s**, by which time both mixed hulls had damped to exactly
  0.0000 — "they agree" was a comparison of two zeros, which is true of any implementation that also
  reaches zero. The window is now 0.5 s, and the control explicitly requires the compared value to
  be non-zero. Worth generalising: an agreement assertion needs a floor as well as a tolerance.

---

## 6. Phase 5 — conventions, inspector, and the paperwork

No behaviour change beyond warning refresh. Last because it is the only phase whose value is
legibility, and legibility should describe the finished thing.

### 6.1 Property hints must match setter clamps

The convention is stated in this codebase, at
[`pasture_3d_ocean.cpp:623`](src/pasture_3d_ocean.cpp:623): *"Ranges match the clamps in the setters
… A hint narrower than the clamp is a slider that stops short of"*. The buoy breaks it twice.

| Property | Hint today | Setter clamp | Resolution |
|---|---|---|---|
| `displacement` | `0.001,10,0.001,or_greater` | `MAX(x, 0)` | Hint min → `0`. Zero displacement is meaningful: "this sample point contributes nothing" |
| `full_depth` | `0.01,5,0.01,or_greater` | `MAX(x, 0.001)` | Hint min → `0.001`, step → `0.001` |

The clamp is the contract; the hint moves to meet it, not the reverse.

### 6.2 Warning refresh

`set_displacement()` and `set_water_body()` call `update_configuration_warnings()`.
`set_sample_interval()` does not, yet `_sample_interval` drives a warning at
[`:333`](src/pasture_3d_buoy.cpp:333) — so changing it in the inspector leaves the panel stale.
Phase 4 adds an `angular_drag` warning, giving `set_angular_drag()` the same obligation.

Add the call to `set_sample_interval()` and `set_angular_drag()`. `set_full_depth()` and
`set_linear_drag()` drive no warning text and stay as they are — the rule is "setters that change
warning text refresh warnings", not "all setters refresh warnings".

### 6.3 Small things

- One form for unpacking a Variant height: `(real_t)(double)`. [`:179`](src/pasture_3d_buoy.cpp:179)
  currently uses implicit conversion where [`:239`](src/pasture_3d_buoy.cpp:239) is explicit.
- Drop the unused `#include "logger.h"` from `pasture_3d_buoy.cpp`. `CLASS_NAME()` comes from
  `constants.h` via the header.

### 6.4 Spec and guide bookkeeping

**`PASTURE3D_WATER_BODIES_SPEC.md` §9.1** — the pseudocode's last two lines are now wrong:

```
com      = parent.centre of mass, world                      # NOT the node origin
v_rel    = parent.linear_velocity + parent.angular_velocity × (global_position - com)
g_vec    = parent.total_gravity                              # project × gravity_scale × area overrides
F_buoy   = ρ_water * |g_vec| * displacement * frac * (-ĝ)
parent.apply_force(F_buoy + F_drag, global_position - parent.global_position)   # origin-relative
parent.angular_velocity *= 1 - max(angular_drag over the body's buoys) * frac_max * delta
```

**§9.2** — "Re-resolved when the cached body's exact test starts failing" becomes "…, checked on
sampling ticks only, so a handoff is noticed within `sample_interval` ticks (§9.3)".

**§9.3** — replace the `sample_interval` bullet: it now throttles resolution and sampling together,
saves in proportion to N, and costs handoff latency in proportion to N. Add the solve-count
instrument and state the budget in solves as well as milliseconds.

**§11** phase table, row 6 — append the remediation and point at the new results section.

**§11.12** — new section, results for all five phases, in the established format.

**§12** — retire the row *"Phase 6's buoy budget passes with 17% of margin on a square lake"*: it is
superseded by a budget measured on the ocean in solve counts. Add what remains open (§7 below).

**`PASTURE3D_WATER_GUIDE.md`** — no new export to document (`keep_awake` was retracted, §4.4), but
the buoyancy section should say that a floating body may sleep and is woken by the buoyancy force
itself, because "my boat froze" is a question the guide can now answer in one line.

### 6.5 Gate criteria

**S. Warnings refresh when the text would change.**
Read `get_buoyancy_warnings()`, set `sample_interval = 4`, read again: the content must differ.
Repeat for `angular_drag` against a sibling buoy with a different value.
*Control:* setting `linear_drag` must **not** change the content. Without it the criterion passes for
a node that rebuilds its warnings unconditionally, which is not what is being asserted.

**T. Hints match clamps, mechanically.**
For each of `displacement`, `full_depth`, `linear_drag`, `angular_drag`, `sample_interval`: parse the
range hint from `get_property_list()`, then probe the clamp by assigning `-1e9` and reading back. The
hint minimum must equal the observed clamp floor.
*Control:* the gate asserts against one deliberately wrong hint injected at test time and requires
the check to fail. A hint parser that silently matches nothing would otherwise pass everything.

### 6.6 Risk

None to runtime behaviour. The risk is documentation drift in the other direction — §9.1's pseudocode
becoming the thing nobody updates next time. Criterion L's assertion is written against the
pseudocode's terms deliberately, so a future change to the model that does not update §9.1 fails a
gate rather than aging quietly.

---

## 7. What this does not fix

| Open item | Why not |
|---|---|
| Batched `solve_domain` — one call taking an array of positions | §9.3 declines to build it speculatively. After Phase 1 the budget is one solve per buoy per tick, which is the floor for an unbatched design; batching is the next step only if a gate says so |
| A multi-entry height memo | §2.1. The adjacency that makes one entry work is a property of the body API and would have to stop being true first |
| Hull mesh integration / waterline solving | §1.2, and §9.1's whole premise |
| Buoy-count-dependent COM caching for bodies whose shapes change mid-frame | `BodyTick` refreshes the COM once per frame. A body whose collision shape is swapped mid-frame reads a one-frame-stale COM. Not modelled: shape swaps are not a per-frame operation |
| Steam Deck figures | Inherited standing caveat |
| **The forced re-resolve interval is ungated.** `_ticks_since_resolve` must count physics ticks, not sampling ticks, or `RESOLVE_INTERVAL` stretches to 30 × `sample_interval` — four seconds at N = 8 for a boat waiting to notice it has left a lake. No criterion runs the 30+ ticks needed to see it. A criterion would have to park a buoy where the containment test keeps succeeding while the registry answer has changed underneath it, which is a fiddlier fixture than anything here; noted rather than built | §3.7 |

---

## 8. Running the gates

```bash
Godot_v4.7-stable_win64_console.exe --path project bench/WaterBodiesPhase6Gate.tscn
```

Correctness criteria (F, H, I, J, K, L, M, N, O, P, Q, R, S, T) run headless and unconditionally.

**Timing criteria (E, G) stay behind `RUN_TIMING=1` and must not be run without asking first** — this
machine shares a GPU with another engine, and a contended run produces a number that looks like a
regression. Everything load-bearing in this document is asserted in solve counts precisely so the
phases can be verified without booking the machine.

The house rules from §11 hold throughout: every criterion carries a control that must fail, completed
criteria are counted so a criterion that throws part-way cannot read as a pass, and "measured
nothing" must be distinguishable from "measured well".
