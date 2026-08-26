# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphFrameData — persistent Resource holding configuration and state for a GraphFrame
# container in a Pasture3DTerrainGraph (title, tint color, layout offset, size, attached nodes).
@tool
class_name Pasture3DGraphFrameData
extends Resource

@export var title: String = "Group":
	set(v):
		title = v
		emit_changed()

@export var tint_color: Color = Color(0.2, 0.25, 0.35, 0.75):
	set(v):
		tint_color = v
		emit_changed()

@export var position_offset: Vector2 = Vector2.ZERO

@export var size: Vector2 = Vector2(320, 240)

@export var attached_node_indices: PackedInt32Array = PackedInt32Array():
	set(v):
		attached_node_indices = v
		emit_changed()

@export var autoshrink: bool = true:
	set(v):
		autoshrink = v
		emit_changed()
