# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGizmoSprites — the constant-size markers every Pasture3D gizmo draws: a node's own sprite at
# its origin, and the filled/hollow dots used for spline handles.
#
# Shared because there are two gizmo plugins and they had the same problem. brush_gizmo.gd draws the
# brushes; pool_gizmo.gd draws water bodies, which are not brushes and never will be — a pool's loop
# belongs to the brush that carved it. Both need "this node's icon, legible from any distance", and one
# copy of that is the difference between adding a sprite and adding it twice.
#
# Everything here is STATIC. None of it varies per plugin instance, and a gizmo plugin is re-instantiated
# on every @tool script reload, which is often — so the caches outlive the plugins that read them.
@tool
extends RefCounted

# ---- Constant-size sprite markers -----------------------------------------------------------------
#
# The wireframe octahedra were a single pixel thick and vanished into a checkered terrain the moment
# more than a couple of brushes were on screen — and they said nothing about WHICH brush you were
# looking at. The origin marker is now the node's own scene-tree icon and the loop handles are the
# filled/hollow dots a vector drawing program uses, all drawn at a CONSTANT SCREEN SIZE so they read the
# same whether the camera is on the mountain or a kilometre off it.
#
# `fixed_size` on a billboarded StandardMaterial3D is what makes them screen-constant. It is used rather
# than `add_unscaled_billboard`, which is the API for exactly this, because that one draws at the gizmo
# NODE'S ORIGIN and takes no transform — fine for the one origin marker, useless for the fifty loop
# points that are the bigger half of the problem. One mechanism for both beats two.
#
# THESE THREE ARE THE SIZE KNOBS. They are in `fixed_size` units, whose mapping to pixels depends on the
# viewport height and the camera's vertical FOV, so they are tuned by looking rather than derived.

## The brush's scene-tree icon at its origin.
const ICON_SIZE: float = 0.055
## A loop control point.
const POINT_SIZE: float = 0.030
## A bezier tangent handle — smaller than a point, so the point stays the thing you aim at.
const TANGENT_SIZE: float = 0.023
## Where the gizmo sprites live. Carries a `.gdignore`, so Godot's importer never touches them — see
## `sprite_for` for the reimport that made that necessary.
const SPRITE_DIR := "res://addons/pasture_3d/icons/gizmo/"
## Pixel size the 128-unit sprites are rasterised to. Four times the size they are usually drawn at, so
## the mipmap chain has something to work with and a close camera does not find the edge of the raster.
const SPRITE_PX: int = 256

## Resolution of the generated dot textures. 64 is comfortably above the pixel size they are drawn at,
## so the mipmapped edge stays clean when the camera is close enough to make them large.
const DOT_PX: int = 64

## The two dot textures and the unit quad, generated once for the whole editor session. `static` because
## nothing about them varies per plugin instance, and a gizmo plugin is re-instantiated on every @tool
## script reload — which is often.
static var _dot_hollow: ImageTexture
static var _dot_filled: ImageTexture
static var _quad: QuadMesh
## Sprite path -> the rasterised texture, or null when there is no file there. Cached across the whole
## editor session; `static` because a gizmo plugin is re-instantiated on every @tool script reload.
static var _sprite_cache: Dictionary = {}
## Sprite materials by key, one per (texture, tint) pair actually asked for. Interned lazily,
## so a gizmo family declares a colour and nothing else.
static var _materials: Dictionary = {}


## The shared unit quad every sprite is an instance of. Sized 1x1 and scaled by the transform, so the
## three size constants are the only place a size is written down.
static func _quad_mesh() -> QuadMesh:
	if _quad == null:
		_quad = QuadMesh.new()
		_quad.size = Vector2.ONE
	return _quad


## A dot texture: WHITE body with a BLACK rim, on transparent. Filled is a disc, unfilled a ring.
##
## The body is white so the material's albedo can tint it — cyan for a point, orange for a handle — and
## the rim is black so it survives being tinted, which is what keeps the marker readable against pale
## terrain AND against a dark sky. A single-colour dot loses one of those two.
static func _dot_texture(p_filled: bool) -> ImageTexture:
	var img := Image.create_empty(DOT_PX, DOT_PX, true, Image.FORMAT_RGBA8)
	var c := (DOT_PX - 1) * 0.5
	var r_out := DOT_PX * 0.5 - 1.0
	var rim := DOT_PX * 0.10          # black outline thickness
	var r_in := r_out - DOT_PX * 0.30 # inner edge of the ring's white band
	var aa := 1.2                     # antialias width, pixels
	for y in DOT_PX:
		for x in DOT_PX:
			var d := Vector2(x - c, y - c).length()
			var alpha: float
			var white: float
			if p_filled:
				alpha = clampf((r_out - d) / aa, 0.0, 1.0)
				white = clampf((r_out - rim - d) / aa, 0.0, 1.0)
			else:
				alpha = minf(clampf((r_out - d) / aa, 0.0, 1.0),
						clampf((d - (r_in - rim)) / aa, 0.0, 1.0))
				white = minf(clampf((r_out - rim - d) / aa, 0.0, 1.0),
						clampf((d - r_in) / aa, 0.0, 1.0))
			img.set_pixel(x, y, Color(white, white, white, alpha))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _dot(p_filled: bool) -> ImageTexture:
	if p_filled:
		if _dot_filled == null:
			_dot_filled = _dot_texture(true)
		return _dot_filled
	if _dot_hollow == null:
		_dot_hollow = _dot_texture(false)
	return _dot_hollow


