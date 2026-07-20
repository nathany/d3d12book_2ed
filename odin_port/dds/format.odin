// Format tables, ported from DirectXTK12's `Src/LoaderHelpers.h` (MIT license,
// https://github.com/microsoft/DirectXTK12) — `BitsPerPixel`, `GetSurfaceInfo`, and
// `GetDXGIFormat`. The vendored copy this was read from is
// `External/DirectXTK12/Src/LoaderHelpers.h`.
//
// Ported as a documented SUBSET; see README.md for the full supported/unsupported matrix
// and why. Anything not covered returns UNKNOWN / 0 bits, which the parser turns into
// `.Unsupported_Format` — never a silent wrong answer.
package dds

import dxgi "vendor:directx/dxgi"

// C++: LoaderHelpers::BitsPerPixel(fmt). Returns 0 for formats this port doesn't cover,
// which `surface_info` reports as an error rather than guessing a stride.
bits_per_pixel :: proc(format: dxgi.FORMAT) -> u32 {
	#partial switch format {
	case .R32G32B32A32_TYPELESS, .R32G32B32A32_FLOAT:
		return 128

	case .R16G16B16A16_UNORM, .R16G16B16A16_FLOAT:
		return 64

	case .R10G10B10A2_UNORM,
	     .R8G8B8A8_TYPELESS, .R8G8B8A8_UNORM, .R8G8B8A8_UNORM_SRGB, .R8G8B8A8_SNORM,
	     .R16G16_UNORM, .R16G16_SNORM, .R16G16_FLOAT,
	     .R32_FLOAT,
	     .B8G8R8A8_UNORM, .B8G8R8X8_UNORM,
	     .B8G8R8A8_TYPELESS, .B8G8R8A8_UNORM_SRGB,
	     .B8G8R8X8_TYPELESS, .B8G8R8X8_UNORM_SRGB:
		return 32

	case .R8G8_UNORM, .R8G8_SNORM,
	     .R16_UNORM, .R16_FLOAT,
	     .B5G6R5_UNORM, .B5G5R5A1_UNORM, .B4G4R4A4_UNORM:
		return 16

	case .R8_UNORM, .A8_UNORM,
	     .BC2_TYPELESS, .BC2_UNORM, .BC2_UNORM_SRGB,
	     .BC3_TYPELESS, .BC3_UNORM, .BC3_UNORM_SRGB,
	     .BC5_TYPELESS, .BC5_UNORM, .BC5_SNORM,
	     .BC6H_TYPELESS, .BC6H_UF16, .BC6H_SF16,
	     .BC7_TYPELESS, .BC7_UNORM, .BC7_UNORM_SRGB:
		return 8

	case .BC1_TYPELESS, .BC1_UNORM, .BC1_UNORM_SRGB,
	     .BC4_TYPELESS, .BC4_UNORM, .BC4_SNORM:
		return 4
	}

	return 0
}

// C++: LoaderHelpers::IsCompressed(fmt) — the block-compressed formats, whose surfaces
// are measured in 4x4 texel blocks rather than rows of pixels.
is_compressed :: proc(format: dxgi.FORMAT) -> bool {
	#partial switch format {
	case .BC1_TYPELESS, .BC1_UNORM, .BC1_UNORM_SRGB,
	     .BC2_TYPELESS, .BC2_UNORM, .BC2_UNORM_SRGB,
	     .BC3_TYPELESS, .BC3_UNORM, .BC3_UNORM_SRGB,
	     .BC4_TYPELESS, .BC4_UNORM, .BC4_SNORM,
	     .BC5_TYPELESS, .BC5_UNORM, .BC5_SNORM,
	     .BC6H_TYPELESS, .BC6H_UF16, .BC6H_SF16,
	     .BC7_TYPELESS, .BC7_UNORM, .BC7_UNORM_SRGB:
		return true
	}
	return false
}

// Bytes per 4x4 block: 8 for the "half rate" formats, 16 for the rest. Only meaningful
// when is_compressed(format).
@(private)
block_bytes :: proc(format: dxgi.FORMAT) -> u32 {
	#partial switch format {
	case .BC1_TYPELESS, .BC1_UNORM, .BC1_UNORM_SRGB,
	     .BC4_TYPELESS, .BC4_UNORM, .BC4_SNORM:
		return 8
	}
	return 16
}

