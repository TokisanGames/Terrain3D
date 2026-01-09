// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

R"(

//INSERT: TEXTURE_SAMPLERS_LINEAR
#define FILTER_LINEAR
#define FILTER_METHOD filter_linear_mipmap_anisotropic

//INSERT: TEXTURE_SAMPLERS_NEAREST
#define FILTER_NEAREST
#define FILTER_METHOD filter_nearest_mipmap_anisotropic

)"