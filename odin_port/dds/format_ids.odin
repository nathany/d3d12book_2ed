// The format vocabulary, defined locally so this package depends on no graphics API.
//
// The numbering is DXGI's, and that is NOT a Direct3D dependency — it is the DDS file
// format's own vocabulary. A DX10-extended header stores a raw `DXGI_FORMAT` integer in
// its `dxgiFormat` field, so these numbers are what's literally on disk. Matching them
// keeps the DX10 parse path a plain cast and makes `Format` self-documenting against the
// DDS spec.
//
// Consequently `Format` converts to a D3D12/DXGI format by value:
//
//	dxgi.FORMAT(info.format)      // always valid; format_dxgi_test.odin proves it
//
// Other APIs (Vulkan's VK_FORMAT_BC*, Metal, WebGPU) number their formats differently and
// would each need a mapping table. Those belong with the backend that can test them, not
// here — this project is DX12-only, and an untested table is worse than no table.
//
// Only the formats this parser can produce are listed; see README.md for the
// deliberately-unsupported set. Adding one means adding it here, in `bits_per_pixel`,
// and (if block-compressed) in `is_compressed`/`block_bytes`.
package dds

// Values are DXGI_FORMAT's, from the Microsoft `dxgiformat.h` enumeration.
Format :: enum u32 {
	UNKNOWN                = 0,

	R32G32B32A32_TYPELESS  = 1,
	R32G32B32A32_FLOAT     = 2,
	R16G16B16A16_FLOAT     = 10,
	R16G16B16A16_UNORM     = 11,
	R16G16B16A16_SNORM     = 13,
	R32G32_FLOAT           = 16,
	R10G10B10A2_UNORM      = 24,
	R8G8B8A8_TYPELESS      = 27,
	R8G8B8A8_UNORM         = 28,
	R8G8B8A8_UNORM_SRGB    = 29,
	R8G8B8A8_SNORM         = 31,
	R16G16_FLOAT           = 34,
	R16G16_UNORM           = 35,
	R16G16_SNORM           = 37,
	R32_FLOAT              = 41,
	R8G8_UNORM             = 49,
	R8G8_SNORM             = 51,
	R16_FLOAT              = 54,
	R16_UNORM              = 56,
	R8_UNORM               = 61,
	A8_UNORM               = 65,

	BC1_TYPELESS           = 70,
	BC1_UNORM              = 71,
	BC1_UNORM_SRGB         = 72,
	BC2_TYPELESS           = 73,
	BC2_UNORM              = 74,
	BC2_UNORM_SRGB         = 75,
	BC3_TYPELESS           = 76,
	BC3_UNORM              = 77,
	BC3_UNORM_SRGB         = 78,
	BC4_TYPELESS           = 79,
	BC4_UNORM              = 80,
	BC4_SNORM              = 81,
	BC5_TYPELESS           = 82,
	BC5_UNORM              = 83,
	BC5_SNORM              = 84,

	B5G6R5_UNORM           = 85,
	B5G5R5A1_UNORM         = 86,
	B8G8R8A8_UNORM         = 87,
	B8G8R8X8_UNORM         = 88,
	B8G8R8A8_TYPELESS      = 90,
	B8G8R8A8_UNORM_SRGB    = 91,
	B8G8R8X8_TYPELESS      = 92,
	B8G8R8X8_UNORM_SRGB    = 93,

	BC6H_TYPELESS          = 94,
	BC6H_UF16              = 95,
	BC6H_SF16              = 96,
	BC7_TYPELESS           = 97,
	BC7_UNORM              = 98,
	BC7_UNORM_SRGB         = 99,

	B4G4R4A4_UNORM         = 115,
}
