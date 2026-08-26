// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <algorithm>

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/geometry2d.hpp>
#include <godot_cpp/classes/time.hpp>

#include "logger.h"
#include "pasture_3d_graph_gpu.h"
#include "pasture_3d_graph_ops.h"
#include "pasture_3d_util.h"

///////////////////////////
// Private Functions
///////////////////////////

/**
 * One lattice vertex of the pool grid, emitted at most once.
 *
 * `p_map` is a flat int32 array over the grid with -1 for "not emitted yet". The GDScript original
 * used a Dictionary keyed on the same flattened index, which is a Variant hash and compare per
 * corner -- four per interior cell, so hundreds of thousands per lake. This is the single change
 * that accounts for most of the speedup.
 */
static int32_t _pool_grid_vert(int32_t *p_map, PackedVector3Array &r_verts, PackedVector2Array &r_uvs,
		const int p_ix, const int p_iz, const double p_min_x, const double p_min_y,
		const double p_spacing, const int p_grid_w) {
	const int key = p_iz * p_grid_w + p_ix;
	if (p_map[key] >= 0) {
		return p_map[key];
	}
	// Narrowed to Vector3/Vector2 at the same point GDScript narrows, so the two agree exactly.
	const double x = p_min_x + (double)p_ix * p_spacing;
	const double z = p_min_y + (double)p_iz * p_spacing;
	const int32_t idx = (int32_t)r_verts.size();
	r_verts.push_back(Vector3((real_t)x, 0.f, (real_t)z));
	r_uvs.push_back(Vector2((real_t)x, (real_t)z));
	p_map[key] = idx;
	return idx;
}

/**
 * The inside mask of a closed loop over a grid, by scanline: 1 where a lattice POINT is inside.
 *
 * Shared by build_pool_mesh (which needs it to walk cells) and build_inside_mask (which hands it to
 * Pasture3DPool so containment queries can be an array lookup instead of a polygon walk). One
 * implementation, so the water a body claims to contain is exactly the water it draws.
 *
 * Not a point-in-polygon test per grid point: that is O(points x edges), tens of millions of
 * operations at lake scale. This is O(rows x edges + points).
 */
static void _pool_inside_mask(const PackedVector2Array &p_poly, const double p_min_x,
		const double p_min_y, const double p_spacing, const int p_gw, const int p_gh,
		uint8_t *r_mask) {
	const int n = p_poly.size();
	const Vector2 *poly = p_poly.ptr();
	memset(r_mask, 0, (size_t)(p_gw * p_gh));

	Vector<float> xs;
	xs.resize(n); // an edge can cross a scanline at most once, so this is the ceiling
	float *xsw = xs.ptrw();
	for (int iz = 0; iz < p_gh; iz++) {
		const double z = p_min_y + (double)iz * p_spacing;
		int count = 0;
		for (int i = 0; i < n; i++) {
			const Vector2 &a = poly[i];
			const Vector2 &b = poly[(i + 1) % n];
			// Half-open crossing test: a vertex exactly on the scanline counts once, so spans never
			// pair up wrongly at a horizontal tangent.
			if (((double)a.y <= z) != ((double)b.y <= z)) {
				xsw[count++] = (float)((double)a.x +
						(z - (double)a.y) / ((double)b.y - (double)a.y) * ((double)b.x - (double)a.x));
			}
		}
		if (count == 0) {
			continue;
		}
		std::sort(xsw, xsw + count);
		const int row = iz * p_gw;
		for (int k = 0; k + 1 < count; k += 2) {
			int i0 = (int)Math::ceil(((double)xsw[k] - p_min_x) / p_spacing);
			int i1 = (int)Math::floor(((double)xsw[k + 1] - p_min_x) / p_spacing);
			i0 = MAX(i0, 0);
			i1 = MIN(i1, p_gw - 1);
			for (int ix = i0; ix <= i1; ix++) {
				r_mask[row + ix] = 1;
			}
		}
	}
}

///////////////////////////
// Public Functions
///////////////////////////

void Pasture3DUtil::print_arr(const String &p_name, const Array &p_arr, const int p_level) {
	LOG(p_level, "Array[", p_arr.size(), "]: ", p_name);
	for (int i = 0; i < p_arr.size(); i++) {
		Variant var = p_arr[i];
		switch (var.get_type()) {
			case Variant::ARRAY: {
				print_arr(p_name + String::num_int64(i), var, p_level);
				break;
			}
			case Variant::DICTIONARY: {
				print_dict(p_name + String::num_int64(i), var, p_level);
				break;
			}
			case Variant::OBJECT: {
				Object *obj = cast_to<Object>(var);
				String str = "Object#" + String::num_uint64(obj->get_instance_id()) + ", " + ptr_to_str(obj);
				LOG(p_level, i, ": ", str);
				break;
			}
			default: {
				LOG(p_level, i, ": ", p_arr[i]);
				break;
			}
		}
	}
}

void Pasture3DUtil::print_dict(const String &p_name, const Dictionary &p_dict, const int p_level) {
	LOG(p_level, "Dictionary: ", p_name);
	Array keys = p_dict.keys();
	for (const StringName &key : keys) {
		Variant var = p_dict[key];
		switch (var.get_type()) {
			case Variant::ARRAY: {
				print_arr(String(key), var, p_level);
				break;
			}
			case Variant::DICTIONARY: {
				print_dict(String(key), var, p_level);
				break;
			}
			case Variant::OBJECT: {
				Object *obj = cast_to<Object>(var);
				String str = "Object#" + String::num_uint64(obj->get_instance_id()) + ", " + ptr_to_str(obj);
				LOG(p_level, "\"", key, "\": ", str);
				break;
			}
			default: {
				LOG(p_level, "\"", key, "\": Value: ", var);
				break;
			}
		}
	}
}

void Pasture3DUtil::dump_gentex(const GeneratedTexture &p_gen, const String &p_name) {
	LOG(MESG, "Generated ", p_name, " RID: ", p_gen.get_rid(), ", dirty: ", p_gen.is_dirty(),
			", image: ", ptr_to_str(*p_gen.get_image()));
}

void Pasture3DUtil::dump_maps(const TypedArray<Image> &p_maps, const String &p_name) {
	LOG(MESG, "Dumping ", p_name, " array. Size: ", p_maps.size());
	for (const Ref<Image> &img : p_maps) {
		LOG(MESG, "Map size: ", img->get_size(), ", format: ", img->get_format(),
				", ", ptr_to_str(*img));
	}
}

// Expects a filename in a String like: "pasture3d-01_02.res" which returns (-1, 2)
// Also accepts the legacy "terrain3d" prefix so pre-rebrand region files still parse.
Vector2i Pasture3DUtil::filename_to_location(const String &p_filename) {
	String location_string = p_filename.trim_prefix("pasture3d").trim_prefix("terrain3d").trim_suffix(".res");
	return string_to_location(location_string);
}

