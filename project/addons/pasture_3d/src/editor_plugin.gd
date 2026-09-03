# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Editor Plugin for Pasture3D
@tool
extends EditorPlugin


# Includes
const Pasture3DUI: Script = preload("res://addons/pasture_3d/src/ui.gd")
const Pasture3DLayersDock: Script = preload("res://addons/pasture_3d/src/layers_dock.gd")
const Pasture3DBrushGizmo: Script = preload("res://addons/pasture_3d/src/brush_gizmo.gd")
const Pasture3DPoolGizmo: Script = preload("res://addons/pasture_3d/src/pool_gizmo.gd")
const Pasture3DJunctionGizmo: Script = preload("res://addons/pasture_3d/src/junction_gizmo.gd")
const ReliefFractalScript: Script = preload("res://addons/pasture_3d/connectors/pasture3d_relief_fractal.gd")
const BrushGraphRow: Script = preload("res://addons/pasture_3d/src/brush_graph_row.gd")
const ASSET_DOCK: String = "res://addons/pasture_3d/src/asset_dock.tscn"
const ASSET_DOCK_45: String = "res://addons/pasture_3d/src/asset_dock_45.tscn"

# Editor Plugin
var debug: int = 0 # Set in _edit()
var editor: Pasture3DEditor
var editor_settings: EditorSettings
var ui: Node # Pasture3DUI see Godot #75388
var asset_dock: PanelContainer
var layers_dock: PanelContainer
var graph_editor: Pasture3DGraphEditor # bottom-panel visual node-graph editor
var graph_inspector: Pasture3DGraphInspectorPlugin # "Edit in Graph Editor" button
var brush_gizmo: EditorNode3DGizmoPlugin # Clickable origin markers for brush nodes
## The selected Pasture3D brush, re-derived on `selection_changed` rather than per input event —
## see `_current_brush`. May hold a freed node; read it through `_current_brush`, not directly.
var _selected_brush: Pasture3DTerrainBrush
var pool_gizmo: EditorNode3DGizmoPlugin # Clickable markers floating over Pasture3DPool water
var junction_gizmo: EditorNode3DGizmoPlugin # Resolved road junctions, drawn where the roads meet
var current_region_position: Vector2
var mouse_global_position: Vector3 = Vector3.ZERO
var godot_editor_window: Window # The Godot Editor window
var viewport: SubViewport # Viewport the mouse was last in
var mouse_in_main: bool = false # Helper to track when mouse is in the editor vp

# Terrain
var terrain: Pasture3D
var _last_terrain: Pasture3D
var nav_region: NavigationRegion3D

# Input
var modifier_ctrl: bool
var modifier_alt: bool
var modifier_shift: bool
var _last_modifiers: int = 0
var _input_mode: int = 0 # -1: camera move, 0: none, 1: operating
var rmb_release_time: int = 0
var _use_meta: bool = false

# Landscape-brush pseudo-tools (GDScript-only — see PASTURE3D_BRUSH_PLACEMENT_TOOL_SPEC.md). Not C++
# Pasture3DEditor.Tools: handled in _forward_placement_input / _forward_selection_input, ahead of the
# sculpt path. placement_mode = click drops a brush; selection_mode = click selects an existing brush.
var placement_mode: bool = false
var selection_mode: bool = false
var placement_brush_script: String = "res://addons/pasture_3d/connectors/pasture3d_mound.gd"
var placement_brush_label: String = "Mound"
## Vertical (Y) offset added to the surface hit when dropping a brush (set from the bottom-bar selector;
## defaults per brush type — Ridge 20, Trough -10, others 0). See tool_settings.build_placement_selector.
var placement_y_offset: float = 0.0


func _init() -> void:
	if debug:
		print("Pasture3DEditorPlugin: _init")
	if OS.get_name() == "macOS":
		_use_meta = true
	
	# Get the Godot Editor window. Structure is root:Window/EditorNode/Base Control
	godot_editor_window = EditorInterface.get_base_control().get_parent().get_parent()
	godot_editor_window.focus_entered.connect(_on_godot_focus_entered)
	EditorInterface.get_inspector().mouse_entered.connect(func(): mouse_in_main = false)


func _enter_tree() -> void:
	if debug:
		print("Pasture3DEditorPlugin: _enter_tree")
	editor = Pasture3DEditor.new()
	setup_editor_settings()
	ui = Pasture3DUI.new()
	ui.plugin = self
	add_child(ui)

	scene_changed.connect(_on_scene_changed)

	# Load Godot 4.6+ asset dock or pre-4.6
	if Engine.get_version_info().hex >= 0x040600:
		asset_dock = load(ASSET_DOCK).instantiate()
	else:
		asset_dock = load(ASSET_DOCK_45).instantiate()
	asset_dock.initialize(self)

	add_to_group("pasture3d_editor_plugin")
	layers_dock = Pasture3DLayersDock.new()
	layers_dock.initialize(self)

	# Visual node-graph editor (PASTURE3D_TERRAIN_GRAPH_SPEC.md) — a bottom panel, opened from the
	# "Edit in Graph Editor" button the inspector plugin adds to a graph / graph modifier / plow brush.
	graph_editor = Pasture3DGraphEditor.new()
	graph_editor.initialize(self)
	graph_inspector = Pasture3DGraphInspectorPlugin.new()
	graph_inspector.editor = graph_editor
	graph_inspector.plugin = self
	add_inspector_plugin(graph_inspector)

	# Clickable origin markers so brush nodes are easy to select in a busy scene.
	brush_gizmo = Pasture3DBrushGizmo.new()
	add_node_3d_gizmo_plugin(brush_gizmo)
	# The same, for water bodies. A pool draws only an internal-child mesh, so without this there
	# is nothing in the viewport to click that selects the pool itself.
	pool_gizmo = Pasture3DPoolGizmo.new()
	add_node_3d_gizmo_plugin(pool_gizmo)
	# Road junctions have no geometry of their own until P5 builds the mesh, so until then the resolved
	# footprint is drawn rather than left in the inspector as numbers nobody checks.
	junction_gizmo = Pasture3DJunctionGizmo.new()
	add_node_3d_gizmo_plugin(junction_gizmo)

	# One selection scan per selection change, rather than one per forwarded input event — see
	# `_current_brush`. Primed immediately so a brush already selected when the plugin loads is live.
	EditorInterface.get_selection().selection_changed.connect(_on_editor_selection_changed)
	_on_editor_selection_changed()

	_register_water_globals()


