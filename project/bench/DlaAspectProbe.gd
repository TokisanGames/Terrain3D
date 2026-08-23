# Not a gate, and it has no verdict. Answers one editor question: what does a Pasture3DReliefDLA do when
# the loop it is fitted to is not square?
#
# The field is stretched ONCE over the loop's oriented rectangle (nu,nv are +/-1 at its edges), so a
# square field on a 3:1 loop multiplies every ridge width, branch spacing and blur radius by 3 along one
# axis. This measures that directly, in world metres, on both the old behaviour and the new one.
#
# The metric is RIDGE DENSITY: local maxima per metre travelled across the massif, scanned along the
# loop's own two axes. It is self-normalising (maxima divided by the metres actually spent above the
# noise floor), so the massif being longer one way does not by itself move it -- only the ridges being
# WIDER one way does. Isotropic reads 1.00; a field stretched 3:1 reads about 0.33.
#
# Measured 2026-08-21, 90 m x N loops, seed 7, coverage 0.90:
#
#            not told   told
#   1.0:1      0.908    0.908     identical, and they must be: a square loop crops nothing
#   3.0:1      0.408    1.031
#   6.0:1      0.235    1.017
#   9.0:1      0.211    1.147     res 512; 1.233 at res 256, so the residual is RESOLUTION
#
# 0.908 on a square loop is this metric's own noise floor, not an anisotropy -- judge the others against
# that and not against 1.000. The "not told" column tracks 1/aspect, which is the stretch itself.
#
# The residual at 9:1 is not a stretch. The cells are square there too (0.71 m against 0.70 m); what runs
# out is the massif, which at that aspect is about three ridges wide and cannot carry a ridge-spacing
# statistic. It converges with `resolution`, which is what the material's own warning says to raise.
#
# ALSO MEASURED: the texture on an elongated loop follows the SHORT axis, because the blur budget does.
# At 3:1 the ridges come out about three times finer in metres than the same material on a square loop of
# the same length -- and they have to, since a ridge as wide as the square loop's would be wider than the
# elongated loop is deep. `detail_size` still styles it: 0.12 -> 0.30 took the density from 0.19 to 0.13
# per metre with the isotropy intact.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/DlaAspectProbe.tscn
extends Node

## Fraction of the peak below which a sample is "off the massif" and is not scanned.
const FLOOR := 0.05
## Metres between samples. Fine enough to resolve a ridge at the short end of the aspects tested.
const STEP := 0.5
const OUT_DIR := "user://dla_aspect"


func _ready() -> void:
	print("\n=== DLA on a loop that is not square ===\n")
	print("  ridge density = local maxima per metre of massif traversed, along each of the loop's axes")
	print("  ratio = (along the LONG axis) / (along the short axis); 1.00 is isotropic\n")
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	print("  %-32s %8s %9s %9s %8s %7s" % ["", "dims", "per m (u)", "per m (v)", "ratio", "reach"])
	for e in [[90.0, 512, 0.12], [30.0, 512, 0.12], [30.0, 512, 0.30], [30.0, 256, 0.12],
			[15.0, 256, 0.12], [10.0, 256, 0.12], [10.0, 512, 0.12]]:
		for told in [false, true]:
			_run(90.0, e[0], told, e[1], e[2])
	print("\n  fields written to %s\n" % ProjectSettings.globalize_path(OUT_DIR))
	get_tree().quit(0)


func _make(p_res: int, p_detail: float) -> Pasture3DReliefDLA:
	var m := Pasture3DReliefDLA.new()
	m.seed = 7
	m.resolution = p_res
	m.hierarchy_levels = 4
	m.coverage = 0.90
	m.detail_size = p_detail
	m.wander = 0.32
	# LIVE: this probe measures the growth, and FROZEN would hold one field across every arm of the sweep.
	m.evaluation = Pasture3DReliefDLA.Evaluation.LIVE
	return m