// Expects a string formatted as: "±##±##" which returns (##,##)
Vector2i Pasture3DUtil::string_to_location(const String &p_string) {
	String x_str = p_string.left(3).replace("_", "");
	String y_str = p_string.right(3).replace("_", "");
	if (!x_str.is_valid_int() || !y_str.is_valid_int()) {
		LOG(ERROR, "Malformed string '", p_string, "'. Result: ", x_str, ", ", y_str);
		return V2I_MAX;
	}
	return Vector2i(x_str.to_int(), y_str.to_int());
}

// Expects a v2i(-1,2) and returns pasture3d-01_02.res
String Pasture3DUtil::location_to_filename(const Vector2i &p_region_loc) {
	return "pasture3d" + location_to_string(p_region_loc) + ".res";
}

// Expects a v2i(-1,2) and returns pasture3d_layers-01_02.res (the per-region layer pixel slice)
String Pasture3DUtil::location_to_layer_filename(const Vector2i &p_region_loc) {
	return String(LAYER_FILE_PREFIX) + location_to_string(p_region_loc) + ".res";
}

// Expects a v2i(-1,2) and returns -01_02
String Pasture3DUtil::location_to_string(const Vector2i &p_region_loc) {
	const String POS_REGION_FORMAT = "_%02d";
	const String NEG_REGION_FORMAT = "%03d";
	String x_str, y_str;
	x_str = vformat((p_region_loc.x >= 0) ? POS_REGION_FORMAT : NEG_REGION_FORMAT, p_region_loc.x);
	y_str = vformat((p_region_loc.y >= 0) ? POS_REGION_FORMAT : NEG_REGION_FORMAT, p_region_loc.y);
	return x_str + y_str;
}

PackedStringArray Pasture3DUtil::get_files(const String &p_dir, const String &p_glob) {
	PackedStringArray files;
	Ref<DirAccess> da = DirAccess::open(p_dir);
	if (da.is_null()) {
		LOG(ERROR, "Cannot open directory: ", p_dir);
		return files;
	}
	PackedStringArray dir_files = da->get_files();
	for (const String &file_name : dir_files) {
		String fname = file_name.trim_suffix(".remap");
		if (!fname.matchn(p_glob)) {
			continue;
		}
		LOG(DEBUG, "Found file: ", p_dir + String("/") + fname);
		files.push_back(fname);
	}
	return files;
}

Ref<Image> Pasture3DUtil::black_to_alpha(const Ref<Image> &p_image) {
	if (p_image.is_null()) {
		return Ref<Image>();
	}
	Ref<Image> img = Image::create_empty(p_image->get_width(), p_image->get_height(), false, Image::FORMAT_RGBAF);
	for (int y = 0; y < img->get_height(); y++) {
		for (int x = 0; x < img->get_width(); x++) {
			Color pixel = p_image->get_pixel(x, y);
			pixel.a = pixel.get_luminance();
			img->set_pixel(x, y, pixel);
		}
	}
	if (p_image->has_mipmaps()) {
		img->generate_mipmaps();
	}
	return img;
}

/**
 * Returns the minimum and maximum values for a heightmap (red channel only)
 */
Vector2 Pasture3DUtil::get_min_max(const Ref<Image> &p_image) {
	if (p_image.is_null()) {
		LOG(ERROR, "Provided image is not valid. Nothing to analyze");
		return V2(INFINITY);
	} else if (p_image->is_empty()) {
		LOG(ERROR, "Provided image is empty. Nothing to analyze");
		return V2(INFINITY);
	}

	Vector2 min_max = Vector2(FLT_MAX, -FLT_MAX);

	for (int y = 0; y < p_image->get_height(); y++) {
		for (int x = 0; x < p_image->get_width(); x++) {
			Color col = p_image->get_pixel(x, y);
			if (col.r < min_max.x) {
				min_max.x = col.r;
			}
			if (col.r > min_max.y) {
				min_max.y = col.r;
			}
		}
	}

	LOG(INFO, "Calculating minimum and maximum values of the image: ", min_max);
	return min_max;
}

/**
 * Returns a Image of a float heightmap normalized to RGB8 greyscale and scaled
 * Minimum of 8x8
 */
Ref<Image> Pasture3DUtil::get_thumbnail(const Ref<Image> &p_image, const Vector2i &p_size) {
	if (p_image.is_null()) {
		LOG(ERROR, "Provided image is not valid. Nothing to process");
		return Ref<Image>();
	} else if (p_image->is_empty()) {
		LOG(ERROR, "Provided image is empty. Nothing to process");
		return Ref<Image>();
	}
	Vector2i size = Vector2i(CLAMP(p_size.x, 8, 16384), CLAMP(p_size.y, 8, 16384));

	LOG(INFO, "Drawing a thumbnail sized: ", size);
	// Create a temporary work image scaled to desired width
	Ref<Image> img;
	img.instantiate();
	img->copy_from(p_image);
	img->resize(size.x, size.y, Image::INTERPOLATE_LANCZOS);

	// Get minimum and maximum height values on the scaled image
	Vector2 minmax = get_min_max(img);
	real_t hmin = minmax.x;
	real_t hmax = minmax.y;
	// Define maximum range
	hmin = std::abs(hmin);
	hmax = std::abs(hmax) + hmin;
	// Avoid divide by zero
	hmax = (hmax == 0) ? 0.001f : hmax;

	// Create a new image w / normalized values
	Ref<Image> thumb = Image::create_empty(size.x, size.y, false, Image::FORMAT_RGB8);
	for (int y = 0; y < thumb->get_height(); y++) {
		for (int x = 0; x < thumb->get_width(); x++) {
			Color col = img->get_pixel(x, y);
			col.r = (col.r + hmin) / hmax;
			col.g = col.r;
			col.b = col.r;
			thumb->set_pixel(x, y, col);
		}
	}
	return thumb;
}

/* Get an Image filled with specified color and format
 * If p_color.a < 0, fill with checkered pattern multiplied by p_color.rgb
 *
 * Behavior changes if a compressed format is requested:
 * If the editor is running and format is DXT1/5, BPTC_RGBA, it returns a filled image.
 * Otherwise, it returns a blank image in that format.
 *
 * The reason is the Image compression library is available only in the editor. And it is
 * unreliable, offering little control over the output format, choosing automatically and
 * often wrong. We have selected a few compressed formats it gets right.
 */
