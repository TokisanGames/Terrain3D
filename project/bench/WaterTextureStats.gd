# Statistics of the water detail/foam textures, so a swap can be compensated instead of
# guessed at.
#
# WATER SHADER SPEC sec 8.6 finding 3: the detail texture is a DERIVATIVE map that
# gen_water_textures.py normalised by its own 99.5th percentile and then discarded the
# divisor -- it is printed, never stored. So `detail_strength` is not "slope in m/m", it is
# a number calibrated against one specific PNG's statistics. Swap the PNG and the slope
# changes by the ratio of their rms, silently, in exactly the way that cost a session last
# time (rust speckle near, grey slabs far).
#
# detail_deriv is decoded rg*2-1 and summed over WATER_DETAIL_LAYERS layers, then scaled by
# detail_strength. foam_tex is read .r only and thresholded, so its MEAN is what moves foam
# coverage when the texture changes.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project \
#          --script res://bench/WaterTextureStats.gd
extends SceneTree

const DIR := "res://addons/pasture_3d/extras/shaders/water/"
const DERIV := ["T_water_deriv.png", "OceanDetail.png"]
const FOAM := ["T_water_foam.png", "HeightOceanFoam.png", "NormalOceanFoam.png"]
# Sampling stride. The maps are 1024+; every 4th texel in each axis is 65k samples, which
# settles rms to well under a percent and keeps this a few seconds.
const STRIDE := 4


func _initialize() -> void:
	await process_frame
	print("\n=== Water texture statistics ===\n")
	print("DERIVATIVE MAPS -- decoded as rg*2-1, which is what water_shading.gdshaderinc does")
	print("  %-24s %8s %8s %8s %8s %8s" % ["texture", "format", "rms", "peak", "mean r", "mean g"])
	var deriv_rms := {}
	for f in DERIV:
		var s: Dictionary = _stats(DIR + f, true)
		if s.is_empty():
			continue
		deriv_rms[f] = s["rms"]
		print("  %-24s %8s %8.4f %8.4f %8.4f %8.4f" % [
				f, s["format"], s["rms"], s["peak"], s["mean_r"], s["mean_g"]])

	print("\nFOAM MASKS -- .r only, which is all the shader samples")
	print("  %-24s %8s %8s %8s %8s" % ["texture", "format", "mean", "rms", "max"])
	for f in FOAM:
		var s: Dictionary = _stats(DIR + f, false)
		if s.is_empty():
			continue
		print("  %-24s %8s %8.4f %8.4f %8.4f" % [
				f, s["format"], s["mean_r"], s["rms"], s["peak"]])

	if deriv_rms.has(DERIV[0]) and deriv_rms.has(DERIV[1]):
		var old_rms: float = deriv_rms[DERIV[0]]
		var new_rms: float = deriv_rms[DERIV[1]]
		var ratio: float = new_rms / maxf(old_rms, 1e-6)
		print("\n=== recalibration ===")
		print("  %s rms %.4f -> %s rms %.4f  = x%.3f" % [
				DERIV[0], old_rms, DERIV[1], new_rms, ratio])
		print("  To hold the SAME surface slope, detail_strength must be divided by %.3f:" % ratio)
		for pair in [["ocean", 0.25], ["ocean_low", 0.25], ["lake", 0.18],
				["pond", 0.12], ["river", 0.30]]:
			print("    %-10s %.3f -> %.3f" % [pair[0], pair[1], pair[1] / ratio])
		# CONTROL -- a texture compared with itself must come out at exactly 1.000, or the
		# sampler/decode path is adding a difference of its own and every ratio above is
		# measuring that instead.
		var again: Dictionary = _stats(DIR + DERIV[0], true)
		var self_ratio: float = again["rms"] / maxf(old_rms, 1e-6)
		print("  CONTROL, %s against itself: x%.3f (must be 1.000)" % [DERIV[0], self_ratio])
	quit(0)


func _stats(p_path: String, p_deriv: bool) -> Dictionary:
	var tex: Texture2D = load(p_path)
	if tex == null:
		print("  !! could not load %s" % p_path)
		return {}
	var img: Image = tex.get_image()
	if img == null:
		print("  !! no image for %s" % p_path)
		return {}
	if img.is_compressed():
		img.decompress()
	var n := 0
	var sum_sq := 0.0
	var peak := 0.0
	var sum_r := 0.0
	var sum_g := 0.0
	for y in range(0, img.get_height(), STRIDE):
		for x in range(0, img.get_width(), STRIDE):
			var c := img.get_pixel(x, y)
			n += 1
			sum_r += c.r
			sum_g += c.g
			if p_deriv:
				# Exactly the shader's decode, then the magnitude of the 2D slope vector.
				var dx := c.r * 2.0 - 1.0
				var dy := c.g * 2.0 - 1.0
				var mag := sqrt(dx * dx + dy * dy)
				sum_sq += dx * dx + dy * dy
				peak = maxf(peak, mag)
			else:
				sum_sq += c.r * c.r
				peak = maxf(peak, c.r)
	return {
		"format": str(img.get_format()),
		"rms": sqrt(sum_sq / maxf(n, 1)),
		"peak": peak,
		"mean_r": sum_r / maxf(n, 1),
		"mean_g": sum_g / maxf(n, 1),
	}