# Water shaders read their clock and sun from global shader uniforms, so one write
# drives every water body in the scene (PASTURE3D_WATER_SHADER_SPEC.md §2.3).
#
# These have to live in project.godot: the RenderingServer global table is built
# from it at engine startup and nothing written later persists, which is what makes
# the uniforms resolve in exported builds. RenderingServer.global_shader_parameter_add()
# covers the current session only, and Pasture3D does it at runtime as a fallback.
#
# Writes project.godot, so it saves only when an entry is genuinely absent.
func _register_water_globals() -> void:
	const WATER_GLOBALS: Dictionary = {
		"water_time": { "type": "float", "value": 0.0 },
		"water_sun_direction": { "type": "vec3", "value": Vector3(0.0, -1.0, 0.0) },
		"water_sun_color": { "type": "vec3", "value": Vector3(1.0, 1.0, 1.0) },
		"water_time_period": { "type": "float", "value": 120.0 },
	}
	var added: PackedStringArray = []
	for gname: String in WATER_GLOBALS:
		var setting: String = "shader_globals/" + gname
		if ProjectSettings.has_setting(setting):
			continue
		ProjectSettings.set_setting(setting, WATER_GLOBALS[gname])
		added.append(gname)
	if added.is_empty():
		return
	var err: int = ProjectSettings.save()
	if err != OK:
		push_warning("Pasture3D: could not save water shader globals to project.godot (error %d). " % err +
			"Water will still run, but the uniforms will be re-registered every session.")
	elif debug:
		print("Pasture3DEditorPlugin: registered shader globals ", added)


func _exit_tree() -> void:
	if debug:
		print("Pasture3DEditorPlugin: _exit_tree")
	asset_dock.remove_dock(true)
	asset_dock.queue_free()
	layers_dock.remove_dock()
	layers_dock.queue_free()
	if graph_inspector:
		remove_inspector_plugin(graph_inspector)
	if graph_editor:
		graph_editor.remove_dock()
		graph_editor.queue_free()
	if brush_gizmo:
		remove_node_3d_gizmo_plugin(brush_gizmo)
	if pool_gizmo:
		remove_node_3d_gizmo_plugin(pool_gizmo)
	if junction_gizmo:
		remove_node_3d_gizmo_plugin(junction_gizmo)
	var sel := EditorInterface.get_selection()
	if sel.selection_changed.is_connected(_on_editor_selection_changed):
		sel.selection_changed.disconnect(_on_editor_selection_changed)
	ui.queue_free()
	editor.free()

	scene_changed.disconnect(_on_scene_changed)
	godot_editor_window.focus_entered.disconnect(_on_godot_focus_entered)


func get_graph_editor() -> Pasture3DGraphEditor:
	return graph_editor


func _on_godot_focus_entered() -> void:
	if debug > 1:
		print("Pasture3DEditorPlugin: _on_godot_focus_entered")
	_read_input()


## EditorPlugin selection function call chain isn't consistent. Here's the map of calls:
## Assume we handle Pasture3D and NavigationRegion3D  
# Click Pasture3D: 					_handles(Pasture3D), _edit(Pasture3D), _make_visible(true)
# Deselect:							_edit(null), _make_visible(false)
# Click other node:					_handles(OtherNode)
# Click NavRegion3D:				_handles(NavReg3D), _edit(NavReg3D), _make_visible(true)
# Click NavRegion3D, Pasture3D:		_handles(Pasture3D), _make_visible(true), _edit(Pasture3D)
# Click Pasture3D, NavRegion3D:		_handles(NavReg3D), _make_visible(true), _edit(NavReg3D)
func _handles(p_object: Object) -> bool:
	if p_object is Pasture3D:
		return true
	elif p_object is Pasture3DTerrainBrush:
		# Handle brushes so we receive 3D input for in-place loop-point add/remove. We deliberately keep
		# the terrain editing context intact (see _edit) — this never enters the sculpt path.
		return true
	elif p_object is Pasture3DRoadNetwork or p_object is Pasture3DRoadGroup:
		return true
	elif p_object is NavigationRegion3D and is_instance_valid(_last_terrain):
		return true
	
	# Pasture3DObjects requires access to EditorUndoRedoManager. The only way to make sure it
	# always has it, is to pass it in here. _edit is NOT called if the node is cut and pasted.
	elif p_object is Pasture3DObjects:
		p_object.editor_setup(self)
	elif p_object is Node3D and p_object.get_parent() is Pasture3DObjects:
		p_object.get_parent().editor_setup(self)
	
	return false


