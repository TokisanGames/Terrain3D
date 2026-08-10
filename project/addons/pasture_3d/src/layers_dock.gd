# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Layers dock for Pasture3D — the editor UI for the non-destructive height-map layer stack.
# See PASTURE3D_LAYERS_GUIDE.md §6. The list mirrors Pasture3DData's bound stack API; structural
# and visual changes recomposite the affected regions so the viewport stays live.
@tool
extends PanelContainer

const BLEND_NAMES: Array[String] = [ "Replace", "Add", "Max", "Min" ]
# Option index -> Pasture3DLayer.BlendMode. BLEND_MAX (placeholder) is intentionally omitted.
const BLEND_MODES: Array[int] = [
	Pasture3DLayer.REPLACE, Pasture3DLayer.ADD, Pasture3DLayer.MAX, Pasture3DLayer.MIN ]
# Owner_id namespace of brush tool layers (Pasture3DTerrainBrush.BRUSH_OWNER_PREFIX). Used to tell a
# tool layer apart from hand layers / road-connector layers when flagging orphaned tool layers.
const BRUSH_OWNER_PREFIX: String = "pasture3d_brush:"

var plugin: EditorPlugin
var terrain: Pasture3D

var _list: VBoxContainer
var _add_btn: Button
var _dup_btn: Button
var _clear_btn: Button
var _del_btn: Button
var _up_btn: Button
var _down_btn: Button
var _warning: Label
var _warning_timer: Timer
var _rows: Array = []
var _assigned_owners: Dictionary = {} # owner_id -> true, the tool layers some brush node targets
## The Pasture3DData we're currently subscribed to for layers_changed, so set_terrain can unsubscribe
## from the previous one. Held as a plain ref (Resource) — always checked with is_instance_valid.
var _watched_data: Pasture3DData = null


func initialize(p_plugin: EditorPlugin) -> void:
	plugin = p_plugin
	name = "Pasture3D Layers"
	# Dock first so the control is in the tree and theme icons resolve while building the toolbar.
	plugin.add_control_to_dock(EditorPlugin.DOCK_SLOT_LEFT_BR, self)

	var root := VBoxContainer.new()
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(root)

	# Toolbar
	var bar := HBoxContainer.new()
	root.add_child(bar)
	var title := Label.new()
	title.text = "Layers"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(title)
	_add_btn = _make_tool_button(bar, "Add", "Add", "Add a new layer above the active one")
	_dup_btn = _make_tool_button(bar, "Duplicate", "Duplicate", "Duplicate the active layer")
	_clear_btn = _make_tool_button(bar, "Clear", "Clear",
		"Clear the active layer's baked data, keeping the layer.\n"
		+ "On a tool layer, the tools still bound to it re-bake immediately — so what this drops is the "
		+ "orphaned footprint of tools that were deleted, moved or reassigned.")
	_del_btn = _make_tool_button(bar, "Remove", "Remove", "Remove the active layer")
	_up_btn = _make_tool_button(bar, "MoveUp", "ArrowUp", "Move the active layer up (composites later)")
	_down_btn = _make_tool_button(bar, "MoveDown", "ArrowDown", "Move the active layer down")
	_add_btn.pressed.connect(_on_add)
	_dup_btn.pressed.connect(_on_duplicate)
	_clear_btn.pressed.connect(_on_clear)
	_del_btn.pressed.connect(_on_remove)
	_up_btn.pressed.connect(_on_move_up)
	_down_btn.pressed.connect(_on_move_down)

	# Warning line (flashes when a stroke hits a locked/reserved layer)
	_warning = Label.new()
	_warning.add_theme_color_override("font_color", Color("FC7F7F"))
	_warning.visible = false
	root.add_child(_warning)
	_warning_timer = Timer.new()
	_warning_timer.one_shot = true
	_warning_timer.wait_time = 2.5
	_warning_timer.timeout.connect(func(): _warning.visible = false)
	add_child(_warning_timer)

	# Scrollable layer list
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)

	refresh()


func _make_tool_button(p_parent: Node, p_name: String, p_icon: String, p_tip: String) -> Button:
	var b := Button.new()
	b.name = p_name
	b.tooltip_text = p_tip
	b.flat = true
	if EditorInterface.get_edited_scene_root() != self and has_theme_icon(p_icon, "EditorIcons"):
		b.icon = get_theme_icon(p_icon, "EditorIcons")
	else:
		b.text = p_name # No icon in this editor theme — a blank flat button is unclickable-looking.
	p_parent.add_child(b)
	return b


