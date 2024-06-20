## Import From SimpleGrassTextured
# 
# This script demonstrates how to import transforms from SGT. To use it:
#
# 1. Assign this script to your Terrain3D node and reselect the node to update the inspector.
# 2. In the inspector select your SGT node.
# 3. Setup the desired mesh asset in the asset dock.
# 4. Assign that mesh id in the inspector.
# 5. Click Import.
#
# Use clear_instances to erase the whole storage multimesh dictionary.
#
# The add_transforms function applies the height_offset in the Terrain3DMeshAsset. This script
# provides an additional height offset, and also demonstrates how to move the mesh along its 
# local Y axis via code.
#
# The SimpleGrassTextured default mesh is a cross of two texture cards. The default Terrain3D 
# texture card is a single quadmesh, so assign your own mesh if you wish an exact match. Once the 
# transforms are imported, you can reassign any mesh you like into this mesh slot.

@tool
extends Terrain3D

@export var simple_grass_textured: MultiMeshInstance3D
@export var assign_mesh_id: int
@export var height_offset: float
@export var import: bool = false : set = import_sgt
@export var clear_instances: bool = false : set = clear_multimeshes


func clear_multimeshes(value: bool) -> void:
	storage.set_multimeshes(Dictionary())


func import_sgt(value: bool) -> void:
	var sgt_mm: MultiMesh = simple_grass_textured.multimesh
	var global_xform: Transform3D = simple_grass_textured.global_transform
	var xforms: Array[Transform3D]
	var colors: Array[Color]
	
	print("Starting to import %d instances from SimpleGrassTextured using mesh id %d" % [ sgt_mm.instance_count, assign_mesh_id])
	if sgt_mm.instance_count > 20000:
		print("This may take a while")
	
	for i in sgt_mm.instance_count:
		var trns: Transform3D = global_xform
		trns *= sgt_mm.get_instance_transform(i)
		trns.origin += trns.basis.y * height_offset
		xforms.push_back(trns)
		var color := Color.WHITE
		if sgt_mm.use_colors:
			color = sgt_mm.get_instance_color(i)
		colors.push_back(color)

	if xforms.size() > 0:
		get_instancer().add_transforms(assign_mesh_id, xforms, colors)

	print("Import complete")
	