func _edit(p_object: Object) -> void:
	# A brush is selected: don't _clear the terrain context (keep ray-march live), and populate the Layers
	# dock from the brush's PARENT terrain so it shows even if that terrain was never selected first.
	# Point editing is handled in _forward_3d_gui_input.
	if p_object is Pasture3DTerrainBrush:
		var bt: Pasture3D = p_object.terrain
		if is_instance_valid(bt):
			_last_terrain = bt
			if layers_dock:
				layers_dock.set_terrain(bt)
		return

	if p_object is Pasture3DRoadNetwork or p_object is Pasture3DRoadGroup:
		var nt: Pasture3D = p_object.terrain if "terrain" in p_object else null
		if is_instance_valid(nt):
			_last_terrain = nt
			if layers_dock:
				layers_dock.set_terrain(nt)
		return

	if !p_object:
		_clear()

	if p_object is Pasture3D:
		if p_object == terrain:
			return
		terrain = p_object
		_last_terrain = terrain
		terrain.set_plugin(self)
		terrain.set_editor(editor)
		debug = terrain.debug_level
		editor.set_terrain(terrain)
		terrain.set_meta("_edit_lock_", true)
		ui.set_visible(true)

		# Get alerted when a new asset list is loaded
		if not terrain.assets_changed.is_connected(asset_dock.update_assets):
			terrain.assets_changed.connect(asset_dock.update_assets)
		asset_dock.update_assets()
		if layers_dock:
			layers_dock.set_terrain(terrain)
	else:
		_clear()

	if is_terrain_valid(_last_terrain):
		if p_object is NavigationRegion3D:
			ui.set_visible(true, true)
			nav_region = p_object
		else:
			nav_region = null

	
func _make_visible(p_visible: bool, p_redraw: bool = false) -> void:
	if debug:
		print("Pasture3DEditorPlugin: _make_visible(%s, %s)" % [ p_visible, p_redraw ])
	if p_visible and is_selected():
		ui.set_visible(true)
		asset_dock.update_dock()
	else:
		ui.set_visible(false)


func _clear() -> void:
	placement_mode = false
	selection_mode = false
	if is_terrain_valid():
		editor.set_tool(Pasture3DEditor.TOOL_MAX)
		editor.set_operation(Pasture3DEditor.OP_MAX)
		terrain = null
		editor.set_terrain(null)
		ui.clear_picking()
	if layers_dock:
		layers_dock.set_terrain(null)


## Forwarded from Pasture3DEditor when a stroke hits a locked/reserved/hidden active layer (§6).
func flash_layer_warning(p_name: String, p_hidden: bool = false) -> void:
	if layers_dock:
		layers_dock.flash_warning(p_name, p_hidden)


func _forward_3d_gui_input(p_viewport_camera: Camera3D, p_event: InputEvent) -> AfterGUIInput:
	mouse_in_main = true

	# Landscape pseudo-tools → drop / select a brush where the user clicks. Take priority over the
	# selected-brush loop editing and the sculpt path (spec §3.4); they never sculpt.
	if placement_mode and is_terrain_valid():
		return _forward_placement_input(p_viewport_camera, p_event)
	if selection_mode and is_terrain_valid():
		return _forward_selection_input(p_viewport_camera, p_event)

	# Brush selected → loop-point editing (Ctrl-click add / right-click-a-point remove). Mutually
	# exclusive with sculpting (which only runs when the terrain is selected), so they never collide.
	var brush := _current_brush()
	if brush != null:
		return _forward_brush_input(p_viewport_camera, p_event, brush)

	if not is_terrain_valid():
		return AFTER_GUI_INPUT_PASS

	var continue_input: AfterGUIInput = _read_input(p_event)
	if continue_input != AFTER_GUI_INPUT_CUSTOM:
		return continue_input
	
	## Setup active camera & viewport
	# Always update this for all inputs, as the mouse position can move without
	# necessarily being a InputEventMouseMotion object. get_intersection() also
	# returns the last frame position, and should be updated more frequently.
	
	# Snap terrain to current camera 
	terrain.set_camera(p_viewport_camera)

	# Detect if viewport is set to half_resolution
	# Structure is: Node3DEditorViewportContainer/Node3DEditorViewport(4)/SubViewportContainer/SubViewport/Camera3D
	viewport = p_viewport_camera.get_parent()
	var full_resolution: bool = false if viewport.get_parent().stretch_shrink == 2 else true

	## Get mouse location on terrain
	# Project 2D mouse position to 3D position and direction
	var vp_mouse_pos: Vector2 = viewport.get_mouse_position()
	var mouse_pos: Vector2 = vp_mouse_pos if full_resolution else vp_mouse_pos / 2
	var camera_pos: Vector3 = p_viewport_camera.project_ray_origin(mouse_pos)
	var camera_dir: Vector3 = p_viewport_camera.project_ray_normal(mouse_pos)

	ui.update_decal()

	# If region tool, grab mouse position without considering height
	if editor.get_tool() == Pasture3DEditor.REGION:
		var t = -Vector3(0, 1, 0).dot(camera_pos) / Vector3(0, 1, 0).dot(camera_dir)
		mouse_global_position = (camera_pos + t * camera_dir)
	else:
	#Else look for intersection with terrain
		var intersection_point: Vector3 = terrain.get_intersection(camera_pos, camera_dir, true)
		if intersection_point.z > 3.4e38 or is_nan(intersection_point.y): # max double or nan
			return AFTER_GUI_INPUT_PASS
		mouse_global_position = intersection_point
	
	## Handle mouse movement
	if p_event is InputEventMouseMotion:

		if ui.live_info_panel:
			ui.live_info_panel.update(mouse_global_position)

		if _input_mode != -1: # Not cam rotation
			## Update region highlight
			var region_position: Vector2 = ( Vector2(mouse_global_position.x, mouse_global_position.z) \
				/ (terrain.get_region_size() * terrain.get_vertex_spacing()) ).floor()

			if _input_mode > 0 and editor.is_operating():
				# Inject pressure - Relies on C++ set_brush_data() using same dictionary instance
				ui.brush_data["mouse_pressure"] = p_event.pressure

				editor.operate(mouse_global_position, p_viewport_camera.rotation.y)
				return AFTER_GUI_INPUT_STOP
			
		return AFTER_GUI_INPUT_PASS

	if p_event is InputEventMouseButton and _input_mode > 0:
		if p_event.is_pressed():
			# If picking
			if ui.is_picking():
				ui.pick(mouse_global_position)
				if not ui.operation_builder or not ui.operation_builder.is_ready():
					return AFTER_GUI_INPUT_STOP
			
			if modifier_ctrl and editor.get_tool() == Pasture3DEditor.HEIGHT:
				var height: float = terrain.data.get_height(mouse_global_position)
				ui.brush_data["height"] = height
				ui.tool_settings.set_setting("height", height)
				
			# If adjusting regions
			if editor.get_tool() == Pasture3DEditor.REGION:
				# Skip regions that already exist or don't
				var has_region: bool = terrain.data.has_regionp(mouse_global_position)
				var op: int = editor.get_operation()
				if	( has_region and op == Pasture3DEditor.ADD) or \
					( not has_region and op == Pasture3DEditor.SUBTRACT ):
					return AFTER_GUI_INPUT_STOP
			
			# If an automatic operation is ready to go (e.g. gradient)
			if ui.operation_builder and ui.operation_builder.is_ready():
				ui.operation_builder.apply_operation(editor, mouse_global_position, p_viewport_camera.rotation.y)
				return AFTER_GUI_INPUT_STOP
			
			# If no sculpt tool is active (or selection mode is on), clicking on a road ribbon / brush selects it
			if editor.get_tool() == Pasture3DEditor.TOOL_MAX or selection_mode:
				var clicked_brush: Node3D = _pick_brush_screen(p_viewport_camera, mouse_pos, 24.0)
				if clicked_brush != null:
					selection_mode = false
					if ui:
						var tb: Variant = ui.get("toolbar")
						if tb and tb.has_method("clear_landscape_toggles"):
							tb.clear_landscape_toggles()
					var sel: EditorSelection = EditorInterface.get_selection()
					sel.clear()
					sel.add_node(clicked_brush)
					EditorInterface.edit_node(clicked_brush)
					return AFTER_GUI_INPUT_STOP

			# Mouse clicked, start editing
			editor.start_operation(mouse_global_position)
			editor.operate(mouse_global_position, p_viewport_camera.rotation.y)
			return AFTER_GUI_INPUT_STOP
		
		# _input_apply released, save undo data
		elif editor.is_operating():
			editor.stop_operation()
			return AFTER_GUI_INPUT_STOP

	return AFTER_GUI_INPUT_PASS