func remove_dock() -> void:
	if plugin:
		plugin.remove_control_from_docks(self)


func set_terrain(p_terrain: Pasture3D) -> void:
	terrain = p_terrain
	refresh()


## Subscribe to the current data's layers_changed so layers created OUTSIDE this dock show up without a
## re-selection — a brush's "Add New Layer", a brush's first bake, a road connector, the Sim. Deferred so
## the rebuild lands at idle rather than mid-bake, and re-pointed whenever the terrain (or its data) changes.
func _watch_layers_changed() -> void:
	var d := _data()
	if d == _watched_data:
		return
	# has_signal guards a plugin running against an older extension build, where the signal is absent and
	# the dock simply keeps its previous (re-selection driven) behaviour instead of erroring.
	if is_instance_valid(_watched_data) and _watched_data.has_signal("layers_changed") \
			and _watched_data.is_connected("layers_changed", refresh):
		_watched_data.disconnect("layers_changed", refresh)
	_watched_data = d
	if d and d.has_signal("layers_changed") and not d.is_connected("layers_changed", refresh):
		d.connect("layers_changed", refresh, CONNECT_DEFERRED)


func _data() -> Pasture3DData:
	if is_instance_valid(terrain) and terrain.data:
		return terrain.data
	return null


func _stack() -> Pasture3DLayerStack:
	var d := _data()
	if d and d.has_layer_stack():
		return d.get_layer_stack()
	return null


## Flash a UE-style warning. Called by the editor plugin when a stroke is blocked.
func flash_warning(p_layer_name: String, p_hidden: bool = false) -> void:
	if p_hidden:
		_warning.text = "Layer '%s' is hidden — stroke blocked. Make it visible to paint." % p_layer_name
	else:
		_warning.text = "Layer '%s' is locked or reserved — stroke blocked" % p_layer_name
	_warning.visible = true
	_warning_timer.start()


## Rebuild the whole list from the current stack.
func refresh() -> void:
	if not is_instance_valid(_list):
		return
	_watch_layers_changed()
	# Detach before freeing: queue_free leaves the node parented until the end of the frame, so two
	# refreshes in one frame (an explicit one plus the deferred layers_changed one) would otherwise
	# stack a duplicate set of rows into the list.
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	_rows.clear()

	var d := _data()
	# A freshly added node has no stack yet (the Base is only synthesized on load). Create one so the
	# panel can show and grow it. Add stays enabled whenever a terrain is selected.
	if d:
		d.ensure_layer_stack()
	_add_btn.disabled = d == null

	var stack := _stack()
	_dup_btn.disabled = stack == null
	if stack == null:
		return

	# Which tool layers a Pasture3DTerrainBrush currently targets — recomputed each refresh so the
	# orphaned-tool-layer badges stay current as tools are added/removed/reassigned.
	_assigned_owners = _assigned_brush_owners()

	var count: int = stack.get_layer_count()
	# List top layer first so the visual order matches compositing (top = drawn last/over).
	for i in range(count - 1, -1, -1):
		var layer: Pasture3DLayer = stack.get_layer(i)
		if layer == null:
			continue
		var row := _build_row(i, layer)
		_rows.append(row)
		_list.add_child(row)

	_sync_active_state()


## Repaint the active-row highlight and the toolbar's enabled state from the stack's active layer. Split
## out of refresh() so merely CHANGING the active layer doesn't have to rebuild the rows — rebuilding them
## on click is what made the name field unclickable, since it freed the field under the cursor.
func _sync_active_state() -> void:
	var stack := _stack()
	if stack == null:
		return
	var active: int = stack.get_active_layer()
	var count: int = stack.get_layer_count()
	for row in _rows:
		if not is_instance_valid(row):
			continue
		if int(row.get_meta("layer_idx", -1)) == active:
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(0.26, 0.45, 0.78, 0.5)
			sb.set_content_margin_all(3)
			row.add_theme_stylebox_override("panel", sb)
		else:
			row.remove_theme_stylebox_override("panel")
	_del_btn.disabled = active == 0
	# Base is excluded for the same reason Remove is, plus a sharper one: a single-layer Base ALIASES the
	# region height images (Pasture3DData::refresh_base_alias), so dropping its tiles would detach the
	# terrain's own maps rather than clear a layer.
	_clear_btn.disabled = active == 0
	_up_btn.disabled = active == 0 or active >= count - 1
	_down_btn.disabled = active <= 1


