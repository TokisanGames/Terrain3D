// Copyright © 2023 Cory Petkovsek, Roope Palmroos, and Contributors.

R"(

//INSERT: DUAL_SCALING_UNIFORMS
uniform int dual_scale_texture : hint_range(0,31) = 0;
uniform float dual_scale_reduction : hint_range(0.001,1) = 0.3;
uniform float tri_scale_reduction : hint_range(0.001,1) = 0.3;
uniform float dual_scale_far : hint_range(0,1000) = 170.0;
uniform float dual_scale_near : hint_range(0,1000) = 100.0;

//INSERT: DUAL_SCALING_BASE
	// If dual scaling, apply to base texture
	if(region < 0) {
		mat_scale *= tri_scale_reduction;
	}
	//each time we change scale, recalculate antitiling from baseline to maintain continuity.
	matUV = uv_detiling(base_uv * mat_scale, uv_center * mat_scale, out_mat.base);
	ddx1 *= mat_scale;
	ddy1 *= mat_scale;
	albedo_ht = textureGrad(_texture_array_albedo, vec3(matUV, float(out_mat.base)), ddx1, ddy1);
	normal_rg = textureGrad(_texture_array_normal, vec3(matUV, float(out_mat.base)), ddx1, ddy1);
	if(out_mat.base == dual_scale_texture || out_mat.over == dual_scale_texture) {
		mat_scale *= dual_scale_reduction;
		ddx1 *= dual_scale_reduction;
		ddy1 *= dual_scale_reduction;
		matUV = uv_detiling(base_uv * mat_scale, uv_center * mat_scale, dual_scale_texture);
		albedo_far = textureGrad(_texture_array_albedo, vec3(matUV, float(dual_scale_texture)), ddx1, ddy1);
		normal_far = textureGrad(_texture_array_normal, vec3(matUV, float(dual_scale_texture)), ddx1, ddy1);
	}

	float far_factor = clamp(smoothstep(dual_scale_near, dual_scale_far, length(v_vertex - v_camera_pos)), 0.0, 1.0);
	if(out_mat.base == dual_scale_texture) {
		albedo_ht = mix(albedo_ht, albedo_far, far_factor);
		normal_rg = mix(normal_rg, normal_far, far_factor);
	}

//INSERT: UNI_SCALING_BASE
	matUV = uv_detiling(base_uv * mat_scale, uv_center * mat_scale, out_mat.base);
	ddx1 *= mat_scale;
	ddy1 *= mat_scale;
	albedo_ht = textureGrad(_texture_array_albedo, vec3(matUV, float(out_mat.base)), ddx1, ddy1);
	normal_rg = textureGrad(_texture_array_normal, vec3(matUV, float(out_mat.base)), ddx1, ddy1);

//INSERT: DUAL_SCALING_OVERLAY
		// If dual scaling, apply to overlay texture
		if(out_mat.over == dual_scale_texture) {
			albedo_ht2 = mix(albedo_ht2, albedo_far, far_factor);
			normal_rg2 = mix(normal_rg2, normal_far, far_factor);
		}

)"