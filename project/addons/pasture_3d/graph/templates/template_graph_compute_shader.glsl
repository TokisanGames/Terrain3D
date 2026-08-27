#[compute]
#version 450

// TemplateGraphComputeShader — Boilerplate starting compute shader for Pasture3D GPU filters.

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
    float intensity;
} pc;

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    if (coord.x >= pc.grid_w || coord.y >= pc.grid_h) {
        return;
    }

    int idx = coord.y * pc.grid_w + coord.x;
    float val = in_height[idx];
    if (isnan(val) || isinf(val)) {
        out_height[idx] = val;
        return;
    }

    float m = clamp(in_mask[idx], 0.0, 1.0);
    out_height[idx] = val + pc.intensity * m;
}