func _build_row(p_idx: int, p_layer: Pasture3DLayer) -> Control:
	var row := PanelContainer.new()
	row.set_meta("layer_idx", p_idx)
	# Focusable and input-consuming so clicking anywhere on the row selects it and F2 then reaches it,
	# the way selecting a node and pressing F2 works elsewhere in the editor.
	row.focus_mode = Control.FOCUS_ALL
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.gui_input.connect(func(e): _on_row_input(p_idx, row, e))

	var hb := HBoxContainer.new()
	row.add_child(hb)

	# Visibility toggle
	var vis := CheckButton.new()
	vis.button_pressed = p_layer.is_visible()
	vis.tooltip_text = "Visible"
	vis.toggled.connect(func(v): _on_visible(p_idx, v))
	hb.add_child(vis)

	# Warning badge: orphaned tool layer (no tool targets it) or, as a fallback, an empty layer.
	var status := _layer_status(p_layer)
	if status != "":
		var warn := TextureRect.new()
		warn.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		warn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		if EditorInterface.get_edited_scene_root() != self:
			warn.texture = get_theme_icon("NodeWarning", "EditorIcons")
		if status == "orphan":
			warn.tooltip_text = "Tool layer '%s' has no tools assigned — safe to delete, or assign a tool to it." % p_layer.get_layer_name()
		else:
			warn.tooltip_text = "Layer '%s' is empty (nothing painted into it yet)." % p_layer.get_layer_name()
		hb.add_child(warn)

	# Name. Read-only until you ask to rename, so a single click can select the row instead of being eaten
	# by a text field — and so the field survives the click at all. Rename is double-click or F2, matching
	# how nodes are renamed in the Scene dock; Enter or clicking away commits.
	var name_edit := LineEdit.new()
	name_edit.text = p_layer.get_layer_name()
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.tooltip_text = "Layer name — double-click or F2 to rename (Base is index 0)"
	name_edit.editable = false
	name_edit.selecting_enabled = false
	name_edit.flat = true # reads as a label until it is actually being edited
	name_edit.text_submitted.connect(func(t): _commit_rename(p_idx, name_edit, t))
	name_edit.focus_exited.connect(func(): _commit_rename(p_idx, name_edit, name_edit.text))
	name_edit.gui_input.connect(func(e): _on_name_input(p_idx, name_edit, e))
	row.set_meta("name_edit", name_edit)
	hb.add_child(name_edit)

	# Blend mode
	var blend := OptionButton.new()
	for n in BLEND_NAMES:
		blend.add_item(n)
	blend.select(BLEND_MODES.find(p_layer.get_blend_mode()))
	blend.tooltip_text = "Blend mode"
	blend.item_selected.connect(func(sel): _on_blend(p_idx, sel))
	hb.add_child(blend)

	# Opacity
	var op := HSlider.new()
	op.min_value = 0.0
	op.max_value = 1.0
	op.step = 0.01
	op.value = p_layer.get_opacity()
	op.custom_minimum_size = Vector2(70, 0)
	op.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	op.tooltip_text = "Opacity"
	op.value_changed.connect(func(v): _on_opacity(p_idx, v))
	hb.add_child(op)

	# Lock toggle
	var lock := CheckButton.new()
	lock.button_pressed = p_layer.is_locked()
	lock.tooltip_text = "Locked (blocks sculpting)"
	lock.toggled.connect(func(v): _on_lock(p_idx, v))
	hb.add_child(lock)

	# Drag-reorder support lives on the row.
	row.set_drag_forwarding(
		_get_row_drag.bind(p_idx), _can_drop_row.bind(p_idx), _drop_row.bind(p_idx))
	return row


## ---- Tool-layer health (orphaned / empty) ----

## owner_ids of the tool layers that some Pasture3DTerrainBrush in the edited scene currently targets.
func _assigned_brush_owners() -> Dictionary:
	var owners := {}
	var root := EditorInterface.get_edited_scene_root()
	if root:
		_collect_brush_owners(root, owners)
	return owners


