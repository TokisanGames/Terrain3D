# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DMaterial stores shader parameters, and nothing else.
#
# The shader declares inspector groups with `group_uniforms <name>;`. Godot reports each of those
# in the shader parameter list as an entry with PROPERTY_USAGE_GROUP, and _get_property_list() used
# to let them fall through to the code that records parameters. The result was that a group NAME
# went into _active_params -- so _set, _get, _property_can_revert and _property_get_revert all
# claimed to handle it -- and a null entry for it was written into _shader_params, which is saved
# to the .tres. Six of M_terrain.tres's 39 stored "parameters" were group names.
#
# Nothing caught it because every other check in project/bench asserts what the material RENDERS.
# This one asserts what it STORES, which is the only place the defect was ever visible.
#
# Criterion B is the control. A alone is satisfied perfectly by deleting group handling outright,
# which would also delete every heading in the inspector -- so B requires the headings to still be
# there. D is the case that actually accumulates over a project's lifetime.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/MaterialParamsCheck.tscn
extends Node

const DEMO_DATA := "res://demo/data"
const DEMO_MATERIAL := "res://demo/data/M_terrain.tres"
const DEMO_ASSETS := "res://demo/data/assets.tres"

var _fail := 0
var _terrain: Pasture3D
var _material: Pasture3DMaterial


func _ready() -> void:
	print("\n=== Pasture3DMaterial stored parameters ===\n")
	_build()
	await _settle()
	_gate_a_no_group_names_stored()
	_gate_b_inspector_still_grouped()
	_gate_c_real_params_untouched()
	await _gate_d_toggling_a_feature_leaves_nothing()

	print("")
	if _fail == 0:
		print("=== MATERIAL PARAMS CHECK PASS ===")
	else:
		print("=== MATERIAL PARAMS CHECK FAIL (%d) ===" % _fail)
	get_tree().quit(1 if _fail > 0 else 0)


## No group name appears in _shader_parameters, and none is accepted by the public parameter API.
## Group names are scraped from the generated shader rather than hardcoded, so a group added later
## cannot quietly escape this.
func _gate_a_no_group_names_stored() -> void:
	print("[A] no group marker is stored or claimed as a parameter:")
	var groups := _declared_groups()
	print("    shader declares %d groups: %s" % [groups.size(), str(groups)])
	if groups.is_empty():
		print("    !! FAIL (scraped no groups; the check would pass vacuously)")
		_fail += 1
		return

	var stored: Dictionary = _material.get("_shader_parameters")
	var leaked := []
	for g in groups:
		if stored.has(g):
			leaked.append(g)
	var ok_store: bool = leaked.is_empty()
	print("    stored keys=%d, group names among them=%d %s" % [
		stored.size(), leaked.size(),
		"ok" if ok_store else "!! FAIL %s" % str(leaked)])
	if not ok_store:
		_fail += 1

	# _active_params is what gates _set/_get, and is not directly readable. Probe it through the
	# public API: a name the material does not recognise must not round-trip a written value.
	var probe: String = groups[0]
	_material.set_shader_param(probe, 0.5)
	var read_back: Variant = _material.get_shader_param(probe)
	var ok_api: bool = read_back == null
	print("    set_shader_param(\"%s\", 0.5) -> reads back %s %s" % [
		probe, str(read_back),
		"ok" if ok_api else "!! FAIL (a group is being treated as a settable parameter)"])
	if not ok_api:
		_fail += 1


## CONTROL for A. "No groups stored" is trivially satisfied by removing group handling entirely,
## which would strip every heading out of the inspector and look like a fix. Require the headings.
func _gate_b_inspector_still_grouped() -> void:
	print("\n[B] CONTROL, the inspector still has its group headings:")
	var declared := _declared_groups()
	var headings := []
	for p in _material.get_property_list():
		var usage: int = p.get("usage", 0)
		if usage & PROPERTY_USAGE_GROUP or usage & PROPERTY_USAGE_SUBGROUP:
			headings.append(str(p["name"]))
	# Compare on the capitalized display form the property list carries, not the raw uniform name.
	var missing := []
	for g in declared:
		if not (g as String).capitalize() in headings:
			missing.append(g)
	var ok: bool = missing.is_empty() and headings.size() > 0
	print("    %d headings: %s" % [headings.size(), str(headings)])
	print("    every declared group has one: %s %s" % [
		str(missing.is_empty()),
		"ok" if ok else "!! FAIL missing=%s (A proved nothing)" % str(missing)])
	if not ok:
		_fail += 1