## The currently-selected Pasture3D brush, or null. Drives the loop-point editing input path.
##
## ANSWERED FROM A CACHE, because `_forward_3d_gui_input` asks on EVERY forwarded event — every mouse
## motion across the viewport included — and the honest answer allocates an Array of every selected node
## and type-tests it. The selection only changes when `selection_changed` fires, so that is where the
## work belongs. `is_instance_valid` still guards the read: a cached brush can be freed (deleted, or an
## undone placement) without the signal reaching us first.
func _current_brush() -> Pasture3DTerrainBrush:
	if not is_instance_valid(_selected_brush):
		_selected_brush = null
	return _selected_brush


## The selection changed — re-derive the brush once, here, instead of per input event. Also publishes
## the id to the brush gizmo, whose `_brush_selected` ran the same allocation once per redraw and once
## per subgizmo ray.
func _on_editor_selection_changed() -> void:
	_selected_brush = null
	for n in EditorInterface.get_selection().get_selected_nodes():
		if n is Pasture3DTerrainBrush:
			_selected_brush = n
			break
	if brush_gizmo:
		brush_gizmo.set_selected_brush(_selected_brush)


## Loop-point editing input for a selected brush. Ctrl-click (Cmd on macOS) on the surface inserts a
## point on the nearest loop segment; right-click ON a point removes it. Everything else passes through
## so camera navigation and the subgizmo point-move (handled by the editor) keep working.
func _forward_brush_input(p_camera: Camera3D, p_event: InputEvent, p_brush: Pasture3DTerrainBrush) -> AfterGUIInput:
	# Delete/Backspace removes the selected loop point (keyboard alternative to right-click). Only fires
	# when a point is actually selected, so plain Delete still deletes the brush node otherwise.
	if p_event is InputEventKey and p_event.pressed and not p_event.echo:
		if p_event.keycode == KEY_DELETE or p_event.keycode == KEY_BACKSPACE:
			var sel: Array = brush_gizmo.selected_point(p_brush) if brush_gizmo else [null, -1]
			if sel[0] != null:
				p_brush.editor_remove_point(sel[0], sel[1])
				brush_gizmo.clear_point_selection()
				return AFTER_GUI_INPUT_STOP
		return AFTER_GUI_INPUT_PASS

	if not (p_event is InputEventMouseButton) or not p_event.is_pressed():
		return AFTER_GUI_INPUT_PASS
	var terr: Pasture3D = p_brush.terrain
	if not is_instance_valid(terr) or terr.data == null:
		return AFTER_GUI_INPUT_PASS

	# Mouse position in the camera's (possibly half-resolution) viewport space, matching the sculpt path.
	var vp: SubViewport = p_camera.get_parent()
	var full_res: bool = vp.get_parent().stretch_shrink != 2
	var raw: Vector2 = vp.get_mouse_position()
	var mouse_pos: Vector2 = raw if full_res else raw / 2.0

	# Double-click a point → toggle it between a smooth curve and a sharp corner. Double-click one of its
	# SHOWN tangent handles → sharpen just that side. Both go through the gizmo's own picker, so the
	# handle this acts on is the handle the click selected; a second picker here (14 px, positions only)
	# used to let a double-click on a visible tangent silently toggle the point underneath it.
	if p_event.get_button_index() == MOUSE_BUTTON_LEFT and p_event.double_click:
		var dhit: Array = brush_gizmo.pick_handle_at(p_brush, p_camera, mouse_pos) if brush_gizmo \
				else [null, -1, -1]
		if dhit[0] != null:
			if dhit[2] == 0:
				p_brush.editor_smooth_point(dhit[0], dhit[1])
			else:
				p_brush.editor_zero_tangent(dhit[0], dhit[1], dhit[2])
			return AFTER_GUI_INPUT_STOP
		return AFTER_GUI_INPUT_PASS

	var add_mod: bool = p_event.meta_pressed if _use_meta else p_event.ctrl_pressed
	if p_event.get_button_index() == MOUSE_BUTTON_LEFT and add_mod:
		var from: Vector3 = p_camera.project_ray_origin(mouse_pos)
		var dir: Vector3 = p_camera.project_ray_normal(mouse_pos)
		# CPU raymarch (false): the GPU path is stale on a one-shot click (renders + reads a SubViewport
		# the same frame), which lands the point far away / below ground.
		var hit: Vector3 = terr.get_intersection(from, dir, false)
		if hit.z > 3.4e38 or is_nan(hit.y):
			return AFTER_GUI_INPUT_PASS
		var pos := hit
		if p_brush.snap_to_surface:
			var h: float = p_brush._base_height_below(Vector3(hit.x, 0.0, hit.z))
			if is_finite(h):
				pos = Vector3(hit.x, h + p_brush.surface_offset, hit.z)
		p_brush.editor_add_point(pos)
		return AFTER_GUI_INPUT_STOP

	if p_event.get_button_index() == MOUSE_BUTTON_RIGHT:
		# The gizmo's picker, not a second one — a right-click must remove the point the user can see is
		# selected. A hit on a tangent resolves to its own point, which is the point that owns the handle.
		var picked: Array = brush_gizmo.pick_handle_at(p_brush, p_camera, mouse_pos) if brush_gizmo \
				else [null, -1, -1]
		if picked[0] != null:
			p_brush.editor_remove_point(picked[0], picked[1])
			return AFTER_GUI_INPUT_STOP
		# Not on a point → let the right-button through for camera look.
		return AFTER_GUI_INPUT_PASS

	# Plain left-click not on a point of this brush: check if user clicked on another road ribbon / brush!
	if p_event.get_button_index() == MOUSE_BUTTON_LEFT and not add_mod and not p_event.double_click:
		# Same picker again: "did this click land on one of MY handles" must agree with what the subgizmo
		# ray decided, or a click can both grab a handle and re-select a different brush.
		var picked_self: Array = brush_gizmo.pick_handle_at(p_brush, p_camera, mouse_pos) if brush_gizmo \
				else [null, -1, -1]
		if picked_self[0] == null:
			var other: Node3D = _pick_brush_screen(p_camera, mouse_pos, 24.0)
			if other != null and other != p_brush:
				var sel: EditorSelection = EditorInterface.get_selection()
				sel.clear()
				sel.add_node(other)
				EditorInterface.edit_node(other)
				return AFTER_GUI_INPUT_STOP

	return AFTER_GUI_INPUT_PASS