func _collect_brush_owners(node: Node, owners: Dictionary) -> void:
	var brush := node as Pasture3DTerrainBrush
	if brush and brush.terrain == terrain and brush._layer_owner != "":
		owners[brush._layer_owner] = true
	for c in node.get_children():
		_collect_brush_owners(c, owners)


## "" = healthy, "orphan" = brush tool layer no tool targets, "empty" = non-base layer with no tiles.
## Orphan is the primary signal (requirement 4); empty is the fallback (requirement 5).
func _layer_status(p_layer: Pasture3DLayer) -> String:
	var owner := p_layer.get_owner_id()
	if p_layer.is_reserved() and owner.begins_with(BRUSH_OWNER_PREFIX) and not _assigned_owners.has(owner):
		return "orphan"
	if not p_layer.is_base() and p_layer.get_region_locations().is_empty():
		return "empty"
	return ""


## Row interactions


## Selecting a row repaints the highlight rather than rebuilding the list. The old full refresh is what
## made the name field unclickable: it freed the LineEdit mid-click, so a caret could never land in it.
func _set_active(p_idx: int) -> void:
	var stack := _stack()
	if stack == null or stack.get_active_layer() == p_idx:
		return
	stack.set_active_layer(p_idx)
	_sync_active_state()


func _on_row_input(p_idx: int, p_row: Control, p_event: InputEvent) -> void:
	if p_event is InputEventMouseButton and p_event.pressed and p_event.button_index == MOUSE_BUTTON_LEFT:
		_set_active(p_idx)
		p_row.grab_focus() # so F2 reaches this row next
	elif p_event is InputEventKey and p_event.pressed and p_event.keycode == KEY_F2:
		var le = p_row.get_meta("name_edit", null)
		if le is LineEdit:
			_begin_rename(le)


## Clicks and keys on the name field itself. Single click selects the row (the field is read-only, so it
## has nothing to do with the caret); double-click or F2 starts the rename.
func _on_name_input(p_idx: int, p_edit: LineEdit, p_event: InputEvent) -> void:
	if p_event is InputEventMouseButton and p_event.pressed and p_event.button_index == MOUSE_BUTTON_LEFT:
		if p_event.double_click:
			_begin_rename(p_edit)
		else:
			_set_active(p_idx)
	elif p_event is InputEventKey and p_event.pressed and p_event.keycode == KEY_F2:
		_begin_rename(p_edit)
	elif p_event is InputEventKey and p_event.pressed and p_event.keycode == KEY_ESCAPE and p_edit.editable:
		_cancel_rename(p_idx, p_edit) # abandon the edit, as Escape does in the Scene dock


func _begin_rename(p_edit: LineEdit) -> void:
	if p_edit.editable:
		return
	p_edit.editable = true
	p_edit.selecting_enabled = true
	p_edit.flat = false
	p_edit.grab_focus()
	p_edit.select_all()


## Leave rename mode and apply the name. Reached from Enter (text_submitted) and from clicking away
## (focus_exited) — the editable guard makes the second one a no-op on a field that was never in rename
## mode, and makes Enter-then-blur commit once rather than twice.
func _commit_rename(p_idx: int, p_edit: LineEdit, p_text: String) -> void:
	if not p_edit.editable:
		return
	_end_rename(p_edit)
	_on_rename(p_idx, p_text)


## Escape: drop the edit and put the stored name back, so no rename (and no undo entry) is recorded.
func _cancel_rename(p_idx: int, p_edit: LineEdit) -> void:
	var stack := _stack()
	var layer: Pasture3DLayer = stack.get_layer(p_idx) if stack else null
	if layer:
		p_edit.text = layer.get_layer_name()
	_end_rename(p_edit) # clears `editable` first, so the focus_exited below hits _commit_rename's guard
	p_edit.release_focus()


func _end_rename(p_edit: LineEdit) -> void:
	p_edit.editable = false
	p_edit.selecting_enabled = false
	p_edit.flat = true
	p_edit.deselect()


## Row-control edits (visibility, lock, opacity, blend, name) are all one shape: apply live, then record
## the old→new pair as undoable. They edit ONE property of ONE layer, so unlike the toolbar's structural
## actions there is nothing to snapshot — the two values are the whole state.
##
## The live application is deliberately kept out of the undo action (see _commit_property_action).