// C++: LoaderHelpers::GetSurfaceInfo(width, height, fmt, &numBytes, &rowBytes, &numRows).
//
// `row_bytes` is the TIGHT pitch as stored in the file — not D3D12's 256-byte-aligned
// upload pitch. Block-compressed formats round each dimension up to whole 4x4 blocks, so
// a 1x1 BC1 mip still occupies one full 8-byte block.
surface_info :: proc(
	width, height: u32,
	format: dxgi.FORMAT,
) -> (
	num_bytes, row_bytes, num_rows: u32,
	ok: bool,
) {
	if is_compressed(format) {
		bpe := block_bytes(format)
		num_blocks_wide := width == 0 ? 0 : max(u32(1), (width + 3) / 4)
		num_blocks_high := height == 0 ? 0 : max(u32(1), (height + 3) / 4)
		row_bytes = num_blocks_wide * bpe
		num_rows = num_blocks_high
		num_bytes = row_bytes * num_blocks_high
		return num_bytes, row_bytes, num_rows, true
	}

	bpp := bits_per_pixel(format)
	if bpp == 0 {
		return 0, 0, 0, false
	}

	row_bytes = (width * bpp + 7) / 8 // round up to nearest byte
	num_rows = height
	num_bytes = row_bytes * height
	return num_bytes, row_bytes, num_rows, true
}

// The DDS_PIXELFORMAT block of the header (`DDS.h`), exposed because a failed format
// lookup wants to report exactly what it saw.
Pixel_Format :: struct #packed {
	size:          u32,
	flags:         u32,
	four_cc:       u32,
	rgb_bit_count: u32,
	r_bit_mask:    u32,
	g_bit_mask:    u32,
	b_bit_mask:    u32,
	a_bit_mask:    u32,
}

#assert(size_of(Pixel_Format) == 32)

// DDS_PIXELFORMAT flags (`DDS.h`).
DDPF_ALPHAPIXELS :: u32(0x1)
DDPF_ALPHA :: u32(0x2)
DDPF_FOURCC :: u32(0x4)
DDPF_RGB :: u32(0x40)
DDPF_LUMINANCE :: u32(0x20000)
DDPF_BUMPDUDV :: u32(0x80000)

// C++: MAKEFOURCC(a, b, c, d).
make_four_cc :: proc "contextless" (s: string) -> u32 {
	assert_contextless(len(s) == 4)
	return u32(s[0]) | u32(s[1]) << 8 | u32(s[2]) << 16 | u32(s[3]) << 24
}

FOURCC_DX10 :: u32(0x30315844) // "DX10"

@(private)
is_bit_mask :: proc "contextless" (pf: Pixel_Format, r, g, b, a: u32) -> bool {
	return pf.r_bit_mask == r && pf.g_bit_mask == g && pf.b_bit_mask == b && pf.a_bit_mask == a
}

