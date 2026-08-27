#[compute]
#version 450

// Pasture3D — 3-Band Spatial Frequency Spectral Equalizer Kernel.
// Performs multi-scale Gaussian blur decomposition and frequency gain reconstruction.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer InHeight {
    float in_height[];
};

layout(set = 0, binding = 1, std430) readonly buffer InMeso {
    float in_meso[];
};

layout(set = 0, binding = 2, std430) readonly buffer InMacro {
    float in_macro[];
};

layout(set = 0, binding = 3, std430) readonly buffer InMask {
    float in_mask[];
};

layout(set = 0, binding = 4, std430) buffer OutHeight {
    float out_height[];
};

layout(push_constant) uniform PushConstants {
    int grid_w;
    int grid_h;
    float macro_gain;
    float meso_gain;
    float micro_gain;
    float amount;
} pc;

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    if (coord.x >= pc.grid_w || coord.y >= pc.grid_h) {
        return;
    }

    int idx = coord.y * pc.grid_w + coord.x;
    float h_orig = in_height[idx];
    if (isnan(h_orig) || isinf(h_orig)) {
        out_height[idx] = h_orig;
        return;
    }

    float macro_val = in_macro[idx];
    float meso_band = in_meso[idx] - macro_val;
    float micro_band = h_orig - in_meso[idx];

    float h_eq = pc.macro_gain * macro_val + pc.meso_gain * meso_band + pc.micro_gain * micro_band;
    float m = clamp(in_mask[idx], 0.0, 1.0);
    out_height[idx] = mix(h_orig, h_eq, pc.amount * m);
}