func _on_visible(p_idx: int, p_visible: bool) -> void:
	var stack := _stack()
	if not stack:
		return
	var layer: Pasture3DLayer = stack.get_layer(p_idx)
	if layer:
		var old := layer.is_visible()
		layer.set_visible(p_visible)
		_data().recomposite_layer(p_idx)
		_mark_unsaved()
		_commit_property_action("Toggle Pasture3D Layer Visibility", p_idx, "set_visible", old, p_visible, true)


func _on_lock(p_idx: int, p_locked: bool) -> void:
	var stack := _stack()
	if not stack:
		return
	var layer: Pasture3DLayer = stack.get_layer(p_idx)
	if layer:
		var old := layer.is_locked()
		layer.set_locked(p_locked)
		_mark_unsaved()
		_commit_property_action("Toggle Pasture3D Layer Lock", p_idx, "set_locked", old, p_locked, false)


func _on_opacity(p_idx: int, p_value: float) -> void:
	var stack := _stack()
	if not stack:
		return
	var layer: Pasture3DLayer = stack.get_layer(p_idx)
	if layer:
		var old := layer.get_opacity()
		layer.set_opacity(p_value)
		_data().recomposite_layer(p_idx)
		_mark_unsaved()
		# MERGE_ENDS collapses a drag's stream of value_changed into ONE entry: it keeps the first action's
		# undo (the pre-drag opacity) and the last one's do. The action name carries the layer name so a
		# drag on a different layer starts a new entry instead of merging into the previous layer's.
		_commit_property_action("Set Pasture3D Layer Opacity — %s" % layer.get_layer_name(),
			p_idx, "set_opacity", old, p_value, true, UndoRedo.MERGE_ENDS)


func _on_blend(p_idx: int, p_selected: int) -> void:
	var stack := _stack()
	if not stack or p_selected < 0 or p_selected >= BLEND_MODES.size():
		return
	var layer: Pasture3DLayer = stack.get_layer(p_idx)
	if layer:
		var old := layer.get_blend_mode()
		layer.set_blend_mode(BLEND_MODES[p_selected])
		_data().recomposite_layer(p_idx)
		_mark_unsaved()
		_commit_property_action("Set Pasture3D Layer Blend Mode", p_idx, "set_blend_mode",
			old, BLEND_MODES[p_selected], true)


func _on_rename(p_idx: int, p_text: String) -> void:
	var stack := _stack()
	if not stack:
		return
	var layer: Pasture3DLayer = stack.get_layer(p_idx)
	if layer:
		var old := layer.get_layer_name()
		layer.set_layer_name(p_text)
		_mark_unsaved()
		_commit_property_action("Rename Pasture3D Layer", p_idx, "set_layer_name", old, p_text, false)


## Record an already-applied row edit. commit_action(false) because the handler applied it live — letting
## UndoRedo re-run the do here would repeat the recomposite, and for the opacity slider would rebuild the
## very row being dragged. Undo and redo both route through _apply_layer_property so the two directions
## can't drift apart. A no-op edit records nothing.
func _commit_property_action(p_name: String, p_idx: int, p_setter: String, p_old: Variant, p_new: Variant,
		p_recomposite: bool, p_merge: int = UndoRedo.MERGE_DISABLE) -> void:
	var ur := EditorInterface.get_editor_undo_redo()
	if ur == null or p_old == p_new:
		return
	ur.create_action(p_name, p_merge, terrain)
	ur.add_do_method(self, "_apply_layer_property", p_idx, p_setter, p_new, p_recomposite)
	ur.add_undo_method(self, "_apply_layer_property", p_idx, p_setter, p_old, p_recomposite)
	ur.commit_action(false)


## Set one property on one layer, recompositing when it changes what the layer contributes. The full
## refresh here is for the undo/redo path only, where the rows must be rebuilt to show the restored value.
func _apply_layer_property(p_idx: int, p_setter: String, p_value: Variant, p_recomposite: bool) -> void:
	var d := _data()
	var stack := _stack()
	if not d or not stack:
		return
	var layer: Pasture3DLayer = stack.get_layer(p_idx)
	if layer == null:
		return
	layer.call(p_setter, p_value)
	if p_recomposite:
		d.recomposite_layer(p_idx)
	refresh()
	_mark_unsaved()


