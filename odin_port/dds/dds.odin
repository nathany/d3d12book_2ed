// A DDS file parser — pure, no Direct3D device, no GPU, no I/O policy.
//
// This is the "load" half of DirectXTK12's DDSTextureLoader split (see README.md):
// `parse` turns DDS bytes into a `Texture_Info` plus the per-subresource layout, and the
// caller decides what to do with it. The D3D12 half — creating the resource and pushing
// the bits through an upload heap — lives in `common/texture_upload.odin`, which is what
// keeps this package testable without a GPU.
//
// Errors are returned, never fatal: the demos' fail-fast policy (report_error + exit)
// belongs to the caller, not to a parser that tests need to drive with malformed input.
package dds

import "core:mem"

// "DDS " little-endian.
DDS_MAGIC :: u32(0x20534444)

Error :: enum {
	None = 0,
	Too_Small, //             fewer bytes than magic + header
	Bad_Magic, //             missing the "DDS " signature
	Bad_Header, //            header.size or ddspf.size wrong
	Truncated_Dx10_Header, // FourCC said DX10 but the extended header isn't there
	Unsupported_Format, //    no format mapping (see README.md); info.pixel_format says what
	Unsupported_Dimension, // 1D/3D/volume textures
	Partial_Cube_Map, //      cubemap missing some of its six faces
	Data_Truncated, //        header describes more surface bytes than the file holds
}

// dwCaps2 cubemap bits (`DDS.h`).
@(private) DDS_CUBEMAP :: u32(0x200)
@(private) DDS_CUBEMAP_ALLFACES :: u32(0xfc00) // the six face bits, without DDS_CUBEMAP
@(private) DDS_FLAGS_VOLUME :: u32(0x200000)

// C++: DDS_HEADER (`DDS.h`).
@(private)
Header :: struct #packed {
	size:                 u32,
	flags:                u32,
	height:               u32,
	width:                u32,
	pitch_or_linear_size: u32,
	depth:                u32,
	mip_map_count:        u32,
	reserved1:            [11]u32,
	ddspf:                Pixel_Format,
	caps:                 u32,
	caps2:                u32,
	caps3:                u32,
	caps4:                u32,
	reserved2:            u32,
}

#assert(size_of(Header) == 124)

// C++: DDS_HEADER_DXT10 (`DDS.h`).
@(private)
Header_Dxt10 :: struct #packed {
	dxgi_format:        u32,
	resource_dimension: u32, // D3D10_RESOURCE_DIMENSION: 3 == TEXTURE2D
	misc_flag:          u32, // 0x4 == TEXTURECUBE
	array_size:         u32,
	misc_flags2:        u32,
}

#assert(size_of(Header_Dxt10) == 20)

@(private) RESOURCE_DIMENSION_TEXTURE2D :: u32(3)
@(private) RESOURCE_MISC_TEXTURECUBE :: u32(0x4)

// What the header describes. `array_size` already includes the ×6 for cubemaps, so
// `array_size * mip_levels` is the subresource count in D3D12's terms.
Texture_Info :: struct {
	width:        u32,
	height:       u32,
	mip_levels:   u32,
	array_size:   u32,
	format:       Format,
	is_cube_map:  bool,

	// Byte offset of the first surface within the DDS buffer (128, or 148 with a DX10
	// header).
	data_offset:  u32,

	// The raw pixel-format block, kept so a caller can report exactly what it choked on
	// when `parse_info` returns `.Unsupported_Format`.
	pixel_format: Pixel_Format,
}

// One surface: a single mip of a single array slice.
Subresource :: struct {
	offset:      u32, // byte offset into the DDS buffer
	size:        u32, // total bytes of this surface
	row_pitch:   u32, // TIGHT pitch as stored (not D3D12's 256-aligned upload pitch)
	num_rows:    u32, // rows of pixels, or rows of 4x4 blocks when compressed
	width:       u32,
	height:      u32,
	mip:         u32,
	array_slice: u32,
}

