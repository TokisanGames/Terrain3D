# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Two claims, checked headless.
#
# A. THE ROOT CAUSE. A water body only receives a wave table if its shader DECLARES
#    `_waves`. ShaderMaterial accepts a parameter its shader never heard of and the
#    RenderingServer discards it silently, so "the upload ran" is not evidence the table
#    arrived -- which is how sculpting_2.tscn's ocean sat on bench/legacy/M_ocean.tres
#    ignoring the PoolManager while the pools next to it worked.
#
# B. THE PROPAGATION FIX. Bodies draw with a DUPLICATE of their base material, and a
#    duplicate is a snapshot: tuning the base in the inspector used to leave them drawing
#    the copy taken at load. ShaderMaterial emits NO signal when a parameter changes --
#    verified below, because the obvious fix is a `changed` connection that would quietly
#    never fire -- so the managers poll. This drives that sync directly.
#
# Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path project \
#       --script res://bench/WaterMaterialPropagationCheck.gd
extends SceneTree

const OCEAN_MAT := "res://addons/pasture_3d/extras/shaders/water/M_water_ocean.tres"
const LAKE_MAT := "res://addons/pasture_3d/extras/shaders/water/M_water_lake.tres"
const LEGACY_MAT := "res://bench/legacy/M_ocean.tres"

var _fail := 0


func _initialize() -> void:
	print("\n=== Water material propagation check ===\n")
	# Nodes added to the root during _initialize() are not inside the tree until the first
	# frame. Nothing below depends on tree state -- the cache and the sync are pure -- but a
	# manager that silently never entered the tree is a misleading fixture to leave lying
	# around for whoever adds a criterion that does.
	await process_frame
	_check_a_uniform_declared()
	_check_b_base_edits_propagate()
	_check_c_ocean_uniforms_survive()
	_check_d_detail_group_propagates()
	print("\n=== %s (%d failures) ===\n" % ["PASS" if _fail == 0 else "FAIL", _fail])
	quit(0 if _fail == 0 else 1)


## Does the shader actually declare `_waves`?
func _declares_waves(p_path: String) -> bool:
	var mat := load(p_path) as ShaderMaterial
	if mat == null or mat.shader == null:
		print("    !! %s did not load as a ShaderMaterial" % p_path)
		_fail += 1
		return false
	for u in mat.shader.get_shader_uniform_list():
		if u.get("name", "") == "_waves":
			return true
	return false


# ---- A: the root cause --------------------------------------------------------
# The control is the legacy material. Without it this check could only report "the
# ocean preset has _waves", which is true of every material that never had the bug and
# says nothing about how the bug was diagnosed.
func _check_a_uniform_declared() -> void:
	print("A. `_waves` is declared by the shader, not merely set on the material")
	var ocean_ok := _declares_waves(OCEAN_MAT)
	var lake_ok := _declares_waves(LAKE_MAT)
	var legacy_ok := _declares_waves(LEGACY_MAT)
	print("    M_water_ocean.tres declares _waves: %s (must be true)" % ocean_ok)
	print("    M_water_lake.tres  declares _waves: %s (must be true)" % lake_ok)
	print("    CONTROL, legacy M_ocean.tres       : %s (must be FALSE -- this is the bug)" % legacy_ok)
	if not ocean_ok or not lake_ok:
		_fail += 1
		print("    !! a shipped water preset does not declare _waves")
	if legacy_ok:
		_fail += 1
		print("    !! the legacy material declares _waves, so it was never the explanation")

	# And the upload is accepted regardless, which is why nothing warned.
	var manager := Pasture3DPoolManager.new()
	get_root().add_child(manager)
	var legacy := (load(LEGACY_MAT) as ShaderMaterial).duplicate()
	var before: int = manager.get_upload_count()
	manager.upload_profile_into(legacy, "ocean_default")
	var uploads: int = manager.get_upload_count() - before
	print("    uploads reported into the legacy material: %d (nonzero -- the counter cannot see this)"
			% uploads)
	if uploads == 0:
		_fail += 1
		print("    !! expected the upload to be counted; the diagnosis assumed it was")
	manager.queue_free()