## Brush placement input: track a crosshair under the cursor on mouse motion, and on left-click drop the
## selected landscape brush at the surface hit (one undoable action — see place_brush_at). Other events
## pass through so camera nav / right-click look keep working.
func _forward_placement_input(p_camera: Camera3D, p_event: InputEvent) -> AfterGUIInput:
	var is_motion: bool = p_event is InputEventMouseMotion
	var is_click: bool = p_event is InputEventMouseButton and p_event.is_pressed() \
		and p_event.get_button_index() == MOUSE_BUTTON_LEFT
	if not is_motion and not is_click:
		return AFTER_GUI_INPUT_PASS

	var hit: Vector3 = _placement_surface_hit(p_camera)
	var valid: bool = hit.z < 3.4e38 and not is_nan(hit.y)

	if is_motion:
		if valid:
			mouse_global_position = hit
			if ui and ui.has_method("show_placement_decal"):
				ui.show_placement_decal(hit)
		elif ui and ui.has_method("hide_decal"):
			ui.hide_decal()
		return AFTER_GUI_INPUT_PASS

	if not valid:
		return AFTER_GUI_INPUT_PASS
	place_brush_at(hit)
	return AFTER_GUI_INPUT_STOP


## Surface point under the mouse, or a miss sentinel (z = max float). Uses the CPU raymarch
## (gpu_mode=false): the GPU path renders a SubViewport UPDATE_ONCE and reads it the SAME frame, so a
## one-shot click gets a stale depth (lands far away / below ground). The raymarch is synchronous and
## exact. Y is then pinned to get_height so the brush origin sits precisely on the surface.
func _placement_surface_hit(p_camera: Camera3D) -> Vector3:
	var t: Pasture3D = get_terrain()
	if not is_terrain_valid(t):
		return Vector3(3.5e38, 3.5e38, 3.5e38)
	var vp: SubViewport = p_camera.get_parent()
	var full_res: bool = vp.get_parent().stretch_shrink != 2
	var raw: Vector2 = vp.get_mouse_position()
	var mouse_pos: Vector2 = raw if full_res else raw / 2.0
	var from: Vector3 = p_camera.project_ray_origin(mouse_pos)
	var dir: Vector3 = p_camera.project_ray_normal(mouse_pos)
	var hit: Vector3 = t.get_intersection(from, dir, false)
	if hit.z > 3.4e38 or is_nan(hit.y):
		return hit
	var h: float = t.data.get_height(Vector3(hit.x, 0.0, hit.z))
	if is_finite(h):
		hit.y = h
	return hit


## Instantiate the currently-selected landscape brush type, or null on failure.
func _instantiate_placement_brush() -> Node3D:
	var scr: Variant = load(placement_brush_script)
	if scr == null:
		push_error("Pasture3D: could not load brush script '%s'." % placement_brush_script)
		return null
	var node: Variant = scr.new()
	if not (node is Node3D):
		push_error("Pasture3D: '%s' is not a Node3D brush." % placement_brush_script)
		if node is Object and not (node is RefCounted):
			(node as Object).free()
		return null
	(node as Node).name = placement_brush_label
	_apply_placement_defaults(node as Node3D)
	return node as Node3D


