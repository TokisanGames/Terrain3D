// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

R"(

//INSERT: DUAL_SCALING_UNIFORMS
uniform int dual_scale_texture : hint_range(0,31) = 0;
uniform float dual_scale_reduction : hint_range(0.001,1) = 0.3;
uniform float tri_scale_reduction : hint_range(0.001,1) = 0.3;
uniform float dual_scale_far : hint_range(0,1000) = 170.0;
uniform float dual_scale_near : hint_range(0,1000) = 100.0;

//INSERT: DUAL_SCALING
		// tri scaling
		if (index.z < 0) {
			i_dd *= tri_scale_reduction;
			i_uv *= tri_scale_reduction;
			i_pos *= tri_scale_reduction;
		}

		// dual scaling
		float far_factor = clamp(smoothstep(dual_scale_near, dual_scale_far, length(v_vertex - _camera_pos)), 0.0, 1.0);
		vec4 far_alb = vec4(0.);
		vec4 far_nrm = vec4(0.);
		if (far_factor > 0. && (data.texture_id[0] == dual_scale_texture || data.texture_id[1] == dual_scale_texture)) {
			float far_scale = _texture_uv_scale_array[dual_scale_texture] * dual_scale_reduction;
			vec2 far_uv = i_uv * far_scale;
			vec4 far_dd = i_dd * far_scale;

			// Detiling and Control map rotation
			vec2 uv_center = floor(i_pos * far_scale + 0.5);
			float detile = fma(random(uv_center), 2.0, -1.0) * TAU;
			vec2 detile_shift = vec2(_texture_detile_array[dual_scale_texture].y * detile);
			// Detile rotation matrix
			mat2 far_align = rotate_plane(detile * _texture_detile_array[dual_scale_texture].x);
			// Apply rotation and shift around pivot, offset to center UV over pivot.
			far_uv = far_align * (far_uv - uv_center + detile_shift) + uv_center + 0.5;
			// Transpose to rotate derivatives and normals counter to uv rotation, include control map rotation.
			far_align = transpose(far_align) * c_align;
			// Align derivatives for correct anisotropic filtering
			far_dd.xy *= far_align;
			far_dd.zw *= far_align;

			far_alb = textureGrad(_texture_array_albedo, vec3(far_uv, float(dual_scale_texture)), far_dd.xy, far_dd.zw);
			far_nrm = textureGrad(_texture_array_normal, vec3(far_uv, float(dual_scale_texture)), far_dd.xy, far_dd.zw);
			far_alb.rgb *= _texture_color_array[dual_scale_texture].rgb;
			far_nrm.a = clamp(far_nrm.a + _texture_roughness_mod_array[dual_scale_texture], 0., 1.);
			// Unpack normal map rotation and blending.
			far_nrm.xyz = fma(far_nrm.xzy, vec3(2.0), vec3(-1.0));
			far_nrm.xz *= far_align;
		}

//INSERT: DUAL_SCALING_MIX
			// If dual scaling, apply to overlay texture
			if (id == dual_scale_texture && far_factor > 0.) {
				alb = mix(alb, far_alb, far_factor);
				nrm = mix(nrm, far_nrm, far_factor);
			}

)"