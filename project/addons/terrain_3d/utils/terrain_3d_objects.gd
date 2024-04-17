@tool
extends Node3D
class_name Terrain3DObjects

const TransformChangedNotifier: Script = preload("res://addons/terrain_3d/utils/transform_changed_notifier.gd")

const CHILD_HELPER_NAME: StringName = &"TransformChangedSignaller"
const CHILD_HELPER_PATH: NodePath = ^"TransformChangedSignaller"

var _editor_interface = null
var _undo_redo = null
var _terrain_id: int
var _offsets: Dictionary # Object ID -> Vector3(X, Y offset relative to terrain height, Z)
var _ignore_transform_change: bool = false


func _exit_tree() -> void:
	if not Engine.is_editor_hint() or not _editor_interface:
		return
	
	child_entered_tree.disconnect(_on_child_entered_tree)
	child_exiting_tree.disconnect(_on_child_exiting_tree)
	
	for child in get_children():
		_on_child_exiting_tree(child)


func editor_setup(p_plugin) -> void:
	if _editor_interface:
		return
	
	_editor_interface = p_plugin.get_editor_interface()
	_undo_redo = p_plugin.get_undo_redo()
	
	for child in get_children():
		_on_child_entered_tree(child)
	
	child_entered_tree.connect(_on_child_entered_tree)
	child_exiting_tree.connect(_on_child_exiting_tree)


func get_terrain() -> Terrain3D:
	var terrain := instance_from_id(_terrain_id) as Terrain3D
	if not terrain or terrain.is_queued_for_deletion() or not terrain.is_inside_tree():
		var terrains: Array[Node] = _editor_interface.get_edited_scene_root().find_children("", "Terrain3D")
		if terrains.size() > 0:
			terrain = terrains[0]
		_terrain_id = terrain.get_instance_id() if terrain else 0
	
	if terrain and terrain.storage and not terrain.storage.maps_edited.is_connected(_on_maps_edited):
		terrain.storage.maps_edited.connect(_on_maps_edited)
	
	return terrain


func _get_terrain_height(p_global_position: Vector3) -> float:
	var terrain: Terrain3D = get_terrain()
	if not terrain or not terrain.storage:
		return 0.0
	var height: float = terrain.storage.get_height(p_global_position)
	if is_nan(height):
		return 0.0
	return height


func _on_child_entered_tree(p_node: Node) -> void:
	if not (p_node is Node3D):
		return
	
	assert(p_node.get_parent() == self)
	
	var helper: TransformChangedNotifier = p_node.get_node_or_null(CHILD_HELPER_PATH)
	if not helper:
		helper = TransformChangedNotifier.new()
		helper.name = CHILD_HELPER_NAME
		p_node.add_child(helper, true, INTERNAL_MODE_BACK)
	helper.transform_changed.connect(_on_child_transform_changed.bind(p_node))
	assert(p_node.has_node(CHILD_HELPER_PATH))
	
	var id: int = p_node.get_instance_id()
	if not _offsets.has(id):
		_update_child_offset(p_node)
	else:
		_update_child_position(p_node)


func _on_child_exiting_tree(p_node: Node) -> void:
	if not (p_node is Node3D) or not p_node.has_node(CHILD_HELPER_PATH):
		return
	
	var helper: TransformChangedNotifier = p_node.get_node_or_null(CHILD_HELPER_PATH)
	if helper:
		p_node.remove_child(helper)
		helper.queue_free()


func _is_node_selected(p_node: Node) -> bool:
	var editor_sel = _editor_interface.get_selection()
	return editor_sel.get_transformable_selected_nodes().has(p_node)


func _on_child_transform_changed(p_node: Node3D) -> void:
	if _ignore_transform_change:
		return
	
	var lmb_down := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if lmb_down and (_is_node_selected(p_node) or _is_node_selected(self)):
		# The user may be moving the node using gizmos.
		# We should wait until they're done before updating otherwise gizmos + this node conflict.
		return
	
	if not _offsets.has(p_node.get_instance_id()):
		return
	
	var old_offset: Vector3 = _offsets[p_node.get_instance_id()]
	var old_h: float = _get_terrain_height(old_offset)
	var old_position: Vector3 = old_offset + Vector3(0, old_h, 0)
	var new_position: Vector3 = p_node.global_position
	if old_position.is_equal_approx(new_position):
		return
	var new_h: float = _get_terrain_height(new_position)
	var new_offset: Vector3 = new_position - Vector3(0, new_h, 0)
	
	var translate_without_reposition: bool = Input.is_key_pressed(KEY_SHIFT)
	var y_changed: bool = not is_equal_approx(old_position.y, p_node.global_position.y)
	if not y_changed and not translate_without_reposition:
		new_offset.y = old_offset.y
		new_position = new_offset + Vector3(0, new_h, 0)
	
	# Make sure that when the user undo's the translation, the offset change gets undone too!
	_undo_redo.create_action("Translate", UndoRedo.MERGE_ALL)
	_undo_redo.add_do_property(self, &"_ignore_transform_change", true)
	_undo_redo.add_undo_property(self, &"_ignore_transform_change", true)
	_undo_redo.add_do_property(p_node, &"global_position", new_position)
	_undo_redo.add_undo_property(p_node, &"global_position", old_position)
	_undo_redo.add_do_method(self, &"_set_offset", p_node.get_instance_id(), new_offset)
	_undo_redo.add_undo_method(self, &"_set_offset", p_node.get_instance_id(), old_offset)
	_undo_redo.add_do_property(self, &"_ignore_transform_change", false)
	_undo_redo.add_undo_property(self, &"_ignore_transform_change", false)
	_undo_redo.commit_action()


func _set_offset(p_id: int, p_offset: Vector3) -> void:
	_offsets[p_id] = p_offset


# Overwrite current offset stored for node with its current Y position relative to the terrain
func _update_child_offset(p_node: Node3D) -> void:
	var position: Vector3 = global_transform * p_node.position
	var h: float = _get_terrain_height(position)
	var offset: Vector3 = position - Vector3(0, h, 0)
	_offsets[p_node.get_instance_id()] = offset


# Overwrite node's current position with terrain height + stored offset for this node
func _update_child_position(p_node: Node3D) -> void:
	if not _offsets.has(p_node.get_instance_id()):
		return
	
	var position: Vector3 = global_transform * p_node.position
	var h: float = _get_terrain_height(position)
	var offset: Vector3 = _offsets[p_node.get_instance_id()]
	var new_position: Vector3 = global_transform.inverse() * (offset + Vector3(0, h, 0))
	if not p_node.position.is_equal_approx(new_position):
		p_node.position = new_position


func _on_maps_edited(p_edited_aabb: AABB) -> void:
	var edited_area: AABB = p_edited_aabb.grow(1)
	edited_area.position.y = -INF
	edited_area.end.y = INF
	
	for child in get_children():
		var node := child as Node3D
		if node && edited_area.has_point(node.global_position):
			_update_child_position(node)