## Modern defaults for NEWLY placed brushes only. These are set explicitly rather than by moving the
## script's declared default, so the value serialises into the scene — a pre-existing scene omits the
## property precisely BECAUSE it matched the old default, so moving that default would silently convert
## exactly the nodes we must not touch. Do not "simplify" this into the brush's _init() for the same
## reason. See PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md §11.
func _apply_placement_defaults(node: Node3D) -> void:
	if node is Pasture3DPlow:
		var plow := node as Pasture3DPlow
		if plow.modifiers.is_empty():
			# Through the shared helper, which assigns the stack THROUGH THE SETTER. The copy that used to
			# live here ended in `plow.modifiers.append(mg)`, mutating the array in place — so the brush's
			# `_bind_modifiers` never ran and it never heard its own graph change. Every Plow placed from the
			# toolbar was born deaf: editing its graph updated nothing until Bake was pressed.
			BrushGraphRow.ensure_graph_modifier(plow)


## Place a new landscape brush at `world_pos`, as ONE undoable action: do = add the node under the
## terrain + bake; undo = lift the brush's footprint off its layer + remove the node. Each direction is
## a single encapsulated method so EditorUndoRedoManager's method-execution order is irrelevant, and
## add_do_reference keeps the detached node alive while the action sits undone. See spec §4.
func place_brush_at(world_pos: Vector3) -> void:
	var t: Pasture3D = get_terrain()
	if not is_terrain_valid(t):
		return
	var root: Node = get_tree().edited_scene_root
	if root == null:
		push_warning("Pasture3D: open and edit a scene before placing a brush.")
		return
	var node: Node3D = _instantiate_placement_brush()
	if node == null:
		return
	# Apply the bottom-bar vertical offset on top of the surface hit (Ridge +20, Trough -10, etc.). Done
	# before the action is created so the offset is baked into the captured world_pos (undo restores it too).
	world_pos.y += placement_y_offset
	# Name it uniquely among the terrain's children up front (Mound, Mound1, Mound2…), so add_child keeps
	# a readable name instead of falling back to "@Node3D@<id>" on a collision.
	node.name = _unique_child_name(t, placement_brush_label)
	var ur: EditorUndoRedoManager = get_undo_redo()
	ur.create_action("Place %s" % placement_brush_label, UndoRedo.MERGE_DISABLE, t)
	ur.add_do_reference(node)
	ur.add_do_method(self, "_do_place_brush", t, node, root, world_pos)
	ur.add_undo_method(self, "_undo_place_brush", node)
	ur.commit_action(true) # execute the do-method now → performs the initial placement + bake


## Do/redo: add the brush under the terrain (owned by the scene so it saves), bind + position it, and
## bake. Auto-refresh is suspended around the scripted add so only the explicit synchronous refresh()
## runs (no debounced second bake that could race a fast undo — spec §4.3).
func _do_place_brush(t: Pasture3D, node: Node3D, root: Node, world_pos: Vector3) -> void:
	if not is_instance_valid(node) or not is_instance_valid(t):
		return
	node.set("_suspend_auto", true)
	if node.get_parent() == null:
		t.add_child(node, true) # force_readable_name → keep "Mound1" etc., not "@Node3D@<id>"
		node.owner = root
	if node.get("terrain") != t:
		node.set("terrain", t) # deterministic bind (don't depend on the ancestor-walk auto-assign)
	node.global_position = world_pos
	# Bake via place_bake(): a rect-scoped bake of ONLY this freshly-placed brush. It adds a starter spline
	# if there is none (on REDO the node still carries its original spline, so it won't add a second), then
	# bakes through the dirty-rect path — which, unlike the full refresh, does NOT clear/re-snap/repaint
	# layer-mates. That matters for undo: the full refresh re-snaps every sibling's curve points, a non-undoable
	# mutation of OTHER brushes, so undoing a placement used to corrupt neighbouring brushes. _undo_place_brush
	# reverses this with detach_placement() (rect-scoped). _suspend_auto stays on so the child-added
	# auto-schedule doesn't queue a second debounced bake.
	if node.has_method("place_bake"):
		node.call("place_bake")
	elif node.has_method("refresh"):
		node.call("refresh")
	node.set("_suspend_auto", false)
	# Deliberately DON'T change the editor selection: keeping the terrain selected keeps the Pasture3D
	# toolbar visible and placement mode active, so the user can drop several brushes in a row. Selecting
	# a brush would hide the toolbar (is_selected() only counts the terrain). Use the Select Brush tool
	# (or click the brush's gizmo) to edit one afterward.


## Undo: lift this brush's contribution off the layer, then detach the node from the tree. add_do_reference
## keeps it alive for a later redo.
func _undo_place_brush(node: Node3D) -> void:
	if not is_instance_valid(node):
		return
	# Rect-scoped detach: clear only this brush's own footprint and repaint the neighbours there, matching how
	# placement composited (no whole-layer recomposite, no sibling re-snap). Falls back to the live detach.
	var detached: bool = node.has_method("detach_placement") and bool(node.call("detach_placement"))
	if not detached and node.has_method("_detach_from_current"):
		node.call("_detach_from_current")
	# Defer the tree removal to idle. Unparenting a Node3D (and its child Path3D loops) synchronously here,
	# mid undo-commit, makes the editor's gizmo refresh read the node's global_transform after it has left the
	# tree — harmless, but it spams "!is_inside_tree()" to the Output. Deferring lets the in-flight gizmo pass
	# finish with the node still in the tree, then unparents it cleanly. add_do_reference keeps it alive for a
	# redo; _do_place_brush re-checks get_parent(), so a redo issued before the deferred call still behaves.
	var p: Node = node.get_parent()
	if p:
		p.remove_child.call_deferred(node)


## A child name for `parent` that doesn't collide: base, then base1, base2, … (so a second Mound becomes
## "Mound1"). Keeps placed brushes readably named instead of Godot's "@Node3D@<id>" collision fallback.
func _unique_child_name(parent: Node, base: String) -> String:
	if parent == null or not parent.has_node(NodePath(base)):
		return base
	var i: int = 1
	while parent.has_node(NodePath("%s%d" % [base, i])):
		i += 1
	return "%s%d" % [base, i]


