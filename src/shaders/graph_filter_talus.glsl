#[compute]
#version 450

// Pasture3D — Graph Talus Projection / Angle-of-Repose Relaxation Kernel.
// Simulates cellular volume transfer down steep slopes exceeding critical angle of repose.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer InHeight {
    float in_height[];
};

layout(set = 0, binding = 1, std430) readonly buffer InMask {
    float in_mask[];
};

layout(set = 0, binding = 2, std430) buffer OutHeight {
    float out_height[];
};

layout(push_constant) uniform PushConstants {
    int grid_w;
    int grid_h;
    float dx;
    float dz;
    float tan_talus;
    float rate;
    float amount;
    int pass_type; // 0 = relax iteration, 1 = blend mask
} pc;

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    if (coord.x >= pc.grid_w || coord.y >= pc.grid_h) {
        return;
    }

    int idx = coord.y * pc.grid_w + coord.x;
    float h_c = out_height[idx];
    if (isnan(h_c) || isinf(h_c)) {
        return;
    }

    if (pc.pass_type == 0) {
        // Relaxation iteration
        float diag_d = sqrt(pc.dx * pc.dx + pc.dz * pc.dz);
        const ivec2 offsets[8] = ivec2[8](
            ivec2(-1, 0), ivec2(1, 0),
            ivec2(0, -1), ivec2(0, 1),
            ivec2(-1, -1), ivec2(1, -1),
            ivec2(-1, 1), ivec2(1, 1)
        );
        const float dists[8] = float[8](
            pc.dx, pc.dx, pc.dz, pc.dz,
            diag_d, diag_d, diag_d, diag_d
        );

        float delta = 0.0;
        for (int k = 0; k < 8; k++) {
            ivec2 n_coord = coord + offsets[k];
            if (n_coord.x >= 0 && n_coord.x < pc.grid_w && n_coord.y >= 0 && n_coord.y < pc.grid_h) {
                int n_idx = n_coord.y * pc.grid_w + n_coord.x;
                float n_h = out_height[n_idx];
                if (!isnan(n_h) && !isinf(n_h)) {
                    float diff = h_c - n_h;
                    float max_diff = dists[k] * pc.tan_talus;
                    if (diff > max_diff) {
                        delta -= (diff - max_diff) * pc.rate;
                    } else if (-diff > max_diff) {
                        delta += (-diff - max_diff) * pc.rate;
                    }
                }
            }
        }
        out_height[idx] = h_c + delta;
    } else {
        // Final blend with mask
        float orig_h = in_height[idx];
        if (!isnan(orig_h)) {
            float m = clamp(in_mask[idx], 0.0, 1.0);
            out_height[idx] = mix(orig_h, h_c, pc.amount * m);
        }
    }
}
