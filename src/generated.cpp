// Copyright © 2023 Roope Palmroos, Cory Petkovsek, and Contributors. All rights reserved. See LICENSE.
#include <godot_cpp/classes/rendering_server.hpp>

#include "generated.h"
#include "terrain_3d_logger.h"

///////////////////////////
// Private Functions
///////////////////////////

void Generated::create(const TypedArray<Image> &p_layers) {
	if (!p_layers.is_empty()) {
		if (Terrain3D::_debug_level >= DEBUG) {
			LOG(DEBUG, "RenderingServer creating Texture2DArray, layers size: ", p_layers.size());
			for (int i = 0; i < p_layers.size(); i++) {
				Ref<Image> img = p_layers[i];
				LOG(DEBUG, i, ": ", img, ", empty: ", img->is_empty(), ", size: ", img->get_size(), ", format: ", img->get_format());
			}
		}
		_rid = RenderingServer::get_singleton()->texture_2d_layered_create(p_layers, RenderingServer::TEXTURE_LAYERED_2D_ARRAY);
		_dirty = false;
	} else {
		clear();
	}
}

void Generated::create(const Ref<Image> &p_image) {
	LOG(DEBUG, "RenderingServer creating Texture2D");
	_image = p_image;
	_rid = RenderingServer::get_singleton()->texture_2d_create(_image);
	_dirty = false;
}

void Generated::clear() {
	if (_rid.is_valid()) {
		LOG(DEBUG, "Generated freeing ", _rid);
		RenderingServer::get_singleton()->free_rid(_rid);
	}
	if (_image.is_valid()) {
		LOG(DEBUG, "Generated unref image", _image);
		_image.unref();
	}
	_rid = RID();
	_dirty = true;
}