## Toolbar actions
##
## Add / Duplicate / Remove share one undo mechanism: snapshot the stack's layer ARRAY (plus the active
## index) either side of the operation, and make both directions a restore of one of those snapshots. It
## suits these three because they only rearrange which layer objects the stack holds — the objects
## themselves are untouched, so the snapshot can share them by reference and stays cheap no matter how
## much is painted into them. A removed layer stays alive purely because the snapshot array still
## references it, which is what makes undoing a Remove exact rather than a reconstruction.
##
## Clear is deliberately NOT on this mechanism: it mutates a layer's tiles in place, which a shared-object
## snapshot cannot capture, so it deep-copies the tiles instead (see _on_clear).


func _on_add() -> void:
	var d := _data()
	if not d:
		return
	var before := _stack_snapshot()
	var stack := _stack()
	var n: int = stack.get_layer_count() if stack else 0
	# Hand-sculpt layers author absolute heights, so REPLACE is the sane default (§11).
	var idx: int = d.layer_add("Layer %d" % n, Pasture3DLayer.REPLACE)
	if idx >= 0:
		d.get_layer_stack().set_active_layer(idx)
	refresh()
	_mark_unsaved()
	_commit_stack_action("Add Pasture3D Layer", before)


func _on_duplicate() -> void:
	var d := _data()
	var stack := _stack()
	if not d or not stack:
		return
	var before := _stack_snapshot()
	var idx: int = d.layer_duplicate(stack.get_active_layer())
	if idx >= 0:
		d.get_layer_stack().set_active_layer(idx)
	refresh()
	_mark_unsaved()
	_commit_stack_action("Duplicate Pasture3D Layer", before)


## Snapshot of the stack's structure: which layer objects it holds, in order, and which is active.
## get_layers() hands back a reference to the live array, so this duplicates it — otherwise the "before"
## snapshot would track the very mutation it is meant to reverse.
func _stack_snapshot() -> Dictionary:
	var stack := _stack()
	if stack == null:
		return {}
	return { "layers": stack.get_layers().duplicate(), "active": stack.get_active_layer() }


## Register an already-performed structural change as undoable. The operation has run by the time this is
## called, so the action is committed WITHOUT executing (commit_action(false)) — as the brush's bake undo
## does — and simply records how to get back to either side.
func _commit_stack_action(p_name: String, p_before: Dictionary) -> void:
	var ur := EditorInterface.get_editor_undo_redo()
	if ur == null or p_before.is_empty():
		return
	var after := _stack_snapshot()
	if after.is_empty():
		return
	ur.create_action(p_name, UndoRedo.MERGE_DISABLE, terrain)
	ur.add_do_method(self, "_restore_stack", after)
	ur.add_undo_method(self, "_restore_stack", p_before)
	ur.commit_action(false)


## Put the stack back into a snapshotted structure. Recomposites only the regions covered by the layers
## that differ between now and the target — those are exactly the layers being added or taken away, so a
## big terrain doesn't pay a full recomposite for a one-layer change.
func _restore_stack(p_snapshot: Dictionary) -> void:
	var d := _data()
	var stack := _stack()
	if not d or not stack or p_snapshot.is_empty():
		return
	var affected := _regions_of_differing_layers(stack.get_layers(), p_snapshot["layers"])
	stack.set_layers(p_snapshot["layers"].duplicate())
	stack.set_active_layer(int(p_snapshot["active"]))
	for loc in affected:
		d.composite_region(loc, Rect2i(), false)
	# Full push: a whole-stack swap is the same risk class as a bake undo, where a targeted per-region
	# push left distant regions visually stale.
	d.update_maps()
	refresh()
	_mark_unsaved()


## Region locations covered by the layers present in one array but not the other (either direction).
func _regions_of_differing_layers(p_a: Array, p_b: Array) -> Dictionary:
	var out := {}
	for l in p_a:
		if l != null and not p_b.has(l):
			for loc in l.get_region_locations():
				out[loc] = true
	for l in p_b:
		if l != null and not p_a.has(l):
			for loc in l.get_region_locations():
				out[loc] = true
	return out


