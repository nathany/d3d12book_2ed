// Port of `Shaders/SharedTypes.h` (Frank Luna) — the header the C++ shares between HLSL
// and C++ via macros. Odin can't include it, so the structs the demos bind are mirrored
// here BYTE-FOR-BYTE; the #asserts at the bottom pin the sizes so a drifted field or a
// dropped pad fails the build instead of shearing every cbuffer read after it.
//
// The C++ hand-pads every struct to HLSL cbuffer rules (16-byte registers; a float3 never
// spans one), which is why the pad fields below are load-bearing — keep them, in order.
// Only the members chapter 8 uses are documented; the rest (shadow/fog/terrain/ray-tracing
// slots) arrive with their chapters but must exist now because the HLSL side (included by
// every shader via Shaders/Common.hlsl) declares the full struct.
//
// Every struct is #packed because Odin's matrix type is SIMD-aligned (align_of(Mat4) is
// 32), which would otherwise insert padding HLSL doesn't have — e.g. Material_Data's
// mat_transform sits at byte 48, not a 32-byte boundary. The book's manual padding
// already places every field at its natural offset, so #packed removes only the phantom
// alignment, never real padding.
package common

import "../d3d_math"

// C++: DEFINE_CBUFFER(PerObjectCB, b0).
Per_Object_CB :: struct #packed {
	world:              d3d_math.Mat4,
	tex_transform:      d3d_math.Mat4,
	material_index:     u32,

	// Used for cube mapping.
	cube_map_index:     u32,
	_pad0:              [2]u32,

	// Used only for objects with tessellation.
	mesh_min_tess_dist: f32,
	mesh_max_tess_dist: f32,
	mesh_min_tess:      f32,
	mesh_max_tess:      f32,

	// Add some generic members so we can reuse the same structure for different objects.
	misc_uint4:         [4]u32,
	misc_float4:        [4]f32,
}

// C++: struct Light — the float3/float interleave packs each pair into one register.
Light :: struct #packed {
	strength:      [3]f32,
	falloff_start: f32, //    point/spot light only
	direction:     [3]f32, // directional/spot light only
	falloff_end:   f32, //    point/spot light only
	position:      [3]f32, // point/spot light only
	spot_power:    f32, //    spot light only
}

// C++: #define MaxLights 16
MAX_LIGHTS :: 16

// C++: DEFINE_CBUFFER(PerPassCB, b1).
Per_Pass_CB :: struct #packed {
	view:                    d3d_math.Mat4,
	inv_view:                d3d_math.Mat4,
	proj:                    d3d_math.Mat4,
	inv_proj:                d3d_math.Mat4,
	view_proj:               d3d_math.Mat4,
	inv_view_proj:           d3d_math.Mat4,
	shadow_transform:        d3d_math.Mat4,
	view_proj_tex:           d3d_math.Mat4,

	world_frustum_planes:    [6][4]f32,

	eye_pos_w:               [3]f32,
	_pad0:                   f32,

	render_target_size:      [2]f32,
	inv_render_target_size:  [2]f32,

	near_z:                  f32,
	far_z:                   f32,
	total_time:              f32,
	delta_time:              f32,

	ambient_light:           [4]f32,

	// Used in Chapter 10
	fog_color:               [4]f32,
	fog_start:               f32,
	fog_range:               f32,
	_pad1:                   [2]f32,

	sky_box_index:           u32,
	sun_shadow_map_index:    u32,
	random_tex_index:        u32,
	ray_trace_image_index:   u32,

	scene_depth_map_index:   u32,
	scene_normal_map_index:  u32,
	ssao_ambient_map0_index: u32,
	ssao_ambient_map1_index: u32,

	reflection_map_uav_index: u32,
	reflection_map_srv_index: u32,
	debug_tex_index:          u32,
	_pad2:                    u32,

	normal_maps_enabled:     u32,
	reflections_enabled:     u32,
	shadows_enabled:         u32,
	ssao_enabled:            u32,

	num_dir_lights:          u32,
	num_point_lights:        u32,
	num_spot_lights:         u32,
	fog_enabled:             u32,

	// Indices [0, num_dir_lights) are directional lights;
	// indices [num_dir_lights, num_dir_lights+num_point_lights) are point lights;
	// indices [num_dir_lights+num_point_lights, ...+num_spot_lights) are spot lights,
	// for a maximum of MAX_LIGHTS per object.
	lights:                  [MAX_LIGHTS]Light,
}

// C++: struct MaterialData — a StructuredBuffer element, so it packs tightly (C rules,
// 4-byte scalar alignment), unlike the register-padded cbuffers above.
Material_Data :: struct #packed {
	diffuse_albedo:            [4]f32,
	fresnel_r0:                [3]f32,
	roughness:                 f32,
	displacement_scale:        f32,

	diffuse_map_index:         u32,
	normal_map_index:          u32,
	gloss_height_ao_map_index: u32,

	// Used in texture mapping.
	mat_transform:             d3d_math.Mat4,

	// Used in ray tracing demos only.
	transparency_weight:       f32,
	index_of_refraction:       f32,
}

// Layout locks — sizes computed from the HLSL packing rules the C++ header encodes.
#assert(size_of(Per_Object_CB) == 192)
#assert(size_of(Light) == 48)
#assert(size_of(Per_Pass_CB) == 784 + MAX_LIGHTS * size_of(Light)) // 1552
#assert(size_of(Material_Data) == 120)