// C++: LoaderHelpers::LoadTextureDataFromMemory + the header validation at the top of
// CreateDDSTextureFromMemoryEx, fused. Reads the header only — no surface walking, no
// allocation.
parse_info :: proc(data: []byte) -> (info: Texture_Info, err: Error) {
	if len(data) < size_of(u32) + size_of(Header) {
		return {}, .Too_Small
	}

	magic: u32
	mem.copy(&magic, raw_data(data), size_of(u32))
	if magic != DDS_MAGIC {
		return {}, .Bad_Magic
	}

	// Copied rather than pointer-cast: the file layout is packed, and a caller may hand
	// us a slice with any alignment.
	header: Header
	mem.copy(&header, raw_data(data[size_of(u32):]), size_of(Header))

	if header.size != size_of(Header) || header.ddspf.size != size_of(Pixel_Format) {
		return {}, .Bad_Header
	}

	info.width = header.width
	info.height = header.height
	// A mip_map_count of 0 means "one level", not "no levels" — ~10% of the book's files
	// are written this way.
	info.mip_levels = max(u32(1), header.mip_map_count)
	info.array_size = 1
	info.pixel_format = header.ddspf
	info.data_offset = size_of(u32) + size_of(Header)

	if header.flags & DDS_FLAGS_VOLUME != 0 || header.caps2 & DDS_FLAGS_VOLUME != 0 {
		return info, .Unsupported_Dimension
	}

	if header.ddspf.flags & DDPF_FOURCC != 0 && header.ddspf.four_cc == FOURCC_DX10 {
		if len(data) < int(info.data_offset) + size_of(Header_Dxt10) {
			return info, .Truncated_Dx10_Header
		}
		dx10: Header_Dxt10
		mem.copy(&dx10, raw_data(data[info.data_offset:]), size_of(Header_Dxt10))
		info.data_offset += size_of(Header_Dxt10)

		info.format = Format(dx10.dxgi_format)
		info.array_size = max(u32(1), dx10.array_size)
		if dx10.misc_flag & RESOURCE_MISC_TEXTURECUBE != 0 {
			info.is_cube_map = true
			info.array_size *= 6
		}
		if dx10.resource_dimension != RESOURCE_DIMENSION_TEXTURE2D {
			return info, .Unsupported_Dimension
		}
	} else {
		info.format = format_from_pixel_format(header.ddspf)
		if header.caps2 & DDS_CUBEMAP != 0 {
			// We require all six faces, like DirectXTK12: D3D12 has no partial-cube
			// resource to create.
			if header.caps2 & DDS_CUBEMAP_ALLFACES != DDS_CUBEMAP_ALLFACES {
				return info, .Partial_Cube_Map
			}
			info.is_cube_map = true
			info.array_size = 6
		}
	}

	if info.format == .UNKNOWN || bits_per_pixel(info.format) == 0 {
		return info, .Unsupported_Format
	}

	return info, .None
}

// Number of surfaces the file contains — D3D12's subresource count for this resource.
subresource_count :: proc(info: Texture_Info) -> u32 {
	return info.array_size * info.mip_levels
}

// C++: LoaderHelpers::FillInitData — walk every surface, computing offsets and pitches.
// Fills `dst` (which must hold `subresource_count(info)` entries) so the caller controls
// allocation; `parse` below is the allocating convenience wrapper.
//
// Ordering matches DirectXTK12 and D3D12's own subresource indexing: array slice outer,
// mip inner, so index = mip + array_slice * mip_levels.
parse_subresources :: proc(
	info: Texture_Info,
	data: []byte,
	dst: []Subresource,
) -> Error {
	count := subresource_count(info)
	assert(len(dst) >= int(count), "dst too small; use subresource_count(info)")

	offset := info.data_offset
	i := 0
	for slice_idx in 0 ..< info.array_size {
		w, h := info.width, info.height
		for mip in 0 ..< info.mip_levels {
			num_bytes, row_bytes, num_rows, ok := surface_info(w, h, info.format)
			if !ok {
				return .Unsupported_Format
			}

			if int(offset) + int(num_bytes) > len(data) {
				return .Data_Truncated
			}

			dst[i] = Subresource {
				offset      = offset,
				size        = num_bytes,
				row_pitch   = row_bytes,
				num_rows    = num_rows,
				width       = w,
				height      = h,
				mip         = mip,
				array_slice = slice_idx,
			}
			i += 1
			offset += num_bytes

			w = max(u32(1), w / 2)
			h = max(u32(1), h / 2)
		}
	}

	return .None
}

// Convenience: parse header and surfaces in one call. The returned slice is owned by the
// caller (`delete` it, or pass a temp allocator).
parse :: proc(
	data: []byte,
	allocator := context.allocator,
) -> (
	info: Texture_Info,
	subresources: []Subresource,
	err: Error,
) {
	// Not `or_return`: on failure parse_info still fills in `pixel_format` for the
	// caller's error message, and an early `or_return` would discard it.
	info, err = parse_info(data)
	if err != .None {
		return info, nil, err
	}

	subresources = make([]Subresource, subresource_count(info), allocator)
	if serr := parse_subresources(info, data, subresources); serr != .None {
		delete(subresources, allocator)
		return info, nil, serr
	}
	return info, subresources, .None
}