## Clear the active layer's baked data without removing the layer, then let the tools that still target it
## repaint. On a tool layer that is the point: the layer accumulates the footprint of every tool that ever
## baked into it, and a tool that was deleted, moved or reassigned leaves its contribution behind with
## nothing left to clear it (the row's "orphan" badge). Wiping and re-baking rebuilds the layer from the
## tools that actually exist. On a hand layer it is a plain erase.
##
## Deliberately NOT Pasture3DLayer.clear(), which also resets name / blend / opacity / owner_id / reserved /
## map_type — on a tool layer that would sever the brushes' owner binding. Only the tiles go.
## Undoable because on a HAND layer the wipe is unrecoverable — a tool layer rebuilds itself from its
## brushes, but hand-painted tiles have no other source. Routed to the terrain's scene-local history like
## the reorder action. Redo re-runs _apply_clear, which is deterministic for both kinds of layer.
func _on_clear() -> void:
	var d := _data()
	var stack := _stack()
	if not d or not stack:
		return
	var idx: int = stack.get_active_layer()
	var layer: Pasture3DLayer = stack.get_layer(idx)
	if layer == null or layer.is_base():
		return
	var ur := EditorInterface.get_editor_undo_redo()
	if ur == null:
		_apply_clear(idx)
		return
	# Snapshot BEFORE the wipe, and deep. get_tiles hands back the live Images by reference, and this one
	# dict is replayed on EVERY undo, not just the first — so if the layer were ever left aliasing it, the
	# next bake into the layer would quietly rewrite the undo entry. _restore_tiles copies on the way in
	# for the same reason; the pair keeps the snapshot immutable for the life of the action.
	var before := _copy_tiles(layer.get_tiles())
	ur.create_action("Clear Pasture3D Layer '%s'" % layer.get_layer_name(), UndoRedo.MERGE_DISABLE, terrain)
	ur.add_do_method(self, "_apply_clear", idx)
	ur.add_undo_method(self, "_restore_tiles", idx, before)
	ur.commit_action() # runs the do


## The clear itself — one entry point so redo replays exactly what the button did.
func _apply_clear(p_idx: int) -> void:
	var d := _data()
	var stack := _stack()
	if not d or not stack:
		return
	var layer: Pasture3DLayer = stack.get_layer(p_idx)
	if layer == null or layer.is_base():
		return
	# Snapshot the covered regions BEFORE the wipe: recomposite has to run over what the layer USED to
	# cover, and after set_tiles({}) that list is empty (the trap Pasture3DData::layer_remove avoids too).
	var locations := layer.get_region_locations()
	layer.set_tiles({})
	for loc in locations:
		d.composite_region(loc, Rect2i(), false)
	# Full push, not the edited-regions-only one: this is a whole-layer state swap, the same risk class as
	# a bake undo, where a targeted push left distant regions visually stale.
	d.update_maps()
	_rebake_tools_on_layer(layer)
	refresh()
	_mark_unsaved()


## Undo of _apply_clear: put the tiles back and recomposite. Covers the UNION of what the layer holds now
## (a tool layer has re-baked itself since) and what the snapshot restores — recompositing only the
## restored regions would leave a region the clear EMPTIED still showing the post-clear composite.
func _restore_tiles(p_idx: int, p_tiles: Dictionary) -> void:
	var d := _data()
	var stack := _stack()
	if not d or not stack:
		return
	var layer: Pasture3DLayer = stack.get_layer(p_idx)
	if layer == null:
		return
	var regions := {}
	for loc in layer.get_region_locations():
		regions[loc] = true
	# Copy on the way in too, so the undo entry stays intact for a second undo after a redo.
	layer.set_tiles(_copy_tiles(p_tiles))
	for loc in layer.get_region_locations():
		regions[loc] = true
	for loc in regions:
		d.composite_region(loc, Rect2i(), false)
	d.update_maps()
	refresh()
	_mark_unsaved()


## Deep copy of the {region_loc -> {tile_coord -> Image}} tile structure. get_tiles/set_tiles share the
## live Images by reference, so each one is copied to keep the snapshot immutable. Mirrors
## Pasture3DTerrainBrush._copy_tiles, which does the same for bake undo.
func _copy_tiles(p_tiles: Dictionary) -> Dictionary:
	var out := {}
	for loc in p_tiles:
		var inner: Dictionary = p_tiles[loc]
		var inner_copy := {}
		for coord in inner:
			var img: Image = inner[coord]
			if img:
				var c := Image.new()
				c.copy_from(img)
				inner_copy[coord] = c
			else:
				inner_copy[coord] = null
		out[loc] = inner_copy
	return out