Ref<Image> Pasture3DUtil::get_filled_image(const Vector2i &p_size, const Color &p_color,
		const bool p_create_mipmaps, const Image::Format p_format) {
	Image::Format format = p_format;
	if (format < 0 || format >= Image::FORMAT_MAX) {
		format = Image::FORMAT_DXT5;
	}

	Image::CompressMode compression_format = Image::COMPRESS_MAX;
	Image::UsedChannels channels = Image::USED_CHANNELS_RGBA;
	bool compress = false;
	bool fill_image = true;

	if (format >= Image::Format::FORMAT_DXT1) {
		switch (format) {
			case Image::FORMAT_DXT1:
				format = Image::FORMAT_RGB8;
				channels = Image::USED_CHANNELS_RGB;
				compression_format = Image::COMPRESS_S3TC;
				compress = true;
				break;
			case Image::FORMAT_DXT5:
				format = Image::FORMAT_RGBA8;
				channels = Image::USED_CHANNELS_RGBA;
				compression_format = Image::COMPRESS_S3TC;
				compress = true;
				break;
			case Image::FORMAT_BPTC_RGBA:
				format = Image::FORMAT_RGBA8;
				channels = Image::USED_CHANNELS_RGBA;
				compression_format = Image::COMPRESS_BPTC;
				compress = true;
				break;
			default:
				compress = false;
				fill_image = false;
				break;
		}
	}

	Ref<Image> img = Image::create_empty(p_size.x, p_size.y, p_create_mipmaps, format);

	Color color = p_color;
	if (fill_image) {
		if (color.a < 0.0f) {
			color.a = 1.0f;
			Color col_a = Color(0.8f, 0.8f, 0.8f, 1.0) * color;
			Color col_b = Color(0.5f, 0.5f, 0.5f, 1.0) * color;
			img->fill_rect(Rect2i(V2I_ZERO, p_size / 2), col_a);
			img->fill_rect(Rect2i(p_size / 2, p_size / 2), col_a);
			img->fill_rect(Rect2i(Vector2(p_size.x, 0) / 2, p_size / 2), col_b);
			img->fill_rect(Rect2i(Vector2(0, p_size.y) / 2, p_size / 2), col_b);
		} else {
			img->fill(color);
		}
		if (p_create_mipmaps) {
			img->generate_mipmaps();
		}
	}
	if (compress && IS_EDITOR) {
		img->compress_from_channels(compression_format, channels);
	}
	return img;
}

/**
 * Loads a file from disk and returns an Image
 * Parameters:
 *	p_filename - file on disk to load. EXR, R16/RAW, PNG, or a ResourceLoader format (jpg, res, tres, etc)
 *	p_cache_mode - Send this flag to the resource loader to force caching or not
 *	p_height_range - R16 format: x=Min & y=Max value ranges. Required for R16 import
 *	p_size - R16 format: Image dimensions. Default (0,0) auto detects f/ square images. Required f/ non-square R16
 */
Ref<Image> Pasture3DUtil::load_image(const String &p_file_name, const int p_cache_mode, const Vector2 &p_r16_height_range, const Vector2i &p_r16_size) {
	if (p_file_name.is_empty()) {
		LOG(ERROR, "No file specified. Nothing imported");
		return Ref<Image>();
	}
	if (!FileAccess::file_exists(p_file_name)) {
		LOG(ERROR, "File ", p_file_name, " does not exist. Nothing to import");
		return Ref<Image>();
	}

	// Load file based on extension
	Ref<Image> img;
	LOG(INFO, "Attempting to load: ", p_file_name);
	String ext = p_file_name.get_extension().to_lower();
	PackedStringArray imgloader_extensions = PackedStringArray(Array::make("bmp", "dds", "exr", "hdr", "jpg", "jpeg", "png", "tga", "svg", "webp"));

	// If R16 integer format (read/writeable by Krita)
	if (ext == "r16" || ext == "raw") {
		LOG(DEBUG, "Loading file as an r16");
		Ref<FileAccess> file = FileAccess::open(p_file_name, FileAccess::READ);
		// If p_size is zero, assume square and try to auto detect size
		Vector2i r16_size = p_r16_size;
		if (r16_size <= V2I_ZERO) {
			file->seek_end();
			int fsize = file->get_position();
			int fwidth = sqrt(fsize / 2);
			r16_size = V2I(fwidth);
			LOG(DEBUG, "Total file size is: ", fsize, " calculated width: ", fwidth, " dimensions: ", r16_size);
			file->seek(0);
		}
		img = Image::create_empty(r16_size.x, r16_size.y, false, FORMAT[TYPE_HEIGHT]);
		for (int y = 0; y < r16_size.y; y++) {
			for (int x = 0; x < r16_size.x; x++) {
				real_t h = real_t(file->get_16()) / 65535.0f;
				h = h * (p_r16_height_range.y - p_r16_height_range.x) + p_r16_height_range.x;
				img->set_pixel(x, y, Color(h, 0.f, 0.f));
			}
		}

		// If an Image extension, use Image loader
	} else if (imgloader_extensions.has(ext)) {
		LOG(DEBUG, "ImageFormatLoader loading recognized file type: ", ext);
		img = Image::load_from_file(p_file_name);

		// Else, see if Godot's resource loader will read it as an image: RES, TRES, etc
	} else {
		LOG(DEBUG, "Loading file as a resource");
		img = ResourceLoader::get_singleton()->load(p_file_name, "", static_cast<ResourceLoader::CacheMode>(p_cache_mode));
	}

	if (!img.is_valid()) {
		LOG(ERROR, "File", p_file_name, " cannot be loaded");
		return Ref<Image>();
	}
	if (img->is_empty()) {
		LOG(ERROR, "File", p_file_name, " is empty");
		return Ref<Image>();
	}
	LOG(DEBUG, "Loaded Image size: ", img->get_size(), " format: ", img->get_format());
	return img;
}

/* From source RGB and selected source for Alpha channel, create a new RGBA image.
 * If p_invert_green is true, the destination green channel will be 1.0 - input green channel.
 * If p_invert_alpha is true, the destination alpha channel will be 1.0 - input source channel.
 */
Ref<Image> Pasture3DUtil::pack_image(const Ref<Image> &p_src_rgb, const Ref<Image> &p_src_a, const Ref<Image> &p_src_ao,
		const bool p_invert_green, const bool p_invert_alpha, const bool p_normalize_alpha, const int p_alpha_channel, const int p_ao_channel) {
	if (!p_src_rgb.is_valid() || !p_src_a.is_valid()) {
		LOG(ERROR, "Provided images are not valid. Cannot pack");
		return Ref<Image>();
	}
	if (p_src_rgb->get_size() != p_src_a->get_size()) {
		LOG(ERROR, "Provided images are not the same size. Cannot pack");
		return Ref<Image>();
	}
	if (p_src_rgb->is_empty() || p_src_a->is_empty()) {
		LOG(ERROR, "Provided images are empty. Cannot pack");
		return Ref<Image>();
	}
	if (p_alpha_channel < 0 || p_alpha_channel > 3) {
		LOG(ERROR, "Source Channel of Height/Roughness invalid. Cannot Pack");
		return Ref<Image>();
	}

	bool pack_ao = p_src_ao.is_valid();
	if (pack_ao) {
		if (p_src_rgb->get_size() != p_src_ao->get_size()) {
			LOG(ERROR, "Provided AO and normal images are not the same size. Cannot pack");
			return Ref<Image>();
		}
	}

	real_t a_max = 0.0f;
	real_t a_min = 0.0f;
	real_t contrast = 1.0f;
	if (p_normalize_alpha) {
		a_min = 1.0f;
		// Calculate contrast and offset so that we can make full use of the height channel range.
		for (int y = 0; y < p_src_rgb->get_height(); y++) {
			for (int x = 0; x < p_src_rgb->get_width(); x++) {
				real_t h = p_src_a->get_pixel(x, y)[p_alpha_channel];
				a_max = MAX(h, a_max);
				a_min = MIN(h, a_min);
			}
		}
		contrast /= MAX(a_max - a_min, 1e-6f);
	}

	Ref<Image> dst = Image::create_empty(p_src_rgb->get_width(), p_src_rgb->get_height(), false, Image::FORMAT_RGBA8);
	LOG(INFO, "Creating image from source RGB + source channel images");
	for (int y = 0; y < p_src_rgb->get_height(); y++) {
		for (int x = 0; x < p_src_rgb->get_width(); x++) {
			Color col = p_src_rgb->get_pixel(x, y);
			col.a = p_src_a->get_pixel(x, y)[p_alpha_channel];
			if (p_normalize_alpha) {
				col.a = CLAMP((col.a * contrast - a_min), 0.0f, 1.0f);
			}
			if (p_invert_green) {
				col.g = 1.0f - col.g;
			}
			if (p_invert_alpha) {
				col.a = 1.0f - col.a;
			}
			if (pack_ao) {
				// Compress range to avoid low AO values completely destroying normal vector precision - recovered in shader.
				real_t ao = sqrt(p_src_ao->get_pixel(x, y)[p_ao_channel]) * 0.5 + 0.5;
				col.r = col.r * ao + (1.0f - ao) * 0.5f;
				col.g = col.g * ao + (1.0f - ao) * 0.5f;
				col.b = col.b * ao + (1.0f - ao) * 0.5f;
			}
			dst->set_pixel(x, y, col);
		}
	}
	return dst;
}