## Select-Brush input: a left-click picks the nearest landscape brush (by screen distance to its origin
## marker) and selects it in the editor, then turns the tool off so its loop points are editable right
## away. A miss passes through (camera nav / deselect). See spec §3.3 / the Select Brush tool.
func _forward_selection_input(p_camera: Camera3D, p_event: InputEvent) -> AfterGUIInput:
	if not (p_event is InputEventMouseButton) or not p_event.is_pressed():
		return AFTER_GUI_INPUT_PASS
	if p_event.get_button_index() != MOUSE_BUTTON_LEFT:
		return AFTER_GUI_INPUT_PASS

	var vp: SubViewport = p_camera.get_parent()
	var full_res: bool = vp.get_parent().stretch_shrink != 2
	var raw: Vector2 = vp.get_mouse_position()
	var mouse_pos: Vector2 = raw if full_res else raw / 2.0
	var brush: Node3D = _pick_brush_screen(p_camera, mouse_pos, 40.0)
	if brush == null:
		return AFTER_GUI_INPUT_PASS # let the click through (deselect / camera)

	# Picked one → leave selection mode (so the next clicks edit its loop points) and reset the toolbar.
	selection_mode = false
	if ui:
		var tb: Variant = ui.get("toolbar")
		if tb and tb.has_method("clear_landscape_toggles"):
			tb.clear_landscape_toggles()
	var sel: EditorSelection = EditorInterface.get_selection()
	sel.clear()
	sel.add_node(brush)
	EditorInterface.edit_node(brush)
	return AFTER_GUI_INPUT_STOP


## Nearest Pasture3DTerrainBrush or road ribbon under `screen_pos` within `radius` px, or null.
func _pick_brush_screen(p_camera: Camera3D, screen_pos: Vector2, radius: float = 24.0) -> Node3D:
	var best: Node3D = null
	var best_d: float = radius
	for n in get_tree().get_nodes_in_group(&"pasture3d_brush"):
		if not (n is Node3D):
			continue
		var d: float = INF
		if n.has_method("pick_brush_screen_distance"):
			d = n.pick_brush_screen_distance(p_camera, screen_pos, radius)
		elif n.has_method("pick_road_screen_distance"):
			d = n.pick_road_screen_distance(p_camera, screen_pos, radius)
		else:
			var wp: Vector3 = (n as Node3D).global_position
			if not p_camera.is_position_behind(wp):
				d = p_camera.unproject_position(wp).distance_to(screen_pos)
		if d <= radius and d < best_d:
			best_d = d
			best = n
	return best


func _read_input(p_event: InputEvent = null) -> AfterGUIInput:
	## Determine if user is moving camera or applying
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or \
		p_event is InputEventMouseButton and p_event.is_released() and \
		p_event.get_button_index() == MOUSE_BUTTON_LEFT:
			_input_mode = 1 
	else:
			_input_mode = 0
	
	match get_setting("editors/3d/navigation/navigation_scheme", 0):
		2, 1: # Modo, Maya
			if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) or \
	 			( Input.is_key_pressed(KEY_ALT) and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) ):
					_input_mode = -1 
			if p_event is InputEventMouseButton and p_event.is_released() and \
				( p_event.get_button_index() == MOUSE_BUTTON_RIGHT or \
				( Input.is_key_pressed(KEY_ALT) and p_event.get_button_index() == MOUSE_BUTTON_LEFT )):
					rmb_release_time = Time.get_ticks_msec()
		0, _: # Godot
			if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) or \
				Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
					_input_mode = -1 
			if p_event is InputEventMouseButton and p_event.is_released() and \
				( p_event.get_button_index() == MOUSE_BUTTON_RIGHT or \
				p_event.get_button_index() == MOUSE_BUTTON_MIDDLE ):
					rmb_release_time = Time.get_ticks_msec()
	if _input_mode < 0:
		# Camera is moving, skip input
		return AFTER_GUI_INPUT_PASS

	## Determine modifiers pressed
	modifier_shift = Input.is_key_pressed(KEY_SHIFT)
	
	# Editor responds to modifier_ctrl so we must register touchscreen Invert 
	if _use_meta:
		modifier_ctrl = Input.is_key_pressed(KEY_META) || ui.inverted_input
	else:
		modifier_ctrl = Input.is_key_pressed(KEY_CTRL) || ui.inverted_input
	
	# Keybind enum: Alt,Space,Meta,Capslock
	var alt_key: int
	match get_setting("pasture3d/config/alt_key_bind", 0):
		3: alt_key = KEY_CAPSLOCK
		2: alt_key = KEY_META
		1: alt_key = KEY_SPACE
		0, _: alt_key = KEY_ALT
	modifier_alt = Input.is_key_pressed(alt_key)
	var current_mods: int = int(modifier_shift) | int(modifier_ctrl) << 1 | int(modifier_alt) << 2

	## Process Hotkeys
	if p_event is InputEventKey and \
			current_mods == 0 and \
			p_event.is_pressed() and \
			consume_hotkey(p_event):
		# Hotkey found, consume event, and stop input processing
		EditorInterface.get_editor_viewport_3d().set_input_as_handled()
		return AFTER_GUI_INPUT_STOP

	# Brush data is cleared on set_tool, or clicking textures in the asset dock
	# Update modifiers if changed or missing
	if  _last_modifiers != current_mods or not ui.brush_data.has("modifier_shift"):
		_last_modifiers = current_mods
		ui.brush_data["modifier_shift"] = modifier_shift
		ui.brush_data["modifier_ctrl"] = modifier_ctrl
		ui.brush_data["modifier_alt"] = modifier_alt
		ui.set_active_operation()

	## Continue processing input
	return AFTER_GUI_INPUT_CUSTOM


