// PROVENANCE: hand-written from the DDS file-format documentation (Microsoft "DDS
// Programming Guide" / "Reference for DDS"), using DirectXTK12's DDSTextureLoader.cpp and
// ResourceUploadBatch.cpp (MIT license, https://github.com/microsoft/DirectXTK12) as the
// reference implementation for the legacy-format mapping and the subresource upload flow.
// This replaces DirectX::CreateDDSTextureFromFileEx, which the C++ demos call via
// TextureLib — nothing in Odin's core:/vendor: reads DDS.
//
// Deliberately partial: only the formats the book's textures actually use are mapped
// (BC1/BC2/BC3 via legacy FourCC, BC4/BC5, the DX10 extended header, and 32-bit
// BGRA/BGRX/RGBA masks). Unknown formats fail loudly with the header fields in the
// message — extend the mapping when a new chapter's textures need it.
package common

import "core:fmt"
import "core:mem"
import "core:os"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

// "DDS " little-endian.
@(private = "file")
DDS_MAGIC :: u32(0x20534444)

// DDS_PIXELFORMAT flags.
@(private = "file") DDPF_ALPHAPIXELS :: u32(0x1)
@(private = "file") DDPF_FOURCC :: u32(0x4)
@(private = "file") DDPF_RGB :: u32(0x40)

// dwCaps2 cubemap bits.
@(private = "file") DDSCAPS2_CUBEMAP :: u32(0x200)
@(private = "file") DDSCAPS2_CUBEMAP_ALLFACES :: u32(0xfc00)

@(private = "file")
DDS_Pixel_Format :: struct #packed {
	size:          u32,
	flags:         u32,
	four_cc:       u32,
	rgb_bit_count: u32,
	r_bit_mask:    u32,
	g_bit_mask:    u32,
	b_bit_mask:    u32,
	a_bit_mask:    u32,
}

@(private = "file")
DDS_Header :: struct #packed {
	size:                 u32, // must be 124
	flags:                u32,
	height:               u32,
	width:                u32,
	pitch_or_linear_size: u32,
	depth:                u32,
	mip_map_count:        u32,
	reserved1:            [11]u32,
	ddspf:                DDS_Pixel_Format,
	caps:                 u32,
	caps2:                u32,
	caps3:                u32,
	caps4:                u32,
	reserved2:            u32,
}

#assert(size_of(DDS_Header) == 124)

// Present only when ddspf.four_cc == "DX10".
@(private = "file")
DDS_Header_DXT10 :: struct #packed {
	dxgi_format:        u32,
	resource_dimension: u32, // D3D12_RESOURCE_DIMENSION
	misc_flag:          u32, // 0x4 = TEXTURECUBE
	array_size:         u32,
	misc_flags2:        u32,
}

@(private = "file")
four_cc :: proc(s: string) -> u32 {
	assert(len(s) == 4)
	return u32(s[0]) | u32(s[1]) << 8 | u32(s[2]) << 16 | u32(s[3]) << 24
}

// C++: GetDXGIFormat (DDSTextureLoader.cpp), reduced to the book's formats.
@(private = "file")
dds_to_dxgi_format :: proc(pf: DDS_Pixel_Format, filename: string) -> dxgi.FORMAT {
	if pf.flags & DDPF_FOURCC != 0 {
		switch pf.four_cc {
		case four_cc("DXT1"):
			return .BC1_UNORM
		case four_cc("DXT2"), four_cc("DXT3"):
			return .BC2_UNORM
		case four_cc("DXT4"), four_cc("DXT5"):
			return .BC3_UNORM
		case four_cc("ATI1"), four_cc("BC4U"):
			return .BC4_UNORM
		case four_cc("ATI2"), four_cc("BC5U"):
			return .BC5_UNORM
		}
	} else if pf.flags & DDPF_RGB != 0 && pf.rgb_bit_count == 32 {
		switch {
		case pf.r_bit_mask == 0x00ff0000 && pf.a_bit_mask == 0xff000000:
			return .B8G8R8A8_UNORM
		case pf.r_bit_mask == 0x00ff0000 && pf.a_bit_mask == 0:
			return .B8G8R8X8_UNORM // legacy X8R8G8B8
		case pf.r_bit_mask == 0x000000ff:
			return .R8G8B8A8_UNORM
		}
	}

	report_error(
		fmt.tprintf(
			"%s: unsupported DDS pixel format (flags=%#x fourCC=%#x bits=%d masks=%#x/%#x/%#x/%#x) — extend dds_loader.odin",
			filename, pf.flags, pf.four_cc, pf.rgb_bit_count,
			pf.r_bit_mask, pf.g_bit_mask, pf.b_bit_mask, pf.a_bit_mask,
		),
	)
	os.exit(1)
}