// From source RGB, create a new L image that is scaled to use full 0 - 1 range.
Ref<Image> Pasture3DUtil::luminance_to_height(const Ref<Image> &p_src_rgb) {
	if (!p_src_rgb.is_valid()) {
		LOG(ERROR, "Provided images are not valid. Cannot pack");
		return Ref<Image>();
	}
	if (p_src_rgb->is_empty()) {
		LOG(ERROR, "Provided images are empty. Cannot pack");
		return Ref<Image>();
	}
	real_t lum_contrast;
	real_t l_max = 0.0f;
	real_t l_min = 1.0f;
	// Calculate contrast and offset so that we can make the most use of the height channel range.
	for (int y = 0; y < p_src_rgb->get_height(); y++) {
		for (int x = 0; x < p_src_rgb->get_width(); x++) {
			Color col = p_src_rgb->get_pixel(x, y);
			real_t l = 0.299f * col.r + 0.587f * col.g + 0.114f * col.b;
			l_max = MAX(l, l_max);
			l_min = MIN(l, l_min);
		}
	}
	lum_contrast = 1.0f / MAX(l_max - l_min, 1e-6);
	Ref<Image> dst = Image::create_empty(p_src_rgb->get_width(), p_src_rgb->get_height(), false, Image::FORMAT_RGB8);
	for (int y = 0; y < p_src_rgb->get_height(); y++) {
		for (int x = 0; x < p_src_rgb->get_width(); x++) {
			Color col = p_src_rgb->get_pixel(x, y);
			real_t lum = 0.299f * col.r + 0.587f * col.g + 0.114f * col.b;
			lum = CLAMP((lum * lum_contrast - l_min), 0.0f, 1.0f);
			// some shaping
			col.r = 0.5f - sin(asin(1.0f - 2.0f * lum) / 3.0f);
			col.g = col.r;
			col.b = col.r;
			col.a = col.r;
			dst->set_pixel(x, y, col);
		}
	}
	return dst;
}

void Pasture3DUtil::benchmark(Pasture3D *p_terrain) {
	if (!p_terrain) {
		return;
	}
	const Pasture3DData *data = p_terrain->get_data();
	if (!data) {
		return;
	}
	uint64_t start_time;
	Vector3 vec;
	Color col;
	for (int i = 0; i < 3; i++) {
		start_time = Time::get_singleton()->get_ticks_msec();
		for (int j = 0; j < 10000000; j++) {
			col = data->get_pixel(TYPE_HEIGHT, vec);
		}
		LOG(MESG, "get_pixel() 10M: ", Time::get_singleton()->get_ticks_msec() - start_time, "ms");
	}

	vec = Vector3(0.5f, 0.f, 0.5f);
	for (int i = 0; i < 3; i++) {
		start_time = Time::get_singleton()->get_ticks_msec();
		for (int j = 0; j < 1000000; j++) {
			data->get_height(vec);
		}
		LOG(MESG, "get_height() 1M interpolated: ", Time::get_singleton()->get_ticks_msec() - start_time, "ms");
	}

	for (int i = 0; i < 2; i++) {
		start_time = Time::get_singleton()->get_ticks_msec();
		p_terrain->bake_mesh(0);
		LOG(MESG, "Bake ArrayMesh: ", Time::get_singleton()->get_ticks_msec() - start_time, "ms");
	}
}

/**
 * The water-body surface mesh. See the header for why this lives here and not on the node.
 *
 * A line-by-line port of Pasture3DPool's GDScript rebuild loop, which stays in the file as the A/B
 * oracle. It is a port and not a rewrite on purpose: the two have to be comparable on identical
 * inputs, so the scanline's half-open crossing rule, the cell walk order, the winding, and the
 * boundary clip all match the original exactly.
 *
 * WHY IT IS FASTER, since "it is C++" is not a reason on its own:
 *
 *   1. The shared-vertex map. GDScript used a Dictionary keyed on the flattened grid index, so every
 *      one of the four corners of every interior cell cost a Variant hash and a Variant compare --
 *      roughly 640k hashed lookups for a 500 m lake. Here it is a flat int32 array indexed directly,
 *      with -1 meaning "not emitted yet".
 *   2. No Variant boxing in the inner loop. Every append to a Packed*Array from GDScript crosses the
 *      Variant boundary; here the arrays are sized once and written through raw pointers.
 *
 * PRECISION, deliberately matched rather than improved: GDScript promotes float operands to double
 * and narrows only when storing into a Packed*Array or a Vector2/3. The intermediates below use
 * double at exactly the same points and narrow at exactly the same points, so the two
 * implementations agree bit-for-bit on which cells are inside. Computing this "better" in float
 * would flip boundary cells and make the A/B comparison report differences that are not bugs.
 */