# Returns true if hotkey matches and operation triggered
func consume_hotkey(p_event: InputEventKey) -> bool:
	# Handle repeatable keys
	match p_event.keycode:
		KEY_BRACKETLEFT:
			ui.tool_settings.set_setting("size", ui.tool_settings.get_setting("size") - 1)
			return true
		KEY_BRACKETRIGHT:
			ui.tool_settings.set_setting("size", ui.tool_settings.get_setting("size") + 1)
			return true
		KEY_MINUS:
			ui.tool_settings.set_setting("strength", ui.tool_settings.get_setting("strength") - 1)
			return true
		KEY_EQUAL:
			ui.tool_settings.set_setting("strength", ui.tool_settings.get_setting("strength") + 1)
			return true
		
	if p_event.is_echo():
		return false
		
	# Handle non-repeatable keys
	match p_event.keycode:
		KEY_1, KEY_KP_1:
			terrain.material.set_show_region_grid(!terrain.material.get_show_region_grid())
		KEY_2, KEY_KP_2:
			terrain.label_distance = 4096.0 if is_zero_approx(terrain.label_distance) else 0.0 
		KEY_3, KEY_KP_3:
			terrain.material.set_show_contours(!terrain.material.get_show_contours())
		KEY_4, KEY_KP_4:
			terrain.material.set_show_instancer_grid(!terrain.material.get_show_instancer_grid())
		KEY_5, KEY_KP_5:
			terrain.material.set_show_vertex_grid(!terrain.material.get_show_vertex_grid())
		KEY_E:
			ui.toolbar.get_button("AddRegion").set_pressed(true)
		KEY_R:
			ui.toolbar.get_button("Raise").set_pressed(true)
		KEY_H:
			ui.toolbar.get_button("Height").set_pressed(true)
		KEY_S:
			ui.toolbar.get_button("Slope").set_pressed(true)
		KEY_G:
			ui.toolbar.get_button("EraseLayer").set_pressed(true)
		KEY_C:
			ui.toolbar.get_button("PaintColor").set_pressed(true)
		KEY_N:
			ui.toolbar.get_button("PaintNavigableArea").set_pressed(true)
		KEY_I:
			ui.toolbar.get_button("InstanceMeshes").set_pressed(true)
		KEY_X:
			ui.toolbar.get_button("AddHoles").set_pressed(true)
		KEY_W:
			ui.toolbar.get_button("PaintWetness").set_pressed(true)
		KEY_B:
			ui.toolbar.get_button("PaintTexture").set_pressed(true)
		KEY_V:
			ui.toolbar.get_button("SprayTexture").set_pressed(true)
		KEY_A:
			ui.toolbar.get_button("PaintAutoshader").set_pressed(true)
		KEY_T:
			ui.tool_settings.inverse_slope_range()
		_:
			return false
	return true


func _on_scene_changed(scene_root: Node) -> void:
	if debug:
		print("Pasture3DEditorPlugin: _on_scene_changed: ", scene_root)
	if not scene_root:
		return
		
	for node in scene_root.find_children("", "Pasture3DObjects"):
		node.editor_setup(self)

	asset_dock.update_assets()


func get_terrain() -> Pasture3D:
	if is_terrain_valid():
		return terrain
	elif is_instance_valid(_last_terrain) and is_terrain_valid(_last_terrain):
		return _last_terrain
	else:
		return null


func is_terrain_valid(p_terrain: Pasture3D = null) -> bool:
	var t: Pasture3D
	if p_terrain:
		t = p_terrain
	else:
		t = terrain
	if is_instance_valid(t) and t.is_inside_tree() and t.data:
		return true
	return false


func is_selected() -> bool:
	var selected: Array[Node] = EditorInterface.get_selection().get_selected_nodes()
	for node in selected:
		if ( is_instance_valid(_last_terrain) and node.get_instance_id() == _last_terrain.get_instance_id() ) or \
			node is Pasture3D:
				return true
	return false	


func select_terrain() -> void:
	if debug and is_selected():
		print("Pasture3DEditorPlugin: Terrain is selected, skipping")
	if is_instance_valid(_last_terrain) and is_terrain_valid(_last_terrain) and not is_selected():
		var es: EditorSelection = EditorInterface.get_selection()
		if debug:
			print("Pasture3DEditorPlugin: Clearing and reselecting terrain")
		es.clear()
		es.add_node(_last_terrain)


## Editor Settings


func setup_editor_settings() -> void:
	editor_settings = EditorInterface.get_editor_settings()
	if not editor_settings.has_setting("pasture3d/config/alt_key_bind"):
		editor_settings.set("pasture3d/config/alt_key_bind", 0)
	var property_info = {
		"name": "pasture3d/config/alt_key_bind",
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": "Alt,Space,Meta,Capslock"
	}
	editor_settings.add_property_info(property_info)
	

func set_setting(p_str: String, p_value: Variant) -> void:
	editor_settings.set_setting(p_str, p_value)


func get_setting(p_str: String, p_default: Variant) -> Variant:
	if editor_settings.has_setting(p_str):
		return editor_settings.get_setting(p_str)
	else:
		return p_default


func has_setting(p_str: String) -> bool:
	return editor_settings.has_setting(p_str)


func erase_setting(p_str: String) -> void:
	editor_settings.erase(p_str)


## Undo / Redo Functions


func create_undo_action(p_action_name: String) -> void:
	get_undo_redo().create_action(p_action_name, UndoRedo.MERGE_DISABLE, terrain)


func add_undo_method(p_method: Callable) -> void:
	var args := [ p_method.get_object(), p_method.get_method() ]
	args.append_array(p_method.get_bound_arguments())
	get_undo_redo().add_undo_method.callv(args)


func add_do_method(p_method: Callable) -> void:
	var args := [ p_method.get_object(), p_method.get_method() ]
	args.append_array(p_method.get_bound_arguments())
	get_undo_redo().add_do_method.callv(args)


func commit_action(p_execute: bool) -> void:
	get_undo_redo().commit_action(p_execute)
