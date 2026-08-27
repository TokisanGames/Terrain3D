# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphThumbnailGenerator — utility that renders compact 2D heightmap thumbnail previews
# with hillshade relief shading for GraphNode bodies.
@tool
class_name Pasture3DGraphThumbnailGenerator
extends RefCounted


## Resamples a source grid of dimensions (src_w, src_h) into a destination grid (dst_w, dst_h) using bilinear filtering.
static func resample_grid(p_src: PackedFloat32Array, p_src_w: int, p_src_h: int, p_dst_w: int, p_dst_h: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var n_dst: int = p_dst_w * p_dst_h
	out.resize(n_dst)
	if p_src.is_empty() or p_src_w <= 0 or p_src_h <= 0:
		return out
		
	for iz in range(p_dst_h):
		var src_z: float = (float(iz) / float(maxi(p_dst_h - 1, 1))) * float(p_src_h - 1)
		var z0 := int(floorf(src_z))
		var z1 := mini(z0 + 1, p_src_h - 1)
		var tz := src_z - float(z0)
		var row := iz * p_dst_w
		
		for ix in range(p_dst_w):
			var src_x: float = (float(ix) / float(maxi(p_dst_w - 1, 1))) * float(p_src_w - 1)
			var x0 := int(floorf(src_x))
			var x1 := mini(x0 + 1, p_src_w - 1)
			var tx := src_x - float(x0)
			
			var v00: float = p_src[z0 * p_src_w + x0]
			var v10: float = p_src[z0 * p_src_w + x1]
			var v01: float = p_src[z1 * p_src_w + x0]
			var v11: float = p_src[z1 * p_src_w + x1]
			
			# Replace NaNs if outside brush active perimeter
			if is_nan(v00): v00 = 0.0
			if is_nan(v10): v10 = 0.0
			if is_nan(v01): v01 = 0.0
			if is_nan(v11): v11 = 0.0
			
			var v0: float = lerpf(v00, v10, tx)
			var v1: float = lerpf(v01, v11, tx)
			out[row + ix] = lerpf(v0, v1, tz)
	return out


## Generates a standard representative 3D landscape brush dome/mound surface for previewing Input nodes.
static func generate_sample_brush_input(p_w: int, p_h: int, p_rect: Rect2) -> PackedFloat32Array:
	var n: int = p_w * p_h
	var arr := PackedFloat32Array()
	arr.resize(n)
	var radius: float = minf(p_rect.size.x, p_rect.size.y) * 0.40
	var cx: float = p_rect.position.x + p_rect.size.x * 0.5
	var cz: float = p_rect.position.y + p_rect.size.y * 0.5
	
	for iz in range(p_h):
		var row := iz * p_w
		var wz: float = p_rect.position.y + (float(iz) + 0.5) / float(p_h) * p_rect.size.y
		for ix in range(p_w):
			var wx: float = p_rect.position.x + (float(ix) + 0.5) / float(p_w) * p_rect.size.x
			var dist: float = Vector2(wx - cx, wz - cz).length()
			var t: float = clampf(dist / radius, 0.0, 1.0)
			# Smooth cosine bell curve with height of 25.0 meters
			var h: float = 0.5 * (1.0 + cos(t * PI)) * 25.0 if t < 1.0 else 0.0
			arr[row + ix] = h
	return arr


## Generates an ImageTexture thumbnail for a given node in the graph.
static func generate_thumbnail(p_graph: Pasture3DTerrainGraph, p_node_index: int, p_size: int = 128,
		p_input: PackedFloat32Array = PackedFloat32Array(), p_input_w: int = 0, p_input_h: int = 0,
		p_rect: Rect2 = Rect2(-50.0, -50.0, 100.0, 100.0)) -> ImageTexture:
	if p_graph == null or p_node_index < 0 or p_node_index >= p_graph.nodes.size():
		return null
	var node: Pasture3DGraphNode = p_graph.nodes[p_node_index]
	if node == null:
		return null
		
	var w: int = p_size
	var h: int = p_size
	var n: int = w * h
	var rect := p_rect if p_rect.size.x > 0 and p_rect.size.y > 0 else Rect2(-50.0, -50.0, 100.0, 100.0)
	
	var brush_input: PackedFloat32Array
	if not p_input.is_empty():
		if p_input.size() == n and p_input_w == w and p_input_h == h:
			brush_input = p_input
		elif p_input_w > 0 and p_input_h > 0:
			brush_input = resample_grid(p_input, p_input_w, p_input_h, w, h)
		else:
			brush_input = generate_sample_brush_input(w, h, rect)
	else:
		brush_input = generate_sample_brush_input(w, h, rect)
	
	# Evaluate heightfield
	var field := PackedFloat32Array()
	field.resize(n)
	
	if node.role() == Pasture3DGraphNode.Role.GENERATOR and node.input_count() == 0 and node.op() != &"input" and not node.needs_grid():
		# Pure generator: evaluate directly cell by cell
		for iz in range(h):
			var row := iz * w
			var wz: float = rect.position.y + (float(iz) / float(h)) * rect.size.y
			for ix in range(w):
				var wx: float = rect.position.x + (float(ix) / float(w)) * rect.size.x
				field[row + ix] = node.eval_cell(wx, wz, PackedFloat32Array())
	else:
		# Subgraph rooted at this node with brush input surface supplied
		field = p_graph.evaluate(w, h, rect, null, brush_input, p_node_index)
		
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
	
	# Render 2D image with hillshade relief shading (light from North-West) via byte buffer
	var raw_bytes := PackedByteArray()
	raw_bytes.resize(w * h * 4)
	var ptr := 0
	var is_mask: bool = node.output_port_type() == Pasture3DGraphNode.PortType.MASK
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
			if is_nan(val):
				raw_bytes[ptr] = 20
				raw_bytes[ptr + 1] = 20
				raw_bytes[ptr + 2] = 26
				raw_bytes[ptr + 3] = 128
				ptr += 4
				continue
				
			var norm_h: float = clampf((val - min_h) / h_range, 0.0, 1.0)
			
			# Normal estimate for relief shading
			var vx_p: float = field[row + xp]
			var vx_m: float = field[row + xm]
			var vz_p: float = field[zp + ix]
			var vz_m: float = field[zm + ix]
			if is_nan(vx_p): vx_p = val
			if is_nan(vx_m): vx_m = val
			if is_nan(vz_p): vz_p = val
			if is_nan(vz_m): vz_m = val
			
			var dx: float = (vx_p - vx_m) * 0.5
			var dz: float = (vz_p - vz_m) * 0.5
			var shade: float = clampf(0.5 + 0.5 * (-dx * lx - dz * lz + ly), 0.1, 1.0)
			
			# If node produces mask weights (0..1), tint amber, else earth terrain gradient
			if is_mask:
				raw_bytes[ptr] = int(clampf(0.95 * shade * norm_h * 255.0, 0.0, 255.0))
				raw_bytes[ptr + 1] = int(clampf(0.6 * shade * norm_h * 255.0, 0.0, 255.0))
				raw_bytes[ptr + 2] = int(clampf(0.1 * shade * norm_h * 255.0, 0.0, 255.0))
				raw_bytes[ptr + 3] = 255
			else:
				var lum: float = norm_h * shade
				raw_bytes[ptr] = int(clampf((lum * 0.85 + 0.1) * 255.0, 0.0, 255.0))
				raw_bytes[ptr + 1] = int(clampf((lum * 0.9 + 0.08) * 255.0, 0.0, 255.0))
				raw_bytes[ptr + 2] = int(clampf((lum * 0.8 + 0.05) * 255.0, 0.0, 255.0))
				raw_bytes[ptr + 3] = 255
			ptr += 4
			
	var img := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, raw_bytes)
	return ImageTexture.create_from_image(img)