## A billboarded, screen-constant, always-on-top material for one texture and tint.
##
## `no_depth_test` mirrors what the wireframes did (`create_material(..., on_top = true)`): a brush sunk
## below the surface stays findable, which on a terrain plugin is the common case rather than the odd one.
static func _sprite_material(p_key: String, p_tex: Texture2D, p_color: Color) -> StandardMaterial3D:
	if _materials.has(p_key):
		return _materials[p_key]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_texture = p_tex
	m.albedo_color = p_color
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	# Without this the billboard code throws the model scale away and every sprite comes out the same
	# size, which would make the three size constants above do nothing at all.
	m.billboard_keep_scale = true
	m.fixed_size = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = true
	m.disable_receive_shadows = true
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	m.render_priority = 10
	_materials[p_key] = m
	return m


## Draw one dot at `p_at` (node-local).
static func _dot_sprite(p_gizmo: EditorNode3DGizmo, p_at: Vector3, p_size: float, p_color: Color,
		p_filled: bool) -> void:
	var key := "%s:%s" % ["filled" if p_filled else "hollow", p_color.to_html(false)]
	p_gizmo.add_mesh(_quad_mesh(), _sprite_material(key, _dot(p_filled), p_color),
			Transform3D(Basis().scaled(Vector3.ONE * p_size), p_at))


## The gizmo sprite for a node: `icons/gizmo/<script file name>.svg`, walking up the script's
## inheritance chain until one exists. No list here and none anywhere else — adding a brush family means
## dropping one file next to the others.
##
## RASTERISED HERE RATHER THAN IMPORTED, and that is the whole point of the directory. The first version
## of this drew the class's scene-tree `@icon` directly, and Godot's "detect 3D" saw a 16x16 editor icon
## used in a 3D material and silently rewrote its import settings to VRAM-compressed with mipmaps — a
## 16px glyph through S3TC, which is exactly the mush that got reported, and it degraded the icon
## everywhere else it appears at the same time. `icons/gizmo/` carries a `.gdignore` so the importer
## never sees these at all; `load_svg_from_string` renders them at whatever size is asked for, and
## nothing can quietly decide otherwise.
static func sprite_for(p_node: Node3D) -> Texture2D:
	var scr: Script = p_node.get_script()
	# Bounded: a script chain is short, and this runs inside a redraw.
	for _step in 16:
		if scr == null or scr.resource_path.is_empty():
			break
		var path := SPRITE_DIR + scr.resource_path.get_file().get_basename() + ".svg"
		if not _sprite_cache.has(path):
			_sprite_cache[path] = _rasterise(path)
		var tex: Texture2D = _sprite_cache[path]
		if tex != null:
			return tex
		scr = scr.get_base_script()
	return null


## One SVG at SPRITE_PX, mipmapped. Null when the file is not there, which is how the chain walk knows
## to keep going.
static func _rasterise(p_path: String) -> Texture2D:
	if not FileAccess.file_exists(p_path):
		return null
	var src := FileAccess.get_file_as_string(p_path)
	if src.is_empty():
		return null
	var img := Image.new()
	# The sprites are authored on a 128 unit canvas; see icons/gizmo/_style.txt.
	if img.load_svg_from_string(src, float(SPRITE_PX) / 128.0) != OK:
		push_warning("Pasture3D: gizmo sprite '%s' could not be rasterised." % p_path)
		return null
	# Without these the marker crawls with aliasing whenever it is smaller than its source, which at a
	# constant screen size is most of the time.
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	# A texture built from an Image has an EMPTY `resource_path`, and the material cache is keyed on the
	# sprite's identity — so without this every brush family would share one cache entry and therefore
	# one texture, and every marker in the scene would draw as whichever sprite was rasterised first.
	# `resource_name` rather than `take_over_path`: this is a label, not a claim on the res:// path.
	tex.resource_name = p_path
	return tex