func _run(p_ex: float, p_ez: float, p_told: bool, p_res: int, p_detail: float) -> void:
	var mat := _make(p_res, p_detail)
	# The control is not a second code path -- it is this one with the frame withheld, which is exactly
	# what every host did before the material was given somewhere to put it.
	if p_told:
		mat.set_host_frame(p_ex, p_ez)
	var prog: Array = mat.compile()
	var meta: PackedInt32Array = prog[5]
	var dims := "%dx%d" % [meta[1], meta[2]] if meta.size() >= 3 else "none"

	var nx := int(2.0 * p_ex / STEP) + 1
	var nz := int(2.0 * p_ez / STEP) + 1
	var h := PackedFloat32Array()
	h.resize(nx * nz)
	var peak := 0.0
	for iz in range(nz):
		var lz := -p_ez + float(iz) * STEP
		for ix in range(nx):
			var lx := -p_ex + float(ix) * STEP
			var v: float = mat.eval(lx, lz, lx / p_ex, lz / p_ez, 1.0 / p_ex, 1.0 / p_ez)
			h[iz * nx + ix] = v
			peak = maxf(peak, v)
	if peak <= 0.0:
		print("  %-32s %8s   EMPTY FIELD" % ["%.1f:1 res %d" % [p_ex / p_ez, p_res], dims])
		return
	var cut := peak * FLOOR

	# Scan u (rows) and v (columns) with the identical rule, so the two numbers are comparable.
	var du := _density(h, nx, nz, cut, true)
	var dv := _density(h, nx, nz, cut, false)
	# How far out the massif still carries relief, as a fraction of the half-extent, on the SHORT axis --
	# the one an aspect-blind field leaves empty ground on.
	var reach := 0.0
	for iz in range(nz):
		for ix in range(nx):
			if h[iz * nx + ix] > cut:
				reach = maxf(reach, absf(-p_ez + float(iz) * STEP) / p_ez)
	var label := "%.1f:1 res %d detail %.2f %s" % [p_ex / p_ez, p_res, p_detail,
			"TOLD" if p_told else "not told"]
	print("  %-32s %8s %9.4f %9.4f %8.3f %7.2f" % [label, dims, du, dv,
			(du / dv) if dv > 0.0 else INF, reach])
	_write_png(h, nx, nz, peak, "dla_%d_%d_d%d_%s.png" % [int(p_ex / p_ez * 10), p_res,
			int(p_detail * 100), "told" if p_told else "raw"])


## Local maxima per metre traversed above the floor, along rows (u) or columns (v).
func _density(h: PackedFloat32Array, nx: int, nz: int, cut: float, p_rows: bool) -> float:
	var n_outer := nz if p_rows else nx
	var n_inner := nx if p_rows else nz
	var maxima := 0
	var live := 0
	for o in range(n_outer):
		for i in range(1, n_inner - 1):
			var a: float = h[o * nx + (i - 1)] if p_rows else h[(i - 1) * nx + o]
			var b: float = h[o * nx + i] if p_rows else h[i * nx + o]
			var c: float = h[o * nx + (i + 1)] if p_rows else h[(i + 1) * nx + o]
			if b <= cut:
				continue
			live += 1
			if b > a and b >= c:
				maxima += 1
	return float(maxima) / maxf(float(live) * STEP, 0.001)


## One pixel per sample, and the samples are square metres apart in BOTH directions -- so the picture is
## the loop at true proportions and the ridges in it are the shape they will be on the ground.
func _write_png(h: PackedFloat32Array, nx: int, nz: int, peak: float, name: String) -> void:
	var img := Image.create_empty(nx, nz, false, Image.FORMAT_RGB8)
	for iz in range(nz):
		for ix in range(nx):
			var t := clampf(h[iz * nx + ix] / peak, 0.0, 1.0)
			img.set_pixel(ix, iz, Color(t, t, t))
	img.save_png(OUT_DIR.path_join(name))
