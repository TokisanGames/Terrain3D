# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphThumbnailGenerator — utility that renders compact 48x48 2D heightmap thumbnail previews
# with hillshade relief shading for GraphNode bodies.
@tool
class_name Pasture3DGraphThumbnailGenerator
extends RefCounted


## Generates an ImageTexture thumbnail for a given node in the graph.
static func generate_thumbnail(p_graph: Pasture3DTerrainGraph, p_node_index: int, p_size: int = 48) -> ImageTexture:
	if p_graph == null or p_node_index < 0 or p_node_index >= p_graph.nodes.size():
		return null
	var node: Pasture3DGraphNode = p_graph.nodes[p_node_index]
	if node == null:
		return null
		
	var w: int = p_size
	var h: int = p_size
	var n: int = w * h
	var rect := Rect2(-50.0, -50.0, 100.0, 100.0)
	
	# Evaluate heightfield
	var field := PackedFloat32Array()
	field.resize(n)
	
	if node.role() == Pasture3DGraphNode.Role.GENERATOR and node.input_count() == 0:
		# Pure generator: evaluate directly cell by cell
		for iz in range(h):
			var row := iz * w
			var wz: float = rect.position.y + (float(iz) / float(h)) * rect.size.y
			for ix in range(w):
				var wx: float = rect.position.x + (float(ix) / float(w)) * rect.size.x
				field[row + ix] = node.eval_cell(wx, wz, PackedFloat32Array())
	else:
		# Subgraph rooted at this node without side effects or signal emissions
		field = p_graph.evaluate(w, h, rect, null, null, p_node_index)
		
	if field.is_empty() or field.size() != n:
		return null
		
	# Find min/max for normalization
	var min_h: float = INF
	var max_h: float = -INF
	for i in range(n):
		var v: float = field[i]
		if not is_nan(v):
			min_h = minf(min_h, v)
			max_h = maxf(max_h, v)
			
	var h_range: float = maxf(max_h - min_h, 0.001)
	
	# Render 2D image with hillshade relief shading (light from North-West)
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var lx: float = -0.577
	var lz: float = -0.577
	var ly: float = 0.577
	
	for iz in range(h):
		var zm := maxi(iz - 1, 0) * w
		var zp := mini(iz + 1, h - 1) * w
		var row := iz * w
		for ix in range(w):
			var xm := maxi(ix - 1, 0)
			var xp := mini(ix + 1, w - 1)
			
			var val: float = field[row + ix]
			var norm_h: float = clampf((val - min_h) / h_range, 0.0, 1.0)
			
			# Simple normal estimate for relief shading
			var dx: float = (field[row + xp] - field[row + xm]) * 0.5
			var dz: float = (field[zp + ix] - field[zm + ix]) * 0.5
			var shade: float = clampf(0.5 + 0.5 * (-dx * lx - dz * lz + ly), 0.1, 1.0)
			
			# If node produces mask weights (0..1), tint amber, else earth terrain gradient
			var col: Color
			if node.output_port_type() == Pasture3DGraphNode.PortType.MASK:
				col = Color(0.95 * shade * norm_h, 0.6 * shade * norm_h, 0.1 * shade * norm_h, 1.0)
			else:
				var lum: float = norm_h * shade
				col = Color(lum * 0.85 + 0.1, lum * 0.9 + 0.08, lum * 0.8 + 0.05, 1.0)
				
			img.set_pixel(ix, iz, col)
			
	return ImageTexture.create_from_image(img)