Ref<ArrayMesh> Pasture3DUtil::build_pool_mesh(const PackedVector2Array &p_poly, const Vector2 &p_min,
		const real_t p_spacing, const int p_grid_w, const int p_grid_h) {
	Ref<ArrayMesh> mesh;
	const int n = p_poly.size();
	if (n < 3 || p_grid_w < 2 || p_grid_h < 2 || p_spacing <= 0.0f) {
		return mesh;
	}
	const int cells = p_grid_w * p_grid_h;
	const Vector2 *poly = p_poly.ptr();
	const double min_x = (double)p_min.x;
	const double min_y = (double)p_min.y;
	const double spacing = (double)p_spacing;

	// --- Inside mask, by scanline -------------------------------------------------
	Vector<uint8_t> mask;
	mask.resize(cells);
	uint8_t *maskw = mask.ptrw();
	_pool_inside_mask(p_poly, min_x, min_y, spacing, p_grid_w, p_grid_h, maskw);

	// --- Cell walk ------------------------------------------------------------------
	// Interior lattice points are shared between the up-to-four cells that touch them; boundary
	// triangles get their own vertices because they do not land on the lattice.
	Vector<int32_t> vert_of;
	vert_of.resize(cells);
	int32_t *vmap = vert_of.ptrw();
	for (int i = 0; i < cells; i++) {
		vmap[i] = -1;
	}

	PackedVector3Array verts;
	PackedVector2Array uvs;
	PackedInt32Array indices;

	Geometry2D *geom = Geometry2D::get_singleton();

	for (int iz = 0; iz < p_grid_h - 1; iz++) {
		for (int ix = 0; ix < p_grid_w - 1; ix++) {
			const uint8_t c00 = maskw[iz * p_grid_w + ix];
			const uint8_t c10 = maskw[iz * p_grid_w + ix + 1];
			const uint8_t c01 = maskw[(iz + 1) * p_grid_w + ix];
			const uint8_t c11 = maskw[(iz + 1) * p_grid_w + ix + 1];
			const int n_in = (int)c00 + (int)c10 + (int)c01 + (int)c11;
			if (n_in == 0) {
				continue;
			}
			if (n_in == 4) {
				const int32_t a = _pool_grid_vert(vmap, verts, uvs, ix, iz, min_x, min_y, spacing, p_grid_w);
				const int32_t b = _pool_grid_vert(vmap, verts, uvs, ix + 1, iz, min_x, min_y, spacing, p_grid_w);
				const int32_t c = _pool_grid_vert(vmap, verts, uvs, ix, iz + 1, min_x, min_y, spacing, p_grid_w);
				const int32_t d = _pool_grid_vert(vmap, verts, uvs, ix + 1, iz + 1, min_x, min_y, spacing, p_grid_w);
				// CCW seen from above (+Y up, -Z forward).
				indices.push_back(a);
				indices.push_back(c);
				indices.push_back(b);
				indices.push_back(b);
				indices.push_back(c);
				indices.push_back(d);
				continue;
			}
			// Partial cell: clip the square against the loop and fan the remainder. Only about
			// perimeter/spacing cells reach here, so the expensive path is bounded by the shore
			// length rather than by the area -- which is why this stays exact rather than snapping.
			const double x0 = min_x + (double)ix * spacing;
			const double z0 = min_y + (double)iz * spacing;
			PackedVector2Array cell;
			cell.resize(4);
			{
				Vector2 *cw = cell.ptrw();
				cw[0] = Vector2((real_t)x0, (real_t)z0);
				cw[1] = Vector2((real_t)(x0 + spacing), (real_t)z0);
				cw[2] = Vector2((real_t)(x0 + spacing), (real_t)(z0 + spacing));
				cw[3] = Vector2((real_t)x0, (real_t)(z0 + spacing));
			}
			const TypedArray<PackedVector2Array> pieces = geom->intersect_polygons(cell, p_poly);
			for (int pi = 0; pi < pieces.size(); pi++) {
				const PackedVector2Array piece = pieces[pi];
				if (piece.size() < 3) {
					continue;
				}
				const PackedInt32Array tri = geom->triangulate_polygon(piece);
				const int32_t *trir = tri.ptr();
				const Vector2 *piecer = piece.ptr();
				for (int i = 0; i + 2 < tri.size(); i += 3) {
					for (int j = 0; j < 3; j++) {
						const Vector2 &p = piecer[trir[i + j]];
						indices.push_back(verts.size());
						verts.push_back(Vector3(p.x, 0.f, p.y));
						uvs.push_back(p);
					}
				}
			}
		}
	}

	if (verts.is_empty() || indices.is_empty()) {
		return mesh;
	}

	PackedVector3Array normals;
	normals.resize(verts.size());
	{
		Vector3 *nw = normals.ptrw();
		for (int i = 0; i < normals.size(); i++) {
			nw[i] = Vector3(0.f, 1.f, 0.f);
		}
	}

	// Neutral flow (spec §10). A loop pool does not flow, but it must still SAY so: the river
	// shader decodes ARRAY_COLOR.rg as a direction remapped from [-1,1], and a mesh with no colours
	// reads white, which decodes to a diagonal at full speed. (0.5, 0.5, 0) is the zero vector.
	// The GDScript mesher writes the same thing, and Phase 3's parity criterion compares them.
	PackedColorArray colours;
	colours.resize(verts.size());
	{
		Color *cw = colours.ptrw();
		for (int i = 0; i < colours.size(); i++) {
			cw[i] = Color(0.5f, 0.5f, 0.f, 1.f);
		}
	}

	Array arrays;
	arrays.resize(Mesh::ARRAY_MAX);
	arrays[Mesh::ARRAY_VERTEX] = verts;
	arrays[Mesh::ARRAY_NORMAL] = normals;
	arrays[Mesh::ARRAY_TEX_UV] = uvs;
	arrays[Mesh::ARRAY_COLOR] = colours;
	arrays[Mesh::ARRAY_INDEX] = indices;
	mesh.instantiate();
	mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
	return mesh;
}

/**
 * The same inside mask build_pool_mesh walks, handed out so containment can be O(1).
 *
 * Pasture3DPool asks a containment question per buoy per physics tick, and the honest version of
 * that -- Geometry2D.is_point_in_polygon -- is O(perimeter). A 600 m lake decimates to a few hundred
 * polygon points, so 64 buoys was tens of thousands of edge tests every tick, and it dominated the
 * buoy budget by more than the wave solve did (§11.10).
 *
 * With this, a query is a bounds check and an array lookup. The pool falls back to the exact polygon
 * test only for the cells the boundary actually crosses, which is O(shore length) worth of the grid.
 * Using the MESHER'S mask rather than a second structure also means the water a body claims to
 * contain is exactly the water it draws.
 */
PackedByteArray Pasture3DUtil::build_inside_mask(const PackedVector2Array &p_poly,
		const Vector2 &p_min, const real_t p_spacing, const int p_grid_w, const int p_grid_h) {
	PackedByteArray mask;
	if (p_poly.size() < 3 || p_grid_w < 1 || p_grid_h < 1 || p_spacing <= 0.f) {
		return mask;
	}
	mask.resize(p_grid_w * p_grid_h);
	_pool_inside_mask(p_poly, (double)p_min.x, (double)p_min.y, (double)p_spacing,
			p_grid_w, p_grid_h, mask.ptrw());
	return mask;
}

/**
 * Squared distance from a point to a segment. Doubles throughout: the caller compares these
 * against a search radius to decide whether it may stop early, and a float there can stop one
 * ring too soon on a near-tie.
 */
static inline double _dist_sq_point_seg(const double p_px, const double p_pz,
		const double p_ax, const double p_az, const double p_bx, const double p_bz) {
	const double dx = p_bx - p_ax;
	const double dz = p_bz - p_az;
	const double len2 = dx * dx + dz * dz;
	double t = 0.0;
	if (len2 > 0.0) {
		t = ((p_px - p_ax) * dx + (p_pz - p_az) * dz) / len2;
		t = CLAMP(t, 0.0, 1.0);
	}
	const double qx = p_ax + t * dx - p_px;
	const double qz = p_az + t * dz - p_pz;
	return qx * qx + qz * qz;
}

