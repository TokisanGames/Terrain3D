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
			m._set_stacked(false)


## Wire up each layer's `changed`, and tell it that it IS a layer — which is what un-hides its Blend.
## The two are done together, and gated on the same test, so a material can never end up marked as stacked
## by a stack that is not listening to it.
func _connect_layers() -> void:
	for m in layers:
		if m != null and not m.changed.is_connected(_touch):
			m.changed.connect(_touch)
			m._set_stacked(true)


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


## Forward the loop's proportions down, so a baked-field layer (a DLA) grows its field to the shape of
## the loop it is going to be stretched over. Not conditional on anything: the base is a no-op, and a
## stack that asked its layers first would need one more virtual to ask WITH — which is the same forward,
## twice.
func set_host_frame(p_ex: float, p_ez: float) -> bool:
	var moved := false
	for m in layers:
		if m != null and m.set_host_frame(p_ex, p_ez):
			moved = true
	# A layer that regrew invalidated THIS program too: the splice copied the child's field bytes into
	# `_fields`, so a memoised stack would keep serving the mountain the loop used to be. Set directly
	# rather than through _touch() for the same reason the child does — see Pasture3DReliefDLA.
	if moved:
		_dirty = true
	return moved


## Ask every layer, at any depth. A stack implements no seeding of its own; what it has to get right is
## that a DLA inside it is not invisible to the host's capture — the host asks the material it was handed,
## and what it was handed is this.
func wants_seed_surface() -> bool:
	for m in layers:
		if m != null and m.wants_seed_surface():
			return true
	return false


## Hand the captured surface to every layer, and DO NOT stop at the first taker: two seeded layers in one
## stack both need it, and `or` short-circuits.
##
## No `_dirty` of our own here, unlike set_host_frame — a layer that accepted a new surface calls _touch(),
## which emits `changed`, which _connect_layers has already wired to ours. The frame hook cannot use that
## path because it runs during a bake; this one runs after.
func set_seed_surface(p_surface: Dictionary) -> bool:
	var moved := false
	for m in layers:
		if m != null and m.set_seed_surface(p_surface):
			moved = true
	return moved


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
			# The second gate indexes the same table as the first, so it rebases the same way.
			var g2 := c_ops[o + OP_GATE_2]
			_ops.append(g2 if g2 < 0 else g2 + sel_offset)
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


## Our own complaint, plus every layer's — the last accessor that did not ask its layers, and the same
## defect shape as the seeding one (spec §16.2). A material that knows how to say "Base Amount fights the
## Host Profile" or "I am still waiting for a surface" fell silent the moment it became a layer, which is
## how a broken stack came to look exactly like a working one.
##
## EVERY complaint and not just the first: the failure being fixed is a hidden complaint, and returning
## one of several is that failure with a smaller radius. They are joined with newlines because the host
## appends this as a single warning entry (Pasture3DTerrainBrush._relief_warnings) and the signature is
## one String — widening it would touch every material in the catalogue for no gain here.
##
## Each layer's line names the layer, because "hardness is 0" is not actionable in a stack of four. A
## nested stack prefixes again, which is what makes the path readable rather than just the leaf.
func _configuration_warning() -> String:
	var own := _own_warning()
	var out := PackedStringArray()
	if not own.is_empty():
		out.append(own)
	for i in range(layers.size()):
		var m: Pasture3DReliefMaterial = layers[i]
		if m == null:
			continue
		var w := m._configuration_warning()
		if w.is_empty():
			continue
		# Prefix EVERY line, not the string. A nested stack hands back one line per complaint, and
		# prefixing only the first leaves its second complaint reading as though it came from this level.
		for line in w.split("
"):
			out.append("Layer %d (%s): %s" % [i + 1, _layer_name(m), line])
	return "\n".join(out)


## The name to call a layer in a warning: what the user typed, or the class with the prefix stripped —
## the same rule Pasture3DBrushModifier.display_name uses, for the same reason.
func _layer_name(m: Pasture3DReliefMaterial) -> String:
	if not m.resource_name.is_empty():
		return m.resource_name
	var s: Script = m.get_script()
	return String(s.get_global_name()).trim_prefix("Pasture3DRelief") if s != null else "Relief"


## The stack's OWN complaint, split out so _configuration_warning can put it first and still forward.
func _own_warning() -> String:
	var live := 0
	var first = null
	for m in layers:
		if m != null:
			live += 1
			if first == null:
				first = m
	if live == 0:
		return "Relief Stack has no layers assigned — the material will not deform anything."
	# The accumulator starts at 0, so the FIRST layer's blend is arithmetic against zero. ADD, SUB and
	# REPLACE are all sensible there; MUL multiplies the layer away entirely and MIN keeps only the half of
	# it that is below ground. Both look exactly like "blend does nothing", which is the complaint this
	# warning exists to pre-empt — it is the same trap in the other direction from a hidden Blend.
	if first != null and (first.blend == Blend.MUL or first.blend == Blend.MIN):
		return (("The first layer's Blend is %s, but a stack's accumulator starts at 0: %s. Put this layer "
			+ "lower in the list, or set its Blend to Add.")
			% ["Mul" if first.blend == Blend.MUL else "Min",
			"multiplying by it discards the layer completely" if first.blend == Blend.MUL
			else "only the parts of it below ground survive"])
	return ""
