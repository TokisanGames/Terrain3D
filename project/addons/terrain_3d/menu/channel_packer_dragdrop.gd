# Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.
# Channel Packer Dragdropper for Terrain3D
@tool
extends Button

signal dropped

func _can_drop_data(p_position, p_data) -> bool:
	if typeof(p_data) == TYPE_DICTIONARY:
		if p_data.files.size() == 1:
			match p_data.files[0].get_extension():
				"png", "bmp", "exr", "hdr", "jpg", "jpeg", "tga", "svg", "webp", "ktx", "dds":
					return true
	return false

func _drop_data(p_position, p_data) -> void:
	dropped.emit(p_data.files[0])