## Ask the tools still bound to this layer to repaint it. One call is enough: Pasture3DTerrainBrush.refresh()
## goes through _refresh_owner, which repaints every tool sharing the owner_id, so calling it on the first
## one we find covers the rest (and calling it on each would just redo the same layer-wide bake N times).
## No-op for a hand layer (no owner) or a fully orphaned tool layer — which is then correctly left empty.
func _rebake_tools_on_layer(p_layer: Pasture3DLayer) -> void:
	var owner := p_layer.get_owner_id()
	if owner == "" or not owner.begins_with(BRUSH_OWNER_PREFIX):
		return
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	var brush := _find_tool_on_owner(root, owner)
	if brush:
		brush.refresh()


func _find_tool_on_owner(p_node: Node, p_owner: String) -> Pasture3DTerrainBrush:
	var brush := p_node as Pasture3DTerrainBrush
	if brush and brush.terrain == terrain and brush._layer_owner == p_owner:
		return brush
	for c in p_node.get_children():
		var found := _find_tool_on_owner(c, p_owner)
		if found:
			return found
	return null


func _on_remove() -> void:
	var d := _data()
	var stack := _stack()
	if not d or not stack:
		return
	var before := _stack_snapshot()
	d.layer_remove(stack.get_active_layer())
	refresh()
	_mark_unsaved()
	_commit_stack_action("Remove Pasture3D Layer", before)


func _on_move_up() -> void:
	_move_active(1)


func _on_move_down() -> void:
	_move_active(-1)


func _move_active(p_dir: int) -> void:
	var stack := _stack()
	if not stack:
		return
	var from: int = stack.get_active_layer()
	var to: int = from + p_dir
	if from <= 0 or to <= 0 or to >= stack.get_layer_count():
		return
	_move_layer_undoable(from, to)


## Drag-and-drop reordering (forwarded from each row)


func _get_row_drag(_pos: Vector2, p_idx: int) -> Variant:
	if p_idx == 0:
		return null # Base never moves.
	var preview := Label.new()
	var stack := _stack()
	var layer: Pasture3DLayer = stack.get_layer(p_idx) if stack else null
	preview.text = layer.get_layer_name() if layer else "Layer"
	set_drag_preview(preview)
	return { "p3d_layer": p_idx }


func _can_drop_row(_pos: Vector2, p_data: Variant, p_idx: int) -> bool:
	return typeof(p_data) == TYPE_DICTIONARY and p_data.has("p3d_layer") and p_idx != 0


func _drop_row(_pos: Vector2, p_data: Variant, p_idx: int) -> void:
	var stack := _stack()
	if not stack:
		return
	var from: int = int(p_data["p3d_layer"])
	var to: int = p_idx
	if from == to or from == 0 or to == 0:
		return
	_move_layer_undoable(from, to)


## Reorder a layer as one undoable action so Ctrl+Z restores the previous order. move_layer is its own
## inverse: undoing move(from→to) is move(to→from), so a single _apply_move serves both directions.
## Routed to the terrain's scene-local history via the custom context.
func _move_layer_undoable(p_from: int, p_to: int) -> void:
	var ur := EditorInterface.get_editor_undo_redo()
	if ur == null:
		_apply_move(p_from, p_to)
		return
	ur.create_action("Reorder Pasture3D Layer", UndoRedo.MERGE_DISABLE, terrain)
	ur.add_do_method(self, "_apply_move", p_from, p_to)
	ur.add_undo_method(self, "_apply_move", p_to, p_from)
	ur.commit_action()


## Apply a reorder and rebuild the list. One entry point for both do and undo, so call order is trivial.
func _apply_move(p_from: int, p_to: int) -> void:
	var d := _data()
	var stack := _stack()
	if not d or not stack:
		return
	d.layer_move(p_from, p_to)
	stack.set_active_layer(p_to)
	refresh()
	_mark_unsaved()


func _mark_unsaved() -> void:
	EditorInterface.mark_scene_as_unsaved()
