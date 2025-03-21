// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

R"(

//INSERT: DUAL_SCALING_UNIFORMS
uniform int dual_scale_texture : hint_range(0,31) = 0;
uniform float dual_scale_reduction : hint_range(0.001,1) = 0.3;
uniform float tri_scale_reduction : hint_range(0.001,1) = 0.3;
uniform float dual_scale_far : hint_range(0,1000) = 170.0;
uniform float dual_scale_near : hint_range(0,1000) = 100.0;

//INSERT: DUAL_SCALING_BASE
	// If dual scaling, apply to base texture.
	if(region < 0) {
		mat_scale *= tri_scale_reduction;
	}
	float far_factor = clamp(smoothstep(dual_scale_near, dual_scale_far, length(v_vertex - _camera_pos)), 0.0, 1.0);
	if (out_mat.blend < 1.0 && (
			(far_factor < 1. && (out_mat.base == dual_scale_texture)) || out_mat.base != dual_scale_texture)) {
		// 2 lookups
		//each time we change scale, recalculate antitiling from baseline to maintain continuity.
		matUV = detiling(base_uv * mat_scale, index_pos * mat_scale, out_mat.base, normal_angle);
		dd1.xy = rotate_plane(ddxy.xy, -normal_angle);
		dd1.zw = rotate_plane(ddxy.zw, -normal_angle);
		dd1 *= mat_scale;
		albedo_ht = textureGrad(_texture_array_albedo, vec3(matUV, float(out_mat.base)), dd1.xy, dd1.zw);
		normal_rg = textureGrad(_texture_array_normal, vec3(matUV, float(out_mat.base)), dd1.xy, dd1.zw);

		// Unpack & rotate base normal for blending
		normal_rg.xyz = unpack_normal(normal_rg);
		normal_rg.xz = rotate_plane(normal_rg.xz, -normal_angle);
	}

	if (far_factor > 0. && ((out_mat.base == dual_scale_texture && out_mat.blend < 1.0)
			|| (out_mat.over == dual_scale_texture && out_mat.blend > 0.0))) {
		// 2 lookups
		mat_scale *= dual_scale_reduction;
		float dual_scale_normal = uv_rotation + p_angle; //do not add near & far rotations
		// Do not apply detiling if tri-scale reduction occurs.
		matUV = region < 0 ? base_uv * mat_scale : detiling(base_uv * mat_scale, index_pos * mat_scale, dual_scale_texture, dual_scale_normal);
		dd1.xy = rotate_plane(ddxy.xy, -dual_scale_normal);
		dd1.zw = rotate_plane(ddxy.zw, -dual_scale_normal);
		dd1 *= mat_scale;
		albedo_far = textureGrad(_texture_array_albedo, vec3(matUV, float(dual_scale_texture)), dd1.xy, dd1.zw);
		normal_far = textureGrad(_texture_array_normal, vec3(matUV, float(dual_scale_texture)), dd1.xy, dd1.zw);

		// Unpack & rotate dual scale normal for blending
		normal_far.xyz = unpack_normal(normal_far);
		normal_far.xz = rotate_plane(normal_far.xz, -dual_scale_normal);
	}
	
	if (out_mat.base == dual_scale_texture) {
		albedo_ht = mix(albedo_ht, albedo_far, far_factor);
		normal_rg = mix(normal_rg, normal_far, far_factor);
	}

//INSERT: UNI_SCALING_BASE
	if (out_mat.blend < 1.0) {
		// 2 lookups
		matUV = detiling(base_uv * mat_scale, index_pos * mat_scale, out_mat.base, normal_angle);
		dd1.xy = rotate_plane(ddxy.xy, -normal_angle);
		dd1.zw = rotate_plane(ddxy.zw, -normal_angle);
		dd1 *= mat_scale;
		albedo_ht = textureGrad(_texture_array_albedo, vec3(matUV, float(out_mat.base)), dd1.xy, dd1.zw);
		normal_rg = textureGrad(_texture_array_normal, vec3(matUV, float(out_mat.base)), dd1.xy, dd1.zw);

		// Unpack & rotate base normal for blending
		normal_rg.xyz = unpack_normal(normal_rg).xyz;
		normal_rg.xz = rotate_plane(normal_rg.xz, -normal_angle);
	}

//INSERT: DUAL_SCALING_OVERLAY
		// If dual scaling, apply to overlay texture
		if(out_mat.over == dual_scale_texture) {
			albedo_ht2 = mix(albedo_ht2, albedo_far, far_factor);
			normal_rg2 = mix(normal_rg2, normal_far, far_factor);
		}

)"