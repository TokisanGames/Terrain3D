# Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.
# This is the start of the new UI for Terrain3D with all tools integrated.

@tool
extends Control


var terrain: Terrain3D
var show_pending: bool = true


func _ready() -> void:
	%Close.pressed.connect(_on_close)
	%TextureStartBtn.pressed.connect(_on_texture_start)
	if not show_pending:
		%Baking.queue_free()
		%TexturePacking.queue_free()
		%Import.queue_free()
		%Export.queue_free()


func _on_close() -> void:
	queue_free()


func _on_texture_start() -> void:
	var process_arr: Array
	var msg: String
	%TextureStatus.visible = true
	%TextureStatus.add_theme_color_override("font_color", Color.WHITE)
	
	if %SrcID1.value != %DestID1.value:
		process_arr.push_back([%SrcID1.value, %DestID1.value] as Array[int])
		msg += "Changing texture ID %d to %d.\n" % [ %SrcID1.value, %DestID1.value ]
	if %SrcID2.value != %DestID2.value:
		process_arr.push_back([%SrcID2.value, %DestID2.value] as Array[int])
		msg += "Changing texture ID %d to %d.\n" % [ %SrcID2.value, %DestID2.value ]
	if %SrcID3.value != %DestID3.value:
		process_arr.push_back([%SrcID3.value, %DestID3.value] as Array[int])
		msg += "Changing texture ID %d to %d.\n" % [ %SrcID3.value, %DestID3.value ]
	if process_arr.is_empty():
		msg = "No changes specified. Nothing to do."
		print(msg)
		%TextureStatus.text = msg + "\n"
		%TextureStatus.add_theme_color_override("font_color", Color.RED)
		return

	msg += "Starting..."
	print(msg)
	%TextureStatus.text = msg + "\n"
	await RenderingServer.frame_post_draw
	
	# Mask to clear base_id and over_id bits
	var clear_mask: int = ~(0x1F << 27 | 0x1F << 22)
	var util := Terrain3DUtil.new()

	for region: Terrain3DRegion in terrain.data.get_regions_all().values():
		var map: Image = region.control_map
		var modified: bool = false
		for x: int in map.get_width():
			for y: int in map.get_height():
				var control: int = util.as_uint(map.get_pixel(x, y).r)
				var base_id: int = util.get_base(control)
				var over_id: int = util.get_overlay(control)
				for tuple: Array[int] in process_arr:
					if base_id == tuple[0]:
						base_id = tuple[1]
						modified = true
					if over_id == tuple[0]:
						over_id = tuple[1]
						modified = true

				if modified:
					# Preserve bits 1-22, clear bits 23-32, set new base_id and over_id
					control = (control & clear_mask) | ((base_id & 0x1F) << 27) | ((over_id & 0x1F) << 22)
					map.set_pixel(x, y, Color(util.as_float(control), 0., 0., 1.))

		msg = "Processed region: %.0v" % [ region.get_location() ]
		if modified:
			region.set_modified(true)
			msg += ", modified"
		%TextureStatus.text += msg + "\n"
		print(msg)
		%Scroll.scroll_vertical += 50
		await RenderingServer.frame_post_draw
		
	terrain.data.update_maps(Terrain3DRegion.TYPE_CONTROL)
	%TextureStatus.text += "Finished."
	print("Finished.")
	%Scroll.scroll_vertical += 50
	%TextureStatus.add_theme_color_override("font_color", Color.GREEN)
	