# ---- B: base edits reach the duplicates ---------------------------------------
func _check_b_base_edits_propagate() -> void:
	print("\nB. editing a base material reaches the duplicate bodies draw with")
	var manager := Pasture3DPoolManager.new()
	get_root().add_child(manager)

	# A scene-local copy, so the check never writes to the shipped preset on disk.
	var base := (load(LAKE_MAT) as ShaderMaterial).duplicate()
	var shared := manager.get_material_for(base, "lake_calm") as ShaderMaterial
	if shared == null or shared == base:
		_fail += 1
		print("    !! the manager handed back the base itself; there is no duplicate to test")
		manager.queue_free()
		return

	var rid_before := shared.get_rid()
	var old_scale: float = base.get_shader_parameter("foam_scale")
	var new_scale := old_scale + 0.25
	var table_before: PackedVector4Array = shared.get_shader_parameter("_waves")

	# The premise of the poll: no signal exists to connect to. Both write paths, both
	# candidate signals. If this ever starts firing, the poll can be retired -- so it is
	# asserted rather than assumed.
	var signalled := []
	base.changed.connect(func(): signalled.append("changed"))
	base.property_list_changed.connect(func(): signalled.append("property_list_changed"))
	base.set_shader_parameter("foam_scale", new_scale)
	base.set("shader_parameter/foam_roughness", 0.5)
	print("    signals emitted by a parameter edit: %s (must be empty -- hence the poll)" % [signalled])
	if not signalled.is_empty():
		print("    .. ShaderMaterial now announces edits; sync_material_params could be pushed")

	# What the callers run each editor frame.
	var wrote: bool = Pasture3DPoolManager.sync_material_params(base, shared)

	var got: float = shared.get_shader_parameter("foam_scale")
	print("    base foam_scale %.3f -> %.3f, duplicate now reads %.3f (must match)" % [
			old_scale, new_scale, got])
	if not is_equal_approx(got, new_scale) or not wrote:
		_fail += 1
		print("    !! the edit did not reach the duplicate")

	# CONTROL 1 -- "measured nothing" guard. If the two were equal to begin with, the
	# comparison above would pass without anything having propagated.
	if is_equal_approx(old_scale, new_scale):
		_fail += 1
		print("    !! CONTROL: the value did not actually change; the check proves nothing")

	# CONTROL 2 -- the sync walks every uniform the shader declares, and the base stores
	# no wave table. Copying that nil would erase the table and drop the shader onto its
	# compile-time default, which is the bug in A wearing a different hat.
	var table_after: PackedVector4Array = shared.get_shader_parameter("_waves")
	var table_kept := table_after == table_before and not table_after.is_empty()
	print("    CONTROL, wave table survived the sync: %s (must be true, %d entries)" % [
			table_kept, table_after.size()])
	if not table_kept:
		_fail += 1
		print("    !! the sync erased the wave table it was supposed to leave alone")

	# CONTROL 3 -- the RID must be stable. Re-duplicating would also pass the test above
	# while forcing Pasture3DMesher to rebuild the clipmap on every keystroke, because the
	# mesher bakes this RID into its mesh surfaces.
	var rid_stable := shared.get_rid() == rid_before
	print("    CONTROL, duplicate kept its RID: %s (must be true)" % rid_stable)
	if not rid_stable:
		_fail += 1
		print("    !! the duplicate was replaced rather than updated")

	# CONTROL 4 -- the poll must be idle on an untouched material. A sync that reported
	# work every frame would be fighting whoever writes the plugin-owned uniforms, and on
	# the ocean that means re-uploading the wave table sixty times a second.
	var idle: bool = not Pasture3DPoolManager.sync_material_params(base, shared)
	print("    CONTROL, second sync wrote nothing: %s (must be true)" % idle)
	if not idle:
		_fail += 1
		print("    !! the poll never settles; it will fight the plugin-written uniforms")

	manager.queue_free()