/**
 * IEEE 754 binary32 -> binary16, round-to-nearest, clamped to the largest finite half.
 *
 * Hand-rolled because godot-cpp exposes Image::FORMAT_RH but no float-to-half helper, and the shore
 * field wants a 16-bit FILTERABLE format: bilinear interpolation of the stored value is the whole
 * mechanism, so packing 16 bits across two 8-bit channels is not an option -- the hardware would
 * interpolate each byte separately and the low byte would wrap.
 */
static inline uint16_t _float_to_half(const float p_value) {
	union {
		float f;
		uint32_t u;
	} v;
	v.f = p_value;
	const uint32_t sign = (v.u >> 16) & 0x8000u;
	const int32_t exp = (int32_t)((v.u >> 23) & 0xFFu) - 127 + 15;
	uint32_t mant = v.u & 0x7FFFFFu;
	if (exp <= 0) {
		// Subnormal half, or too small to represent at all. The shore field lives in [0,1], so
		// this branch is reached routinely -- it is not an edge case here.
		if (exp < -10) {
			return (uint16_t)sign;
		}
		mant |= 0x800000u; // restore the implicit leading 1 before shifting it down
		const uint32_t shift = (uint32_t)(14 - exp);
		uint32_t half_mant = mant >> shift;
		if ((mant >> (shift - 1)) & 1u) {
			half_mant++; // round to nearest
		}
		return (uint16_t)(sign | half_mant);
	}
	if (exp >= 31) {
		return (uint16_t)(sign | 0x7BFFu); // clamp rather than emit an infinity
	}
	uint16_t out = (uint16_t)(sign | ((uint32_t)exp << 10) | (mant >> 13));
	if ((mant >> 12) & 1u) {
		out++;
	}
	return out;
}

/**
 * The shore mask's signed distance field. Negative inside the water.
 *
 * WHY THIS EXISTS. A body meshed at wave resolution does not scale: a 1.4 km lake at lake_calm's
 * automatic 1.27 m spacing wants over a million vertices and build_pool_mesh refuses it. Cutting an
 * unaware sheet with a field instead makes the drawn vertex count a property of the CLIPMAP rather
 * than of the lake, and the measured rim is as good as the meshed one -- 0.164 m from the true
 * outline against the 2 m edge_offset that buries it in the bank (bench/WaterShoreEdgeProbe.gd).
 *
 * BANDED, in two tiers, because the two halves of the field are read by different things:
 *
 *   - Within p_exact_band texels of the boundary, the real distance to the polygon. This is the
 *     band the fragment stage's alpha ramp reads, so it is the band that IS the waterline, and
 *     sub-texel accuracy here is the entire product. Measured: a bake with this band removed --
 *     pure chamfer over a binary mask -- puts the waterline 0.476 m out, which is within noise of
 *     not feathering at all, because both lose the same sub-texel information.
 *
 *   - Everywhere else, a two-pass chamfer sweep seeded from that band. Its only consumer is the
 *     vertex kill comparing against a threshold metres away from anything it decides, and a few
 *     percent of error at 10 m out changes no pixel. O(texels) with no segments in the loop.
 *
 * LINEAR ENCODING, in R16F by default. The obvious saving here is to store
 * sign(d) * sqrt(|d| / range) in a single byte, spending the precision near the shore where the
 * alpha ramp reads it instead of spreading it over a range only the vertex kill cares about. That
 * was tried and it measured nearly twice as bad as linear, in a float format as well as a byte, so
 * it is not a quantisation effect: the sampler interpolates the STORED value, and squaring
 * afterwards is not the same as interpolating the distance. Linear interpolation of a distance field
 * being a good approximation of distance is the whole reason an SDF texture works at all.
 *
 * So the precision comes from the format instead. R16F resolves better than a millimetre near the
 * shore at any usable range, at 1.8 MB for a 1.4 km lake against 17 MB of the vertices it replaces.
 * R8 halves that again and lands at 0.249 m against a 0.25 m budget, which makes it the cheap
 * option rather than the default. Both encodings stay reachable because the sqrt one is now a
 * control that must fail.
 */
