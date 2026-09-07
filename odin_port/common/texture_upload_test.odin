package common

import "core:testing"
import "../dds"

// These checks stop at metadata validation: no device, allocation or fatal UI required.
@(test)
dds_upload_limits :: proc(t: ^testing.T) {
	valid := [?]dds.Texture_Info{
		{width = 16384, height = 1, mip_levels = 15, array_size = 2048, format = .R8_UNORM},
		{width = 1, height = 16384, mip_levels = 15, array_size = 1, format = .R8_UNORM},
		{width = 4, height = 4, mip_levels = 3, array_size = 2046, format = .BC1_UNORM, is_cube_map = true},
		{width = 16384, height = 1, mip_levels = 1, array_size = 1, format = .R32G32B32A32_FLOAT},
	}
	for info in valid {
		testing.expectf(t, dds_texture_supported(info), "legal upload boundary rejected: %v", info)
	}
	invalid := [?]dds.Texture_Info{
		{width = 16385, height = 1, mip_levels = 1, array_size = 1, format = .R8_UNORM},
		{width = 1, height = 16385, mip_levels = 1, array_size = 1, format = .R8_UNORM},
		{width = 1, height = 1, mip_levels = 1, array_size = 2049, format = .R8_UNORM},
		{width = 1, height = 1, mip_levels = 1, array_size = 65536, format = .R8_UNORM},
		{width = 32768, height = 1, mip_levels = 16, array_size = 1, format = .R8_UNORM},
		{width = 16384, height = 1, mip_levels = 15, array_size = 2049, format = .R8_UNORM},
		{width = 4, height = 4, mip_levels = 1, array_size = 2052, format = .BC1_UNORM, is_cube_map = true},
		{width = 16385, height = 16385, mip_levels = 1, array_size = 6, format = .BC1_UNORM, is_cube_map = true},
		{},
	}
	for info in invalid {
		testing.expectf(t, !dds_texture_supported(info), "illegal upload metadata accepted: %v", info)
	}
}
