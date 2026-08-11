// Port of `Common/TextureLib.h/.cpp` (Frank Luna) — every texture the demos use, loaded
// in one place so demos don't duplicate the lists. The C++ is a process singleton that
// loads all ~55 book textures up front; this port passes the lib explicitly and
// DELIBERATELY loads only the textures the ported chapters need so the DDS loader only
// has to speak the formats actually on disk — extend the table (and, if a new format
// appears, dds_loader.odin) as chapters land.
package common

import "core:fmt"
import "core:os"
import d3d12 "vendor:directx/d3d12"

// C++: struct Texture (TextureLib.h).
Texture :: struct {
	// Unique name for lookup.
	name:           string,
	filename:       string,
	is_cube_map:    bool,
	bindless_index: i32, // C++ default -1; assigned in BuildCbvSrvUavDescriptorHeap
	resource:       ^d3d12.IResource,
}

Texture_Lib :: struct {
	textures: map[string]^Texture,
}

// C++: TextureLib::Init(device, uploadBatch) — name/filename table order preserved,
// trimmed to chapters ≤ 11.
texture_lib_init :: proc(lib: ^Texture_Lib, upload_batch: ^Resource_Upload_Batch) {
	Entry :: struct {
		name, filename: string,
	}
	entries := [?]Entry {
		{"crateDiffuseMap", "Textures/WoodCrate01.dds"},
		{"waterDiffuseMap", "Textures/water1.dds"},
		{"fenceDiffuseMap", "Textures/WireFence.dds"},
		{"grassDiffuseMap", "Textures/grass.dds"},

		{"bricksDiffuseMap", "Textures/bricks0_color.dds"},
		{"bricksNormalMap", "Textures/bricks0_normal.dds"},
		{"bricksGlossHeightAoMap", "Textures/bricks0_gloss_height_ao.dds"},

		{"tileDiffuseMap", "Textures/tile0.dds"},
		{"checkboardMap", "Textures/checkboard.dds"},
		{"iceMap", "Textures/ice.dds"},

		{"rock_color", "Textures/terrain/rock0_color.dds"},
		{"rock_normal", "Textures/terrain/rock0_normal.dds"},
		{"rock_gloss_height_ao", "Textures/terrain/rock0_gloss_height_ao.dds"},

		{"defaultDiffuseMap", "Textures/white1x1.dds"},
		{"defaultNormalMap", "Textures/default_nmap.dds"},
		{"defaultGlossHeightAoMap", "Textures/default_glossHeightAoMap.dds"},
	}

	for entry in entries {
		tex := new(Texture)
		tex.name = entry.name
		tex.filename = entry.filename
		tex.bindless_index = -1
		tex.resource, tex.is_cube_map = create_dds_texture(upload_batch, entry.filename)
		lib.textures[tex.name] = tex
	}
}

texture_lib_destroy :: proc(lib: ^Texture_Lib) {
	for _, tex in lib.textures {
		if tex.resource != nil {tex.resource->Release()}
		free(tex)
	}
	delete(lib.textures)
}

// C++: texLib["name"] — fatal on a miss instead of returning nullptr; every lookup in
// the demos is of a texture the table above must contain.
texture_lib_get :: proc(lib: ^Texture_Lib, name: string) -> ^Texture {
	tex, ok := lib.textures[name]
	if !ok {
		report_error(fmt.tprintf("texture %q is not in texture_lib_init's table", name))
		os.exit(1)
	}
	return tex
}
