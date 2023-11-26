extends Object

const BakeDialog: PackedScene = preload("res://addons/terrain_3d/editor/components/bake_dialog.tscn")
const BAKE_MESH_DESCRIPTION: String = "This will create a child MeshInstance3D. LOD4+ is recommended. LOD0 is slow and dense with vertices every 1 unit. It is not an optimal mesh."
const BAKE_OCCLUDER_DESCRIPTION: String = "This will create a child OccluderInstance3D. LOD4+ is recommended and will take 5+ seconds per region to generate. LOD0 is unnecessarily dense and slow."

var plugin: EditorPlugin
var bake_method: Callable
var bake_dialog: ConfirmationDialog


func _init() -> void:
	bake_dialog = BakeDialog.instantiate()
	bake_dialog.hide()
	bake_dialog.confirmed.connect(func(): bake_method.call())


func bake_mesh_popup() -> void:
	if plugin.terrain:
		bake_method = _bake_mesh
		bake_dialog.description = BAKE_MESH_DESCRIPTION
		plugin.get_editor_interface().popup_dialog_centered(bake_dialog)


func _bake_mesh() -> void:
	var mesh: Mesh = plugin.terrain.bake_mesh(bake_dialog.lod, Terrain3DStorage.HEIGHT_FILTER_NEAREST)
	if !mesh:
		push_error("Failed to bake mesh from Terrain3D")
		return
	var undo := plugin.get_undo_redo()

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = &"MeshInstance3D"
	mesh_instance.mesh = mesh
	mesh_instance.set_skeleton_path(NodePath())

	undo.create_action("Terrain3D Bake ArrayMesh")
	undo.add_do_method(plugin.terrain, &"add_child", mesh_instance, true)
	undo.add_undo_method(plugin.terrain, &"remove_child", mesh_instance)
	undo.add_do_property(mesh_instance, &"owner", plugin.terrain.owner)
	undo.add_do_reference(mesh_instance)
	undo.commit_action()


func bake_occluder_popup() -> void:
	if plugin.terrain:
		bake_method = _bake_occluder
		bake_dialog.description = BAKE_OCCLUDER_DESCRIPTION
		plugin.get_editor_interface().popup_dialog_centered(bake_dialog)


func _bake_occluder() -> void:
	var mesh: Mesh = plugin.terrain.bake_mesh(bake_dialog.lod, Terrain3DStorage.HEIGHT_FILTER_MINIMUM)
	if !mesh:
		push_error("Failed to bake mesh from Terrain3D")
		return
	assert(mesh.get_surface_count() == 1)

	var undo := plugin.get_undo_redo()

	var occluder := ArrayOccluder3D.new()
	var arrays := mesh.surface_get_arrays(0)
	assert(arrays.size() > Mesh.ARRAY_INDEX)
	assert(arrays[Mesh.ARRAY_INDEX] != null)
	occluder.set_arrays(arrays[Mesh.ARRAY_VERTEX], arrays[Mesh.ARRAY_INDEX])

	var occluder_instance := OccluderInstance3D.new()
	occluder_instance.name = &"OccluderInstance3D"
	occluder_instance.occluder = occluder

	undo.create_action("Terrain3D Bake Occluder3D")
	undo.add_do_method(plugin.terrain, &"add_child", occluder_instance, true)
	undo.add_undo_method(plugin.terrain, &"remove_child", occluder_instance)
	undo.add_do_property(occluder_instance, &"owner", plugin.terrain.owner)
	undo.add_do_reference(occluder_instance)
	undo.commit_action()
