@tool
extends Node3D

#region settings
## Auto set if attached as a child of a Terrain3D node
@export var terrain: Terrain3D :
	set(value):
		terrain = value
		_create_grid()

## Distance between instances
@export_range(0.5, 16.0, 0.03125) var instance_spacing: float = 1.0:
	set(value):
		instance_spacing = value
		rows = maxi(int(cell_width / instance_spacing), 1)
		amount = rows * rows
		_set_offsets()

## Width of an individual cell of the grid
@export_range(8.0, 256.0, 1.0) var cell_width: float = 32.0:
	set(value):
		cell_width = value
		rows = maxi(int(cell_width / instance_spacing), 1)
		amount = rows * rows
		min_draw_distance = 1.0
		_set_offsets()

## Grid width. Must be odd. Higher values cull slightly better, draw further out.
@export_range(1, 9, 2) var grid_width: int = 3 :
	set(value):
		grid_width = value
		particle_count = 1
		min_draw_distance = 1.0
		_create_grid()

@export_storage var rows: int = 1
@export_storage var amount: int = 1 :
	set(value):
		amount = value
		particle_count = value
		for p in particle_nodes:
			p.amount = amount

## Access to process material parameters
@export var process_material: ShaderMaterial

## The mesh that each particle will render
@export var mesh: Mesh

@export var shadow_mode: GeometryInstance3D.ShadowCastingSetting = (
	GeometryInstance3D.ShadowCastingSetting.SHADOW_CASTING_SETTING_ON):
	set(value):
		shadow_mode = value
		for p in particle_nodes:
			p.cast_shadow = value

## Override material for the particle mesh
@export_custom(
	PROPERTY_HINT_RESOURCE_TYPE,
	"BaseMaterial3D,ShaderMaterial") var mesh_material_override: Material:
	set(value):
		mesh_material_override = value
		for p in particle_nodes:
			p.material_override = mesh_material_override

@export_group("Info")
## The minimum distance that particles will be drawn upto
## If using fade out effects like pixel alpha this is the limit to use.
@export var min_draw_distance: float = 1.0:
	set(value):
		min_draw_distance = float(cell_width * grid_width) * 0.5

## Info Only - displays current total particle count based on Cell Width and Instance Spacing
@export var particle_count: int = 1:
	set(value):
		particle_count = amount * grid_width * grid_width
#endregion

var offsets: Array[Vector3]
var last_pos: Vector3 = Vector3.ZERO
var particle_nodes: Array[GPUParticles3D]

func _set_offsets() -> void:
	var half_width: int = grid_width / 2
	offsets.clear()
	
	for x in range(-half_width, half_width + 1):
		for z in range(-half_width, half_width + 1):
			var offset = Vector3(
				float(x * rows) * instance_spacing,
				0.0,
				float(z * rows) * instance_spacing
			)
			offsets.append(offset)

func _update_process_parameters() -> void:
	if process_material:
		var process_rid: RID = process_material.get_rid()
		if terrain and process_rid.is_valid():
			RenderingServer.material_set_param(process_rid, "_background_mode", terrain.material.world_background)
			RenderingServer.material_set_param(process_rid, "_vertex_spacing", terrain.vertex_spacing)
			RenderingServer.material_set_param(process_rid, "_vertex_density", 1.0 / terrain.vertex_spacing)
			RenderingServer.material_set_param(process_rid, "_region_size", terrain.region_size)
			RenderingServer.material_set_param(process_rid, "_region_texel_size", 1.0 / terrain.region_size)
			RenderingServer.material_set_param(process_rid, "_region_map_size", 32)
			RenderingServer.material_set_param(process_rid, "_region_map", terrain.data.get_region_map())
			RenderingServer.material_set_param(process_rid, "_region_locations", terrain.data.get_region_locations())
			RenderingServer.material_set_param(process_rid, "_height_maps", terrain.data.get_height_maps_rid())
			RenderingServer.material_set_param(process_rid, "_control_maps", terrain.data.get_control_maps_rid())
			RenderingServer.material_set_param(process_rid, "instance_spacing", instance_spacing)
			RenderingServer.material_set_param(process_rid, "instance_rows", rows)
			if terrain.get_camera():
				RenderingServer.material_set_param(process_rid, "camera_position", terrain.get_camera().global_position)

func _create_grid() -> void:
	_destroy_grid()
	if not terrain:
		return
	_set_offsets()
	var hr: Vector2 = terrain.data.get_height_range()
	var height: float = hr.x - hr.y
	var aabb: AABB = AABB()
	aabb.size = Vector3(
		float(rows) * instance_spacing, height,
		float(rows) * instance_spacing)
	aabb.position = aabb.size * -0.5
	aabb.position.y = hr.y
	for i in range(grid_width * grid_width):
		var particle_node = GPUParticles3D.new()
		particle_node.amount = amount
		particle_node.lifetime = 1.0
		particle_node.explosiveness = 1.0
		particle_node.amount_ratio = 1.0
		particle_node.process_material = process_material
		particle_node.draw_pass_1 = mesh
		particle_node.speed_scale = 1.0
		particle_node.custom_aabb = aabb
		particle_node.cast_shadow = shadow_mode
		if mesh_material_override:
			particle_node.material_override = mesh_material_override
		particle_node.use_fixed_seed = true
		if i > 0: # Use the same seed across all nodes
			particle_node.seed = particle_nodes[0].seed
		# Compatibility behaves a bit different and doesnt update consistently
		# Setting this seems to avoid the issue. TODO: Investigate further
		if RenderingServer.get_current_rendering_method().contains("gl_compatibility"):
			particle_node.fixed_fps = 240.0
		self.add_child(particle_node)
		particle_node.emitting = true
		particle_nodes.push_back(particle_node)
		last_pos = Vector3.ZERO

func _position_grid(pos: Vector2) -> void:
	for i in particle_nodes.size():
		var node = particle_nodes[i]
		node.global_position = Vector3(pos.x, 0, pos.y) + offsets[i]
		node.restart(true) # keep the same seed.

func _destroy_grid() -> void:
	for node in particle_nodes:
		if is_instance_valid(node):
			node.queue_free()
	particle_nodes.clear()

func _ready() -> void:
	var parent = get_parent()
	if parent is Terrain3D:
		terrain = parent
	_create_grid()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_destroy_grid()

func _physics_process(delta: float) -> void:
	if terrain:
		var camera := terrain.get_camera()
		if camera:
			if Engine.is_editor_hint() or last_pos.distance_squared_to(camera.global_position) > 2.0:
				var pos: Vector2 = Vector2(
					round(camera.global_position.x / instance_spacing),
					round(camera.global_position.z / instance_spacing)
					) * instance_spacing
				_position_grid(pos)
				last_pos = camera.global_position
		_update_process_parameters()