// C++: LoaderHelpers::GetDXGIFormat(ddpf) — the legacy (non-DX10-header) format mapping.
// Returns .UNKNOWN for anything unmapped, including formats DirectXTK12 does handle; see
// README.md for the diff and the rationale.
dxgi_format_from_pixel_format :: proc(pf: Pixel_Format) -> dxgi.FORMAT {
	if pf.flags & DDPF_RGB != 0 {
		// Note that sRGB formats are written using the "DX10" extended header.
		switch pf.rgb_bit_count {
		case 32:
			if is_bit_mask(pf, 0x000000ff, 0x0000ff00, 0x00ff0000, 0xff000000) {
				return .R8G8B8A8_UNORM
			}
			if is_bit_mask(pf, 0x00ff0000, 0x0000ff00, 0x000000ff, 0xff000000) {
				return .B8G8R8A8_UNORM
			}
			if is_bit_mask(pf, 0x00ff0000, 0x0000ff00, 0x000000ff, 0) {
				return .B8G8R8X8_UNORM
			}

			// No DXGI format maps to (0x000000ff, 0x0000ff00, 0x00ff0000, 0) aka
			// D3DFMT_X8B8G8R8.

			// Many DDS writers (including D3DX) swap the RED/BLUE masks for 10:10:10:2;
			// DirectXTK12 assumes the 'backwards' header mask, so we match it.
			if is_bit_mask(pf, 0x3ff00000, 0x000ffc00, 0x000003ff, 0xc0000000) {
				return .R10G10B10A2_UNORM
			}
			if is_bit_mask(pf, 0x0000ffff, 0xffff0000, 0, 0) {
				return .R16G16_UNORM
			}
			if is_bit_mask(pf, 0xffffffff, 0, 0, 0) {
				// The only 32-bit single-channel format in D3D9 was R32F.
				return .R32_FLOAT
			}

		case 16:
			if is_bit_mask(pf, 0x7c00, 0x03e0, 0x001f, 0x8000) {
				return .B5G5R5A1_UNORM
			}
			if is_bit_mask(pf, 0xf800, 0x07e0, 0x001f, 0) {
				return .B5G6R5_UNORM
			}
			if is_bit_mask(pf, 0x0f00, 0x00f0, 0x000f, 0xf000) {
				return .B4G4R4A4_UNORM
			}
			// NVTT 1.x wrote these as RGB instead of LUMINANCE.
			if is_bit_mask(pf, 0x00ff, 0, 0, 0xff00) {
				return .R8G8_UNORM
			}
			if is_bit_mask(pf, 0xffff, 0, 0, 0) {
				return .R16_UNORM
			}

		case 8:
			// NVTT 1.x wrote this as RGB instead of LUMINANCE.
			if is_bit_mask(pf, 0xff, 0, 0, 0) {
				return .R8_UNORM
			}
		}
	} else if pf.flags & DDPF_LUMINANCE != 0 {
		switch pf.rgb_bit_count {
		case 16:
			if is_bit_mask(pf, 0xffff, 0, 0, 0) {
				return .R16_UNORM
			}
			if is_bit_mask(pf, 0x00ff, 0, 0, 0xff00) {
				return .R8G8_UNORM
			}
		case 8:
			if is_bit_mask(pf, 0xff, 0, 0, 0) {
				return .R8_UNORM
			}
			// Some DDS writers assume the bitcount should be 8 instead of 16.
			if is_bit_mask(pf, 0x00ff, 0, 0, 0xff00) {
				return .R8G8_UNORM
			}
		}
	} else if pf.flags & DDPF_ALPHA != 0 {
		if pf.rgb_bit_count == 8 {
			return .A8_UNORM
		}
	} else if pf.flags & DDPF_BUMPDUDV != 0 {
		switch pf.rgb_bit_count {
		case 32:
			if is_bit_mask(pf, 0x000000ff, 0x0000ff00, 0x00ff0000, 0xff000000) {
				return .R8G8B8A8_SNORM
			}
			if is_bit_mask(pf, 0x0000ffff, 0xffff0000, 0, 0) {
				return .R16G16_SNORM
			}
		case 16:
			if is_bit_mask(pf, 0x00ff, 0xff00, 0, 0) {
				return .R8G8_SNORM
			}
		}
	} else if pf.flags & DDPF_FOURCC != 0 {
		switch pf.four_cc {
		case make_four_cc("DXT1"):
			return .BC1_UNORM
		case make_four_cc("DXT3"):
			return .BC2_UNORM
		case make_four_cc("DXT5"):
			return .BC3_UNORM

		// Pre-multiplied alpha isn't directly expressible in DXGI, but the bits are the
		// same as the corresponding BC format, so DirectXTK12 maps them across.
		case make_four_cc("DXT2"):
			return .BC2_UNORM
		case make_four_cc("DXT4"):
			return .BC3_UNORM

		case make_four_cc("ATI1"), make_four_cc("BC4U"):
			return .BC4_UNORM
		case make_four_cc("BC4S"):
			return .BC4_SNORM

		case make_four_cc("ATI2"), make_four_cc("BC5U"):
			return .BC5_UNORM
		case make_four_cc("BC5S"):
			return .BC5_SNORM

		// BC6H and BC7 are always written with the "DX10" extended header.

		// D3DFORMAT enum values written into the FourCC field by D3DX.
		case 36:
			return .R16G16B16A16_UNORM
		case 110:
			return .R16G16B16A16_SNORM
		case 111:
			return .R16_FLOAT
		case 112:
			return .R16G16_FLOAT
		case 113:
			return .R16G16B16A16_FLOAT
		case 114:
			return .R32_FLOAT
		case 115:
			return .R32G32_FLOAT
		case 116:
			return .R32G32B32A32_FLOAT
		}
	}

	return .UNKNOWN
}
