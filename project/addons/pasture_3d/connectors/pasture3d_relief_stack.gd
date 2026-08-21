# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DReliefStack — combines several relief materials into one. Layers are evaluated in order and
# each one enters the accumulator using its own Blend property, so you can lay craggy detail over rolling
# hills, or cut a crater and then roughen it. Stacking is just concatenating the children's compiled op
# programs, so a stack costs exactly what its layers cost — there is no per-layer overhead.
# See PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md §3.
@tool
class_name Pasture3DReliefStack
extends Pasture3DReliefMaterial

## Layers, applied in order. Each layer's own Blend property decides how it enters the accumulator; the
## first layer effectively starts from 0, so ADD and REPLACE behave the same there.
@export var layers: Array[Pasture3DReliefMaterial] = []:
	set(v):
		_disconnect_layers()
		layers = v
		_connect_layers()
		_touch()


func _init() -> void:
	_connect_layers()


func _disconnect_layers() -> void:
	for m in layers:
		if m != null and m.changed.is_connected(_touch):
			m.changed.disconnect(_touch)


func _connect_layers() -> void:
	for m in layers:
		if m != null and not m.changed.is_connected(_touch):
			m.changed.connect(_touch)


## Our own selector's result, plus every child's. Duplicates are left in — the brush dedupes, and it is
## the brush that has to decide what to do when two layers point at DIFFERENT sims.
func sim_results() -> Array:
	var out := super()
	for m in layers:
		if m != null:
			out.append_array(m.sim_results())
	return out


## Our own selector, plus every child's.
func selectors() -> Array:
	var out := super()
	for m in layers:
		if m != null:
			out.append_array(m.selectors())
	return out


func wants_sim_result() -> bool:
	if super():
		return true
	for m in layers:
		if m != null and m.wants_sim_result():
			return true
	return false


func wants_host_profile() -> bool:
	if super():
		return true
	for m in layers:
		if m != null and m.wants_host_profile():
			return true
	return false


func _build() -> void:
	for m in layers:
		if m == null:
			continue
		var prog: Array = m._program()
		var c_ops: PackedInt32Array = prog[0]
		var c_params: PackedFloat32Array = prog[1]
		var c_luts: PackedFloat32Array = prog[2]
		var c_sel: PackedFloat32Array = prog[3]
		var c_fields: PackedFloat32Array = prog[4]
		var c_field_meta: PackedInt32Array = prog[5]
		var c_noise: Array = prog[6]
		var count := c_ops.size() / OP_STRIDE
		# CURVE ops store a slot index into their OWN material's LUT table, DLA ops one into its FIELD
		# table, and gated ops one into its selector table. Splicing the child's tables after ours shifts
		# every one of those indices, so all three offsets have to be applied as we copy.
		#
		# The field table needs one more step than the other two: its blocks are variably sized, so the
		# child's HEADERS carry element offsets into the child's own buffer and must be rebased too.
		var lut_offset := _luts.size() / CURVE_LUT_N
		var sel_offset := _selectors.size() / SELECTOR_STRIDE
		var field_offset := _field_meta.size() / FIELD_META_STRIDE
		var field_base := _fields.size()
		for k in range(c_field_meta.size() / FIELD_META_STRIDE):
			var fm := k * FIELD_META_STRIDE
			_field_meta.append(c_field_meta[fm] + field_base)
			_field_meta.append(c_field_meta[fm + 1])
			_field_meta.append(c_field_meta[fm + 2])
		_fields.append_array(c_fields)
		_luts.append_array(c_luts)
		_selectors.append_array(c_sel)
		# The layer's Blend applies to its first GENERATOR op — a leading WARP is a DOMAIN op that ignores
		# blend entirely, so overriding that one would silently drop the layer's chosen blend.
		var entry := -1
		for i in range(count):
			if _is_generator(c_ops[i * OP_STRIDE]):
				entry = i
				break
		for i in range(count):
			var o := i * OP_STRIDE
			_ops.append(c_ops[o])
			_ops.append(m.blend if i == entry else c_ops[o + 1])
			_ops.append(c_ops[o + 2] if c_ops[o + 2] < 0 else c_ops[o + 2] + sel_offset)
			_ops.append(c_ops[o + 3])
			var base := _params.size()
			_params.resize(base + PARAM_STRIDE)
			for k in range(PARAM_STRIDE):
				_params[base + k] = c_params[i * PARAM_STRIDE + k]
			# Fold the layer's own strength into the op amplitude. Only the top-level material's strength
			# is applied by the brush, so a nested layer's would otherwise be silently ignored.
			if m.strength != 1.0 and _is_generator(c_ops[o]):
				_params[base] *= m.strength
			if c_ops[o] == Op.CURVE:
				_params[base] += lut_offset
			elif c_ops[o] == Op.DLA:
				# NOT an `elif` off the strength branch: DLA is a generator, so a layer strength of 1.5 must
				# scale its amplitude AND its slot must still be rebased. CURVE is safe either way (it is not
				# a generator, so the first branch can never have run) and is left reading as it always did.
				_params[base + DLA_FIELD_SLOT] += field_offset
			_noise.append(c_noise[i])


## The stack raises if any layer that is not purely subtractive raises. A stack of only craters digs.
func _raises() -> bool:
	for m in layers:
		if m != null and m._raises():
			return true
	return false


func _configuration_warning() -> String:
	var live := 0
	for m in layers:
		if m != null:
			live += 1
	if live == 0:
		return "Relief Stack has no layers assigned — the material will not deform anything."
	return ""