Ref<Image> Pasture3DUtil::build_shore_sdf(const PackedVector2Array &p_poly, const Vector2 &p_min,
		const real_t p_texel, const int p_texels, const real_t p_range,
		const int p_exact_band, const bool p_half_float, const bool p_sqrt_encoding) {
	Ref<Image> img;
	if (p_poly.size() < 3 || p_texels < 2 || p_texel <= 0.f || p_range <= 0.f) {
		return img;
	}
	const int n = p_texels;
	const int seg_count = p_poly.size();
	const Vector2 *poly = p_poly.ptr();
	const double texel = (double)p_texel;
	// Texel CENTRES, so a sample at UV (i + 0.5) / n reads the value baked for that texel. Off by
	// half a texel here and the whole field is biased by 0.75 m at the shipping resolution.
	const double ox = (double)p_min.x + texel * 0.5;
	const double oz = (double)p_min.y + texel * 0.5;

	PackedByteArray inside;
	inside.resize(n * n);
	_pool_inside_mask(p_poly, ox, oz, texel, n, n, inside.ptrw());
	const uint8_t *ins = inside.ptr();

	Vector<float> dist;
	dist.resize(n * n);
	float *d = dist.ptrw();
	const float far = (float)(p_range * 4.0); // any value the chamfer will beat
	for (int i = 0; i < n * n; i++) {
		d[i] = far;
	}

	// --- a CSR grid index over the segments -----------------------------------
	// Without it a band texel tests every segment, and a kilometre-scale outline decimates to
	// hundreds of them. With it a texel tests a handful.
	const double cell = MAX(texel * 8.0, 8.0);
	double bx0 = (double)poly[0].x, bz0 = (double)poly[0].y;
	double bx1 = bx0, bz1 = bz0;
	for (int i = 0; i < seg_count; i++) {
		bx0 = MIN(bx0, (double)poly[i].x);
		bz0 = MIN(bz0, (double)poly[i].y);
		bx1 = MAX(bx1, (double)poly[i].x);
		bz1 = MAX(bz1, (double)poly[i].y);
	}
	const int cgx = MAX((int)Math::floor((bx1 - bx0) / cell) + 1, 1);
	const int cgz = MAX((int)Math::floor((bz1 - bz0) / cell) + 1, 1);
	Vector<int32_t> cell_start;
	cell_start.resize(cgx * cgz + 1);
	int32_t *starts = cell_start.ptrw();
	memset(starts, 0, sizeof(int32_t) * (size_t)(cgx * cgz + 1));
	// Pass 1: count. A segment lands in every cell its bounding box touches, which over-counts a
	// diagonal but never misses -- and missing is the only error that would matter.
	for (int i = 0; i < seg_count; i++) {
		const Vector2 &a = poly[i];
		const Vector2 &b = poly[(i + 1) % seg_count];
		const int x0 = CLAMP((int)Math::floor((MIN((double)a.x, (double)b.x) - bx0) / cell), 0, cgx - 1);
		const int x1 = CLAMP((int)Math::floor((MAX((double)a.x, (double)b.x) - bx0) / cell), 0, cgx - 1);
		const int z0 = CLAMP((int)Math::floor((MIN((double)a.y, (double)b.y) - bz0) / cell), 0, cgz - 1);
		const int z1 = CLAMP((int)Math::floor((MAX((double)a.y, (double)b.y) - bz0) / cell), 0, cgz - 1);
		for (int cz = z0; cz <= z1; cz++) {
			for (int cx = x0; cx <= x1; cx++) {
				starts[cz * cgx + cx + 1]++;
			}
		}
	}
	for (int i = 0; i < cgx * cgz; i++) {
		starts[i + 1] += starts[i];
	}
	Vector<int32_t> cell_items;
	cell_items.resize(starts[cgx * cgz]);
	int32_t *items = cell_items.ptrw();
	Vector<int32_t> cursor = cell_start;
	int32_t *cur = cursor.ptrw();
	for (int i = 0; i < seg_count; i++) {
		const Vector2 &a = poly[i];
		const Vector2 &b = poly[(i + 1) % seg_count];
		const int x0 = CLAMP((int)Math::floor((MIN((double)a.x, (double)b.x) - bx0) / cell), 0, cgx - 1);
		const int x1 = CLAMP((int)Math::floor((MAX((double)a.x, (double)b.x) - bx0) / cell), 0, cgx - 1);
		const int z0 = CLAMP((int)Math::floor((MIN((double)a.y, (double)b.y) - bz0) / cell), 0, cgz - 1);
		const int z1 = CLAMP((int)Math::floor((MAX((double)a.y, (double)b.y) - bz0) / cell), 0, cgz - 1);
		for (int cz = z0; cz <= z1; cz++) {
			for (int cx = x0; cx <= x1; cx++) {
				items[cur[cz * cgx + cx]++] = i;
			}
		}
	}

	// --- exact distance in the band -------------------------------------------
	const int band = MAX(p_exact_band, 0);
	for (int iz = 0; iz < n; iz++) {
		for (int ix = 0; ix < n; ix++) {
			const uint8_t here = ins[iz * n + ix];
			const bool edge = (ix + 1 < n && ins[iz * n + ix + 1] != here) ||
					(iz + 1 < n && ins[(iz + 1) * n + ix] != here);
			if (!edge) {
				continue;
			}
			const int z_lo = MAX(iz - band, 0), z_hi = MIN(iz + band, n - 1);
			const int x_lo = MAX(ix - band, 0), x_hi = MIN(ix + band, n - 1);
			for (int bz = z_lo; bz <= z_hi; bz++) {
				for (int bxi = x_lo; bxi <= x_hi; bxi++) {
					const int at = bz * n + bxi;
					if (d[at] < far) {
						continue; // already exact from a neighbouring boundary texel
					}
					const double px = ox + (double)bxi * texel;
					const double pz = oz + (double)bz * texel;
					// Ring search. A k-ring around the point's own cell contains everything
					// closer than k * cell -- the point sits inside its cell, so the nearest
					// unexamined ground is at least k cells away on every side -- so stopping at
					// that bound is exact rather than an approximation.
					const int pcx = CLAMP((int)Math::floor((px - bx0) / cell), 0, cgx - 1);
					const int pcz = CLAMP((int)Math::floor((pz - bz0) / cell), 0, cgz - 1);
					double best = 1e30;
					const int k_max = MAX(cgx, cgz);
					for (int k = 1; k <= k_max; k++) {
						for (int cz = pcz - k; cz <= pcz + k; cz++) {
							if (cz < 0 || cz >= cgz) {
								continue;
							}
							for (int cx = pcx - k; cx <= pcx + k; cx++) {
								if (cx < 0 || cx >= cgx) {
									continue;
								}
								// Only the ring this k added; the interior was covered already.
								if (k > 1 && ABS(cx - pcx) < k && ABS(cz - pcz) < k) {
									continue;
								}
								const int c = cz * cgx + cx;
								for (int s = starts[c]; s < starts[c + 1]; s++) {
									const int si = items[s];
									const Vector2 &a = poly[si];
									const Vector2 &b = poly[(si + 1) % seg_count];
									const double dd = _dist_sq_point_seg(px, pz,
											(double)a.x, (double)a.y, (double)b.x, (double)b.y);
									best = MIN(best, dd);
								}
							}
						}
						const double covered = (double)k * cell;
						if (best <= covered * covered) {
							break;
						}
					}
					d[at] = (float)Math::sqrt(best);
				}
			}
		}
	}

	// --- chamfer the rest -----------------------------------------------------
	const float d_ortho = (float)texel;
	const float d_diag = (float)(texel * Math_SQRT2);
	for (int iz = 0; iz < n; iz++) {
		for (int ix = 0; ix < n; ix++) {
			const int i = iz * n + ix;
			float v = d[i];
			if (iz > 0) {
				v = MIN(v, d[i - n] + d_ortho);
				if (ix > 0) {
					v = MIN(v, d[i - n - 1] + d_diag);
				}
				if (ix + 1 < n) {
					v = MIN(v, d[i - n + 1] + d_diag);
				}
			}
			if (ix > 0) {
				v = MIN(v, d[i - 1] + d_ortho);
			}
			d[i] = v;
		}
	}
	for (int iz = n - 1; iz >= 0; iz--) {
		for (int ix = n - 1; ix >= 0; ix--) {
			const int i = iz * n + ix;
			float v = d[i];
			if (iz + 1 < n) {
				v = MIN(v, d[i + n] + d_ortho);
				if (ix > 0) {
					v = MIN(v, d[i + n - 1] + d_diag);
				}
				if (ix + 1 < n) {
					v = MIN(v, d[i + n + 1] + d_diag);
				}
			}
			if (ix + 1 < n) {
				v = MIN(v, d[i + 1] + d_ortho);
			}
			d[i] = v;
		}
	}

	// --- encode ---------------------------------------------------------------
	// Straight into a byte buffer rather than per-texel set_pixel, which in the GDScript oracle
	// was 106 ms of a 738 ms bake on its own.
	const int stride = p_half_float ? 2 : 1;
	PackedByteArray data;
	data.resize(n * n * stride);
	uint8_t *out = data.ptrw();
	const double range = (double)p_range;
	for (int i = 0; i < n * n; i++) {
		const double sd = (double)d[i] * (ins[i] == 1 ? -1.0 : 1.0);
		double t; // in [-1, 1]
		if (p_sqrt_encoding) {
			const double mag = Math::sqrt(MIN(ABS(sd) / range, 1.0));
			t = sd < 0.0 ? -mag : mag;
		} else {
			t = CLAMP(sd / range, -1.0, 1.0);
		}
		const double stored = t * 0.5 + 0.5; // [0,1], which is what the shader un-maps
		if (p_half_float) {
			const uint16_t h = _float_to_half((float)stored);
			out[i * 2 + 0] = (uint8_t)(h & 0xFF);
			out[i * 2 + 1] = (uint8_t)(h >> 8);
		} else {
			out[i] = (uint8_t)CLAMP((int)Math::round(stored * 255.0), 0, 255);
		}
	}
	return Image::create_from_data(n, n, false,
			p_half_float ? Image::FORMAT_RH : Image::FORMAT_R8, data);
}

