#+build windows
// Proves the claim that makes `dxgi.FORMAT(info.format)` safe: every member of the local
// `Format` enum has the same numeric value as its `vendor:directx/dxgi` counterpart.
//
// This is the only file in the package that imports a graphics API, and it is
// Windows-gated so the parser itself stays buildable everywhere (see README.md).
package dds

import "core:testing"
import dxgi "vendor:directx/dxgi"

@(test)
test_format_values_match_dxgi :: proc(t: ^testing.T) {
	// Written as explicit pairs rather than a loop over the enum: the point is to check
	// our numbers against *their* symbols, which only a literal correspondence does.
	Pair :: struct {
		ours:   Format,
		theirs: dxgi.FORMAT,
	}
	pairs := [?]Pair {
		{.UNKNOWN, .UNKNOWN},
		{.R32G32B32A32_TYPELESS, .R32G32B32A32_TYPELESS},
		{.R32G32B32A32_FLOAT, .R32G32B32A32_FLOAT},
		{.R16G16B16A16_FLOAT, .R16G16B16A16_FLOAT},
		{.R16G16B16A16_UNORM, .R16G16B16A16_UNORM},
		{.R16G16B16A16_SNORM, .R16G16B16A16_SNORM},
		{.R32G32_FLOAT, .R32G32_FLOAT},
		{.R10G10B10A2_UNORM, .R10G10B10A2_UNORM},
		{.R8G8B8A8_TYPELESS, .R8G8B8A8_TYPELESS},
		{.R8G8B8A8_UNORM, .R8G8B8A8_UNORM},
		{.R8G8B8A8_UNORM_SRGB, .R8G8B8A8_UNORM_SRGB},
		{.R8G8B8A8_SNORM, .R8G8B8A8_SNORM},
		{.R16G16_FLOAT, .R16G16_FLOAT},
		{.R16G16_UNORM, .R16G16_UNORM},
		{.R16G16_SNORM, .R16G16_SNORM},
		{.R32_FLOAT, .R32_FLOAT},
		{.R8G8_UNORM, .R8G8_UNORM},
		{.R8G8_SNORM, .R8G8_SNORM},
		{.R16_FLOAT, .R16_FLOAT},
		{.R16_UNORM, .R16_UNORM},
		{.R8_UNORM, .R8_UNORM},
		{.A8_UNORM, .A8_UNORM},
		{.BC1_TYPELESS, .BC1_TYPELESS},
		{.BC1_UNORM, .BC1_UNORM},
		{.BC1_UNORM_SRGB, .BC1_UNORM_SRGB},
		{.BC2_TYPELESS, .BC2_TYPELESS},
		{.BC2_UNORM, .BC2_UNORM},
		{.BC2_UNORM_SRGB, .BC2_UNORM_SRGB},
		{.BC3_TYPELESS, .BC3_TYPELESS},
		{.BC3_UNORM, .BC3_UNORM},
		{.BC3_UNORM_SRGB, .BC3_UNORM_SRGB},
		{.BC4_TYPELESS, .BC4_TYPELESS},
		{.BC4_UNORM, .BC4_UNORM},
		{.BC4_SNORM, .BC4_SNORM},
		{.BC5_TYPELESS, .BC5_TYPELESS},
		{.BC5_UNORM, .BC5_UNORM},
		{.BC5_SNORM, .BC5_SNORM},
		{.B5G6R5_UNORM, .B5G6R5_UNORM},
		{.B5G5R5A1_UNORM, .B5G5R5A1_UNORM},
		{.B8G8R8A8_UNORM, .B8G8R8A8_UNORM},
		{.B8G8R8X8_UNORM, .B8G8R8X8_UNORM},
		{.B8G8R8A8_TYPELESS, .B8G8R8A8_TYPELESS},
		{.B8G8R8A8_UNORM_SRGB, .B8G8R8A8_UNORM_SRGB},
		{.B8G8R8X8_TYPELESS, .B8G8R8X8_TYPELESS},
		{.B8G8R8X8_UNORM_SRGB, .B8G8R8X8_UNORM_SRGB},
		{.BC6H_TYPELESS, .BC6H_TYPELESS},
		{.BC6H_UF16, .BC6H_UF16},
		{.BC6H_SF16, .BC6H_SF16},
		{.BC7_TYPELESS, .BC7_TYPELESS},
		{.BC7_UNORM, .BC7_UNORM},
		{.BC7_UNORM_SRGB, .BC7_UNORM_SRGB},
		{.B4G4R4A4_UNORM, .B4G4R4A4_UNORM},
	}

	for p in pairs {
		testing.expectf(
			t,
			u32(p.ours) == u32(p.theirs),
			"dds.Format.%v is %d but dxgi.FORMAT.%v is %d",
			p.ours, u32(p.ours), p.theirs, u32(p.theirs),
		)
	}

	// Every member of our enum must be covered above, or a newly added format could drift
	// from DXGI unnoticed.
	testing.expect_value(t, len(pairs), len(Format))
}