## A fix that filtered too broadly would also drop real parameters. Assert one survives end to end.
func _gate_c_real_params_untouched() -> void:
	print("\n[C] real parameters are still stored, settable and readable:")
	const PROBE := "blend_sharpness"
	_material.set_shader_param(PROBE, 0.75)
	var read_back: Variant = _material.get_shader_param(PROBE)
	var stored: Dictionary = _material.get("_shader_parameters")
	var ok: bool = stored.has(PROBE) and typeof(read_back) == TYPE_FLOAT \
		and is_equal_approx(read_back, 0.75)
	print("    stored=%s  set 0.75 -> read %s %s" % [
		str(stored.has(PROBE)), str(read_back), "ok" if ok else "!! FAIL"])
	if not ok:
		_fail += 1


## The accumulation case. Groups behind a disabled //INSERT: are absent from the shader entirely,
## so enabling a feature is what first exposes its group name. Under the old code that wrote the
## name permanently -- disabling the feature again did not take it back out.
func _gate_d_toggling_a_feature_leaves_nothing() -> void:
	print("\n[D] enabling then disabling a feature leaves no group key behind:")
	const NOISE_GROUP := "world_background_noise"
	var before: Dictionary = _material.get("_shader_parameters")
	var present_before: bool = before.has(NOISE_GROUP)

	_material.world_background = Pasture3DMaterial.NOISE
	await _settle()
	var _refresh_on := _material.get_property_list()
	var during: Dictionary = _material.get("_shader_parameters")
	var present_during: bool = during.has(NOISE_GROUP)
	# The group must genuinely be in the shader now, or D is testing nothing.
	var in_shader: bool = NOISE_GROUP in _declared_groups()

	_material.world_background = Pasture3DMaterial.NONE
	await _settle()
	var _refresh_off := _material.get_property_list()
	var after: Dictionary = _material.get("_shader_parameters")
	var present_after: bool = after.has(NOISE_GROUP)

	var ok: bool = in_shader and not present_before and not present_during and not present_after
	print("    group present in shader while enabled: %s %s" % [
		str(in_shader), "" if in_shader else "!! (D is vacuous without this)"])
	print("    stored before=%s during=%s after=%s %s" % [
		str(present_before), str(present_during), str(present_after),
		"ok" if ok else "!! FAIL"])
	if not ok:
		_fail += 1


# ---- fixtures ----------------------------------------------------------------

## Group names as the generated shader declares them, e.g. `group_uniforms mipmaps;` -> "mipmaps".
## Read from the shader rather than a hardcoded list so this tracks the shader as it changes.
## shader_get_code() returns post-preprocessor source, but group_uniforms lines survive that.
func _declared_groups() -> PackedStringArray:
	var code: String = RenderingServer.shader_get_code(_material.get_shader_rid())
	var out := PackedStringArray()
	for line in code.split("\n"):
		var t: String = line.strip_edges()
		if not t.begins_with("group_uniforms"):
			continue
		var rest: String = t.substr("group_uniforms".length()).strip_edges().trim_suffix(";")
		rest = rest.strip_edges()
		if rest.is_empty():  # `group_uniforms;` closes the current group
			continue
		if not rest in out:
			out.append(rest)
	return out


func _build() -> void:
	_terrain = Pasture3D.new()
	_material = load(DEMO_MATERIAL).duplicate(true)
	# add_child BEFORE assigning material/assets: Pasture3D::_initialize() is gated on being inside
	# the tree, so anything assigned earlier is never picked up.
	add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_terrain.material = _material
	_terrain.assets = load(DEMO_ASSETS)
	if _terrain.assets != null:
		_terrain.assets.update_texture_list()
	_material.update(Pasture3DMaterial.TEXTURE_ARRAYS)
	# _shader_params is populated lazily by _get_property_list(); force one pass so the gates below
	# read the state the inspector would have produced.
	var _pl := _material.get_property_list()


func _settle() -> void:
	for i in 3:
		await get_tree().process_frame
