// Port of `Common/MaterialLib.h/.cpp` (Frank Luna) — every material the demos use,
// defined once. Like texture_lib.odin, the C++ singleton defines the whole book's table
// up front; this port passes the lib explicitly and carries only the materials the
// ported demos reference (values verbatim from the C++) — extend per chapter.
//
// Init AFTER the CbvSrvUav heap has assigned every texture its bindless index: the
// material table snapshots those indices, and they're what the shader uses to find the
// textures (ResourceDescriptorHeap[matData.DiffuseMapIndex]).
package common

import "core:fmt"
import "core:os"
import "../d3d_math"

Material_Lib :: struct {
	materials:      map[string]^Material,
	next_mat_index: i32, // C++: function-local static matIndex in AddMaterial
}

// C++: MaterialLib::AddMaterial(name, albedoMap, normalMap, glossHeightAoMap, diffuse,
// fresnel, roughness, displacementScale, matTransform, ...).
@(private = "file")
add_material :: proc(
	lib: ^Material_Lib,
	tex_lib: ^Texture_Lib,
	name: string,
	albedo_map: string,
	normal_map: string,
	gloss_height_ao_map: string,
	diffuse: [4]f32,
	fresnel: [3]f32,
	roughness: f32,
	displacement_scale: f32 = 1.0,
) {
	mat := new(Material)
	mat.name = name
	mat.mat_index = lib.next_mat_index
	mat.albedo_bindless_index = texture_lib_get(tex_lib, albedo_map).bindless_index
	mat.normal_bindless_index = texture_lib_get(tex_lib, normal_map).bindless_index
	mat.gloss_height_ao_bindless_index = texture_lib_get(tex_lib, gloss_height_ao_map).bindless_index
	mat.num_frames_dirty = NUM_FRAME_RESOURCES
	mat.diffuse_albedo = diffuse
	mat.fresnel_r0 = fresnel
	mat.roughness = roughness
	mat.displacement_scale = displacement_scale
	mat.mat_transform = d3d_math.MAT4_IDENTITY

	lib.materials[name] = mat
	lib.next_mat_index += 1
}

// C++: MaterialLib::AddMaterial — used for materials local to one demo.
material_lib_add :: proc(
	lib: ^Material_Lib,
	tex_lib: ^Texture_Lib,
	name: string,
	albedo_map: string,
	normal_map: string,
	gloss_height_ao_map: string,
	diffuse: [4]f32,
	fresnel: [3]f32,
	roughness: f32,
	displacement_scale: f32 = 1.0,
) {
	add_material(
		lib, tex_lib, name, albedo_map, normal_map, gloss_height_ao_map,
		diffuse, fresnel, roughness, displacement_scale,
	)
}

// C++: MaterialLib::Init(device) — the table, trimmed to chapters ≤ 14.
material_lib_init :: proc(lib: ^Material_Lib, tex_lib: ^Texture_Lib) {
	add_material(lib, tex_lib, "whiteMat",
		"defaultDiffuseMap", "defaultNormalMap", "defaultGlossHeightAoMap",
		{1.0, 1.0, 1.0, 1.0}, {0.1, 0.1, 0.1}, 0.5)

	add_material(lib, tex_lib, "crate",
		"crateDiffuseMap", "defaultNormalMap", "defaultGlossHeightAoMap",
		{1.0, 1.0, 1.0, 1.0}, {0.1, 0.1, 0.1}, 0.3)

	add_material(lib, tex_lib, "water",
		"waterDiffuseMap", "defaultNormalMap", "defaultGlossHeightAoMap",
		{1.0, 1.0, 1.0, 0.5}, {0.1, 0.1, 0.1}, 0.1)

	add_material(lib, tex_lib, "fence",
		"fenceDiffuseMap", "defaultNormalMap", "defaultGlossHeightAoMap",
		{1.0, 1.0, 1.0, 1.0}, {0.1, 0.1, 0.1}, 0.25)

	add_material(lib, tex_lib, "grass",
		"grassDiffuseMap", "defaultNormalMap", "defaultGlossHeightAoMap",
		{1.0, 1.0, 1.0, 1.0}, {0.1, 0.1, 0.1}, 0.8)

	add_material(lib, tex_lib, "bricks0",
		"bricksDiffuseMap", "bricksNormalMap", "bricksGlossHeightAoMap",
		{1.0, 1.0, 1.0, 1.0}, {0.1, 0.1, 0.1}, 0.3)

	add_material(lib, tex_lib, "tile0",
		"tileDiffuseMap", "defaultNormalMap", "defaultGlossHeightAoMap",
		{0.9, 0.9, 0.9, 1.0}, {0.2, 0.2, 0.2}, 0.1, displacement_scale = 0.25)

	add_material(lib, tex_lib, "rock0",
		"rock_color", "rock_normal", "rock_gloss_height_ao",
		{0.9, 0.9, 0.9, 1.0}, {0.2, 0.2, 0.2}, 0.1)

	add_material(lib, tex_lib, "skullMat",
		"defaultDiffuseMap", "defaultNormalMap", "defaultGlossHeightAoMap",
		{0.8, 0.8, 0.8, 1.0}, {0.6, 0.6, 0.6}, 0.2)

	add_material(lib, tex_lib, "treeSprites",
		"treeSpritesArray", "defaultNormalMap", "defaultGlossHeightAoMap",
		{1.0, 1.0, 1.0, 1.0}, {0.01, 0.01, 0.01}, 0.125)
}

material_lib_destroy :: proc(lib: ^Material_Lib) {
	for _, mat in lib.materials {
		free(mat)
	}
	delete(lib.materials)
}

// C++: matLib["name"] — fatal on a miss instead of returning nullptr.
material_lib_get :: proc(lib: ^Material_Lib, name: string) -> ^Material {
	mat, ok := lib.materials[name]
	if !ok {
		report_error(fmt.tprintf("material %q is not in material_lib_init's table", name))
		os.exit(1)
	}
	return mat
}

// C++: matLib.GetMaterialCount().
material_count :: proc(lib: ^Material_Lib) -> u32 {
	return u32(len(lib.materials))
}