// Native terrain-graph cell-run evaluator. Build the program once, then loop the grid sampling the same
// cell-centre world point the GDScript oracle does (graph_cell_to_world == Pasture3DTerrainGraph.cell_to_world)
// and writing the output to float32 — the storage the oracle's materialised grid uses, so the two round
// identically at the boundary.
PackedFloat32Array Pasture3DUtil::graph_cell_eval_grid(const Dictionary &p_program, const int p_gw,
		const int p_gh, const Rect2 &p_rect) {
	const int n = MAX(p_gw, 0) * MAX(p_gh, 0);
	PackedFloat32Array out;
	out.resize(n);
	// A zeros grid up front doubles as the empty-program result: memset to 0 then bail if the build fails.
	float *w = out.ptrw();
	for (int i = 0; i < n; i++) {
		w[i] = 0.f;
	}
	GraphCellProgram prog;
	if (n == 0 || !graph_cell_build(p_program, prog)) {
		return out;
	}
	std::vector<double> scratch(prog.count);
	for (int iz = 0; iz < p_gh; iz++) {
		const int row = iz * p_gw;
		for (int ix = 0; ix < p_gw; ix++) {
			double wx, wz;
			graph_cell_to_world(ix, iz, p_gw, p_gh, p_rect, wx, wz);
			w[row + ix] = (float)graph_cell_eval(prog, wx, wz, scratch);
		}
	}
	return out;
}

// Native whole-graph evaluator — a thin binding over graph_eval_grid so a headless gate and the native
// rasteriser share one implementation.
PackedFloat32Array Pasture3DUtil::graph_eval_grid(const Dictionary &p_program, const int p_gw,
		const int p_gh, const Rect2 &p_rect, const PackedFloat32Array &p_input) {
	godot::GraphProgram prog;
	if (!godot::graph_build(p_program, prog)) {
		PackedFloat32Array out;
		out.resize(MAX(p_gw, 0) * MAX(p_gh, 0));
		out.fill(0.f);
		return out;
	}
	return godot::graph_eval_grid(prog, p_gw, p_gh, p_rect, p_input);
}

// GPU whole-graph evaluator binding. A persistent instance so the local RD + shader compile ONCE across
// calls. Returns empty on unavailable/failure — the gate (and any caller) reads that as "use the CPU path".
PackedFloat32Array Pasture3DUtil::graph_eval_grid_gpu(const Dictionary &p_program, const int p_gw,
		const int p_gh, const Rect2 &p_rect, const PackedFloat32Array &p_input) {
	static Pasture3DGraphGPU s_gpu;
	PackedFloat32Array out;
	godot::GraphProgram prog;
	if (!godot::graph_build(p_program, prog)) {
		return out; // empty
	}
	if (!s_gpu.eval_grid(prog, p_gw, p_gh, p_rect, p_input, out)) {
		return PackedFloat32Array(); // empty signals unavailable/failed
	}
	return out;
}

///////////////////////////
// Protected Functions
///////////////////////////

void Pasture3DUtil::_bind_methods() {
	// Control map converters
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("as_float", "value"), &as_float);
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("as_uint", "value"), &as_uint);
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("get_base", "pixel"), &gd_get_base);
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("enc_base", "base"), &gd_enc_base);
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("get_overlay", "pixel"), &gd_get_overlay);
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("enc_overlay", "overlay"), &gd_enc_overlay);
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("get_blend", "pixel"), &gd_get_blend);
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("enc_blend", "blend"), &gd_enc_blend);
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("get_uv_rotation", "pixel"), &gd_get_uv_rotation);
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("enc_uv_rotation", "rotation"), &gd_enc_uv_rotation);
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("get_uv_scale", "pixel"), &gd_get_uv_scale);
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("enc_uv_scale", "scale"), &gd_enc_uv_scale);
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("is_hole", "pixel"), &gd_is_hole);
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("enc_hole", "pixel"), &enc_hole);
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("is_nav", "pixel"), &gd_is_nav);
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("enc_nav", "pixel"), &enc_nav);
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("is_auto", "pixel"), &gd_is_auto);
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("enc_auto", "pixel"), &enc_auto);

	// String functions
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("filename_to_location", "filename"), &Pasture3DUtil::filename_to_location);
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("location_to_filename", "region_location"), &Pasture3DUtil::location_to_filename);
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("location_to_layer_filename", "region_location"), &Pasture3DUtil::location_to_layer_filename);

	// Image handling
	// Water bodies
	ClassDB::bind_static_method("Pasture3DUtil",
			D_METHOD("build_pool_mesh", "polygon", "min", "spacing", "grid_w", "grid_h"),
			&Pasture3DUtil::build_pool_mesh);
	ClassDB::bind_static_method("Pasture3DUtil",
			D_METHOD("build_inside_mask", "polygon", "min", "spacing", "grid_w", "grid_h"),
			&Pasture3DUtil::build_inside_mask);
	ClassDB::bind_static_method("Pasture3DUtil",
			D_METHOD("build_shore_sdf", "polygon", "min", "texel", "texels", "range",
					"exact_band", "half_float", "sqrt_encoding"),
			&Pasture3DUtil::build_shore_sdf, DEFVAL(2), DEFVAL(true), DEFVAL(false));

	// Image handling
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("black_to_alpha", "image"), &Pasture3DUtil::black_to_alpha);
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("get_min_max", "image"), &Pasture3DUtil::get_min_max);
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("get_thumbnail", "image", "size"), &Pasture3DUtil::get_thumbnail, DEFVAL(V2I(256)));
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("get_filled_image", "size", "color", "create_mipmaps", "format"), &Pasture3DUtil::get_filled_image);
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("load_image", "file_name", "cache_mode", "r16_height_range", "r16_size"), &Pasture3DUtil::load_image, DEFVAL(ResourceLoader::CACHE_MODE_IGNORE), DEFVAL(Vector2(0.f, 255.f)), DEFVAL(V2I_ZERO));
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("pack_image", "src_rgb", "src_a", "src_ao", "invert_green", "invert_alpha", "normalize_alpha", "alpha_channel", "ao_channel"), &Pasture3DUtil::pack_image, DEFVAL(false), DEFVAL(false), DEFVAL(false), DEFVAL(0), DEFVAL(0));
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("luminance_to_height", "src_rgb"), &Pasture3DUtil::luminance_to_height);

	// Terrain graph — the native cell-run evaluator, for the parity gate.
	ClassDB::bind_static_method("Pasture3DUtil",
			D_METHOD("graph_cell_eval_grid", "program", "gw", "gh", "rect"),
			&Pasture3DUtil::graph_cell_eval_grid);
	// Terrain graph — the native whole-graph evaluator (grid-pass interleave).
	ClassDB::bind_static_method("Pasture3DUtil",
			D_METHOD("graph_eval_grid", "program", "gw", "gh", "rect", "input"),
			&Pasture3DUtil::graph_eval_grid);
	// Terrain graph — the GPU whole-graph evaluator (RenderingDevice); empty return => unavailable/failed.
	ClassDB::bind_static_method("Pasture3DUtil",
			D_METHOD("graph_eval_grid_gpu", "program", "gw", "gh", "rect", "input"),
			&Pasture3DUtil::graph_eval_grid_gpu);
}
