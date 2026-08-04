// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <algorithm>

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/geometry2d.hpp>
#include <godot_cpp/classes/time.hpp>

#include "logger.h"
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

	// Image handling
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("black_to_alpha", "image"), &Pasture3DUtil::black_to_alpha);
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("get_min_max", "image"), &Pasture3DUtil::get_min_max);
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("get_thumbnail", "image", "size"), &Pasture3DUtil::get_thumbnail, DEFVAL(V2I(256)));
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("get_filled_image", "size", "color", "create_mipmaps", "format"), &Pasture3DUtil::get_filled_image);
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("load_image", "file_name", "cache_mode", "r16_height_range", "r16_size"), &Pasture3DUtil::load_image, DEFVAL(ResourceLoader::CACHE_MODE_IGNORE), DEFVAL(Vector2(0.f, 255.f)), DEFVAL(V2I_ZERO));
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("pack_image", "src_rgb", "src_a", "src_ao", "invert_green", "invert_alpha", "normalize_alpha", "alpha_channel", "ao_channel"), &Pasture3DUtil::pack_image, DEFVAL(false), DEFVAL(false), DEFVAL(false), DEFVAL(0), DEFVAL(0));
	ClassDB::bind_static_method("Pasture3DUtil", D_METHOD("luminance_to_height", "src_rgb"), &Pasture3DUtil::luminance_to_height);
}
