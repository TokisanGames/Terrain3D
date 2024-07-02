@tool
extends Control


var selected_file:String:
	set(val):
		selected_file = val
		if label:
			label.text = val

@onready var label: Label = $PanelContainer/VBoxContainer/HBoxContainer/Label
@onready var file_dialog: FileDialog = $FileDialog


func _on_file_dialog_file_selected(path: String) -> void:
	selected_file = path


func _on_select_pressed() -> void:
	file_dialog.popup_centered()


func _on_convert_pressed() -> void:
	if selected_file.is_empty():
		return
	
	convert_storage(selected_file)
	
	get_parent().hide()


static func convert_storage(path:String) -> void:
	var storage:Terrain3DStorage = ResourceLoader.load(path)
	if not storage:
		return
	
	var regions:Array[Terrain3DRegion] = []
	
	var hmaps:Array[Image] = storage.get_maps(Terrain3DStorage.TYPE_HEIGHT)
	var ctlmaps:Array[Image] = storage.get_maps(Terrain3DStorage.TYPE_CONTROL)
	var colmaps:Array[Image] = storage.get_maps(Terrain3DStorage.TYPE_COLOR)
	
	for i:int in range(storage.get_region_count()):
		var region:Terrain3DRegion = Terrain3DRegion.new()
		region.heightmap = hmaps[i]
		region.controlmap = ctlmaps[i]
		region.colormap = colmaps[i]
		regions.append(region)
	
	var save_dir:String = path.substr(0, path.rfind("/"))
	for i:int in regions.size():
		var region:Terrain3DRegion = regions[i]
		var fname:String = Terrain3DRegionManager.get_filename_for_region_from_offset(storage.region_offsets[i])
		ResourceSaver.save(region, save_dir + "/" + fname)


func _on_visibility_changed() -> void:
	selected_file = ""