// C++: GetSurfaceInfo (DDSTextureLoader.cpp) — bytes per row and number of rows for one
// mip surface. Block-compressed formats store 4x4 texel blocks (8 or 16 bytes each) and
// round dimensions up; everything else here is 32 bits per pixel.
@(private = "file")
surface_info :: proc(width, height: u32, format: dxgi.FORMAT) -> (row_bytes, num_rows: u32) {
	#partial switch format {
	case .BC1_UNORM, .BC4_UNORM:
		return max(1, (width + 3) / 4) * 8, max(1, (height + 3) / 4)
	case .BC2_UNORM, .BC3_UNORM, .BC5_UNORM:
		return max(1, (width + 3) / 4) * 16, max(1, (height + 3) / 4)
	case:
		return (width * 32 + 7) / 8, height
	}
}

// C++: DirectX::CreateDDSTextureFromFileEx(device, uploadBatch, filename, ...) — parse
// the file, create the default-heap texture, and record the per-subresource copies on
// the batch (the upload intermediate is tracked and released after the batch's wait).
// The texture ends in PIXEL_SHADER_RESOURCE | NON_PIXEL_SHADER_RESOURCE, like DXTK12.
// The caller owns (and Releases) the returned resource.
create_dds_texture :: proc(
	batch: ^Resource_Upload_Batch,
	filename: string,
) -> (
	texture: ^d3d12.IResource,
	is_cube_map: bool,
) {
	data, err := os.read_entire_file(filename, context.allocator)
	if err != nil {
		// C++: filesystem::exists check + MessageBox in TextureLib::Init.
		report_error(fmt.tprintf("%s not found.", filename))
		os.exit(1)
	}
	defer delete(data)

	if len(data) < 4 + size_of(DDS_Header) || (^u32)(raw_data(data))^ != DDS_MAGIC {
		report_error(fmt.tprintf("%s: not a DDS file.", filename))
		os.exit(1)
	}

	header := (^DDS_Header)(raw_data(data[4:]))^
	if header.size != 124 || header.ddspf.size != 32 {
		report_error(fmt.tprintf("%s: corrupt DDS header.", filename))
		os.exit(1)
	}

	data_offset := u32(4 + size_of(DDS_Header))
	format: dxgi.FORMAT
	array_size := u32(1)

	if header.ddspf.flags & DDPF_FOURCC != 0 && header.ddspf.four_cc == four_cc("DX10") {
		if len(data) < int(data_offset) + size_of(DDS_Header_DXT10) {
			report_error(fmt.tprintf("%s: truncated DX10 header.", filename))
			os.exit(1)
		}
		dx10 := (^DDS_Header_DXT10)(raw_data(data[data_offset:]))^
		data_offset += size_of(DDS_Header_DXT10)

		format = dxgi.FORMAT(dx10.dxgi_format)
		array_size = max(1, dx10.array_size)
		if dx10.misc_flag & 0x4 != 0 { 	// DDS_RESOURCE_MISC_TEXTURECUBE
			is_cube_map = true
			array_size *= 6
		}
		if dx10.resource_dimension != u32(d3d12.RESOURCE_DIMENSION.TEXTURE2D) {
			report_error(fmt.tprintf("%s: only 2D DDS textures are supported.", filename))
			os.exit(1)
		}
	} else {
		format = dds_to_dxgi_format(header.ddspf, filename)
		if header.caps2 & DDSCAPS2_CUBEMAP != 0 {
			if header.caps2 & DDSCAPS2_CUBEMAP_ALLFACES != DDSCAPS2_CUBEMAP_ALLFACES {
				report_error(fmt.tprintf("%s: partial cubemaps are not supported.", filename))
				os.exit(1)
			}
			is_cube_map = true
			array_size = 6
		}
	}

	mip_count := max(1, header.mip_map_count) // 0 means "no mip field": one level

	// The GPU-resident texture, born in COPY_DEST (textures really are created in that
	// state — the id-1328 warning is buffer-specific).
	desc := d3d12.RESOURCE_DESC {
		Dimension = .TEXTURE2D,
		Alignment = 0,
		Width = u64(header.width),
		Height = header.height,
		DepthOrArraySize = u16(array_size),
		MipLevels = u16(mip_count),
		Format = format,
		SampleDesc = {Count = 1, Quality = 0},
		Layout = .UNKNOWN,
		Flags = {},
	}
	heap_default := d3d12.HEAP_PROPERTIES {
		Type = .DEFAULT,
	}
	hr_panic(
		batch.device->CreateCommittedResource(
			&heap_default,
			{},
			&desc,
			{.COPY_DEST},
			nil,
			d3d12.IResource_UUID,
			ptr(&texture),
		),
		"CreateCommittedResource(DDS texture)",
	)

	// Ask the device how the upload heap must be laid out: per-subresource offsets and
	// 256-byte-aligned row pitches (D3D12_TEXTURE_DATA_PITCH_ALIGNMENT).
	num_subresources := mip_count * array_size
	layouts := make([]d3d12.PLACED_SUBRESOURCE_FOOTPRINT, num_subresources, context.temp_allocator)
	num_rows := make([]u32, num_subresources, context.temp_allocator)
	row_sizes := make([]u64, num_subresources, context.temp_allocator)
	total_bytes: u64
	batch.device->GetCopyableFootprints(
		&desc,
		0,
		num_subresources,
		0,
		raw_data(layouts),
		raw_data(num_rows),
		raw_data(row_sizes),
		&total_bytes,
	)

	// The upload-heap intermediate the CPU fills.
	upload: ^d3d12.IResource
	heap_upload := d3d12.HEAP_PROPERTIES {
		Type = .UPLOAD,
	}
	upload_desc := buffer_desc(total_bytes)
	hr_panic(
		batch.device->CreateCommittedResource(
			&heap_upload,
			{},
			&upload_desc,
			d3d12.RESOURCE_STATE_GENERIC_READ,
			nil,
			d3d12.IResource_UUID,
			ptr(&upload),
		),
		"CreateCommittedResource(DDS upload intermediate)",
	)

	mapped: rawptr
	hr_panic(upload->Map(0, nil, &mapped), "Map(DDS upload intermediate)")

	// Copy each subresource, row by row: the file packs rows tightly, the upload heap
	// wants them at the footprint's RowPitch. Subresource order (all mips of face 0,
	// then face 1, ...) matches the DDS file layout.
	src_offset := int(data_offset)
	for slice_idx in 0 ..< array_size {
		w, h := header.width, header.height
		for mip in 0 ..< mip_count {
			sub := slice_idx * mip_count + mip
			src_row_bytes, src_num_rows := surface_info(w, h, format)

			if src_offset + int(src_row_bytes) * int(src_num_rows) > len(data) {
				report_error(fmt.tprintf("%s: file too small for its header (truncated?).", filename))
				os.exit(1)
			}
			assert(u64(src_row_bytes) == row_sizes[sub])
			assert(src_num_rows == num_rows[sub])

			dst := uintptr(mapped) + uintptr(layouts[sub].Offset)
			dst_pitch := int(layouts[sub].Footprint.RowPitch)
			for row in 0 ..< int(src_num_rows) {
				mem.copy(
					rawptr(dst + uintptr(row * dst_pitch)),
					raw_data(data[src_offset + row * int(src_row_bytes):]),
					int(src_row_bytes),
				)
			}
			src_offset += int(src_row_bytes) * int(src_num_rows)

			w = max(1, w / 2)
			h = max(1, h / 2)
		}
	}

	upload->Unmap(0, nil)
	append(&batch.tracked, upload)

	// Record one GPU copy per subresource.
	for sub in 0 ..< num_subresources {
		dst_loc := d3d12.TEXTURE_COPY_LOCATION {
			pResource = texture,
			Type      = .SUBRESOURCE_INDEX,
		}
		dst_loc.SubresourceIndex = sub

		src_loc := d3d12.TEXTURE_COPY_LOCATION {
			pResource = upload,
			Type      = .PLACED_FOOTPRINT,
		}
		src_loc.PlacedFootprint = layouts[sub]

		batch.cmd_list->CopyTextureRegion(&dst_loc, 0, 0, 0, &src_loc, nil)
	}

	// C++: DDS_LOADER_DEFAULT leaves the texture in the combined shader-resource state.
	barrier := transition_barrier(
		texture,
		{.COPY_DEST},
		{.PIXEL_SHADER_RESOURCE, .NON_PIXEL_SHADER_RESOURCE},
	)
	batch.cmd_list->ResourceBarrier(1, &barrier)

	return
}
