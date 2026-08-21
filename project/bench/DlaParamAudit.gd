# Not a gate, and it has no verdict. Sweeps every exported property of Pasture3DReliefDLA across its
# whole authored range and prints what the material derives from it, so a range that stops working half
# way along shows up as a column of repeated numbers instead of as a complaint from the editor.
#
# It exists because two of them did. Measured before the fix:
#
#   coverage      the cluster's reach topped out at 0.61 of the half-extent however high this went, because
#                 a fixed 38 % of the radius was RESERVED for a blur that only wanted 27 % — and on a
#                 240 m loop that left the relief at exactly 0.00 m for the first 24 m in from the edge
#   detail_size   ridge width saturated at 0.16 and never moved again, so over half the slider was inert
#   resolution    a 64-step slider on a value rounded DOWN to a power of two: 192 behaved as 128, 384 as
#                 256, 768 as 512. Fifteen choices, five of them real
#   hierarchy     a fixed ceiling of 6, when the useful maximum is set by the resolution (5 at 256, 6 at
#                 512, 7 at 1024) — wrong at both ends
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project --script res://bench/DlaParamAudit.gd
extends SceneTree

const N := 256


func _init() -> void:
	print("\n=== Pasture3DReliefDLA: where does each range stop doing anything? ===")
	print("  reach/blur/outer are fractions of the field's HALF-extent (1.00 = the loop edge)\n")

	_sweep("coverage", [0.2, 0.4, 0.6, 0.8, 0.9, 0.95, 1.0])
	_sweep("detail_size", [0.03, 0.08, 0.12, 0.16, 0.20, 0.28, 0.35, 0.42, 0.50])
	_sweep("hierarchy_levels", [1, 2, 3, 4, 5, 6, 7, 8])
	_sweep("resolution", [64, 128, 256, 512, 1024])
	_sweep("blur_levels", [1, 3, 5, 7])
	_sweep("ridge_amount", [0.01, 0.05, 0.10, 0.20, 0.30])
	quit()


func _sweep(p_name: String, p_values: Array) -> void:
	print("-- %s" % p_name)
	print("    %-10s %8s %8s %8s %10s %8s %s" % ["value", "reach", "blur", "outer", "particles", "n0", "radii"])
	for v in p_values:
		var m := Pasture3DReliefDLA.new()
		m.resolution = N
		m.set(p_name, v)
		var n: int = m._grid_size()
		var half := 0.5 * float(n)
		var levels: int = m.hierarchy_levels
		var n0: int = maxi(n >> (levels - 1), 16)
		print("    %-10s %8.3f %8.3f %8.3f %10d %8d %s"
				% [str(v), m._grow_extent(n) / half, float(m._blur_budget(n)) / half,
				m._outer(n) / half, m._particles(), n0, str(m._blur_radii(n))])