# ---- C: the ocean's own uniforms survive the poll -----------------------------
# The sharpest way this fix could go wrong. M_water_ocean.tres STORES sea_level = 0.0
# and wave_steepness = 0.35, and Pasture3DOcean's duplicate carries this ocean's sea level
# (the node's Y) and the profile's steepness instead. A sync that copied them would reset
# the water to y = 0 every editor frame while the node kept writing it back -- the ocean
# would sit at the wrong height, or flicker between two.
#
# Checked on the OCEAN preset specifically, because the lake material in B has no
# sea_level uniform at all and so cannot see this.
func _check_c_ocean_uniforms_survive() -> void:
	print("\nC. plugin-written uniforms are not clobbered by the poll")
	var base := load(OCEAN_MAT) as ShaderMaterial
	var runtime := base.duplicate() as ShaderMaterial

	# What Pasture3DOcean writes into its private copy.
	const SEA_LEVEL := -11.4
	const MESH_SIZE := 16.0
	runtime.set_shader_parameter("sea_level", SEA_LEVEL)
	runtime.set_shader_parameter("_mesh_size", MESH_SIZE)
	runtime.set_shader_parameter("wave_steepness", 0.52)
	runtime.set_shader_parameter("_waves", PackedVector4Array([Vector4(1.0, 0.0, 1.6, 137.0)]))

	var wrote: bool = Pasture3DPoolManager.sync_material_params(base, runtime)

	var kept := {
		"sea_level": is_equal_approx(runtime.get_shader_parameter("sea_level"), SEA_LEVEL),
		"_mesh_size": is_equal_approx(runtime.get_shader_parameter("_mesh_size"), MESH_SIZE),
		"wave_steepness": is_equal_approx(runtime.get_shader_parameter("wave_steepness"), 0.52),
		"_waves": (runtime.get_shader_parameter("_waves") as PackedVector4Array).size() == 1,
	}
	for name in kept:
		print("    %-15s survived: %s (base stores %s)" % [
				name, kept[name], base.get_shader_parameter(name)])
		if not kept[name]:
			_fail += 1
			print("    !! the poll overwrote a uniform the plugin owns")

	print("    CONTROL, sync reported no work on an untouched base: %s (must be true)" % not wrote)
	if wrote:
		_fail += 1
		print("    !! the ocean's material would be rewritten every editor frame")

	# CONTROL -- and the classifier must not be so broad it skips the art knobs too,
	# which would make B pass for the wrong reason.
	var art_ok := not Pasture3DPoolManager.is_plugin_written_param("foam_scale") \
			and not Pasture3DPoolManager.is_plugin_written_param("deep_color") \
			and Pasture3DPoolManager.is_plugin_written_param("_waves") \
			and Pasture3DPoolManager.is_plugin_written_param("sea_level")
	print("    CONTROL, classifier splits art knobs from plugin ones: %s (must be true)" % art_ok)
	if not art_ok:
		_fail += 1
		print("    !! is_plugin_written_param does not draw the line where it claims")


# ---- D: every Detail uniform, one at a time -----------------------------------
# B proved the mechanism on two floats. The Detail group is what gets tuned in practice
# and it spans three Variant types -- float, vec2 and a sampler2D. A texture is the one
# worth checking rather than assuming: it is the only parameter here that travels as an
# object reference, and get_shader_parameter() is the only route the sync has to it.
func _check_d_detail_group_propagates() -> void:
	print("\nD. the whole Detail group reaches the duplicate")
	var base := (load(OCEAN_MAT) as ShaderMaterial).duplicate()
	var runtime := base.duplicate() as ShaderMaterial

	var edits := {
		"detail_strength": 1.75,
		"detail_scale0": 0.42,
		"detail_scale1": 0.017,
		"detail_flow0": Vector2(-0.9, 0.44),
		"detail_flow1": Vector2(0.13, -0.61),
		"detail_fade_start": 35.0,
		"detail_fade_end": 1234.0,
		"detail_deriv": load("res://addons/pasture_3d/extras/shaders/water/T_water_foam.png"),
	}
	# CONTROL -- every value must actually differ from what the duplicate already holds,
	# or a uniform that never propagates would still read as "matches".
	for name in edits:
		if runtime.get_shader_parameter(name) == edits[name]:
			_fail += 1
			print("    !! CONTROL: %s was already the target value; it proves nothing" % name)
		base.set_shader_parameter(name, edits[name])

	Pasture3DPoolManager.sync_material_params(base, runtime)

	for name in edits:
		var got = runtime.get_shader_parameter(name)
		var ok: bool = got == edits[name]
		print("    %-18s -> %s (%s)" % [name, ok, "matches" if ok else "GOT %s" % got])
		if not ok:
			_fail += 1
			print("    !! %s did not propagate" % name)
