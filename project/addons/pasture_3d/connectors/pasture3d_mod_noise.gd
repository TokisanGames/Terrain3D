# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DModNoise — vertical jitter to break up a brush's silhouette, as a modifier stack step.
# The point-operator replacement for Pasture3DMound's `noise` / `noise_strength` pair.
#
#   amp += strength * noise.get_noise_2d(world_x, world_z) * profile
#
# `profile` is the brush's 0..1 interior mask, so the jitter fades out at the rim exactly as it did when
# this was two properties on the Mound. Evaluated in world XZ, so two overlapping brushes carrying the
# same FastNoiseLite agree where they meet.
@tool
class_name Pasture3DModNoise
extends Pasture3DBrushModifier

## The field to sample. Unassigned contributes nothing — the modifier reports itself inactive rather
## than costing a pass.
@export var noise: FastNoiseLite:
	set(v):
		if noise != null and noise.changed.is_connected(_touch):
			noise.changed.disconnect(_touch)
		noise = v
		if noise != null and not noise.changed.is_connected(_touch):
			noise.changed.connect(_touch)
		_touch()

## Metres of jitter at the field's full output.
@export var strength: float = 0.0:
	set(v):
		strength = v
		_touch()


func kind() -> StringName:
	return &"noise"


func is_active() -> bool:
	return enabled and noise != null and not is_zero_approx(strength)


func to_params() -> Dictionary:
	return {"noise": noise, "strength": strength}


func modifier_warnings(_p_host) -> PackedStringArray:
	var w := PackedStringArray()
	# The one failure mode that looks exactly like a broken modifier: the slot is filled, the inspector
	# looks configured, and the ground is flat. Same complaint the Mound already makes about Relief.
	if noise != null and is_zero_approx(strength) and enabled:
		w.append("Noise modifier: a noise field is assigned but Strength is 0 m, so it stamps nothing. "
			+ "Set Strength to the metres of jitter you want.")
	return w
