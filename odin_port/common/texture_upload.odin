// PROVENANCE: the D3D12 half of DirectXTK12's DDS texture loading (MIT license,
// https://github.com/microsoft/DirectXTK12) — `CreateDDSTextureFromFileEx` in
// `Src/DDSTextureLoader.cpp` plus the texture path of `Src/ResourceUploadBatch.cpp`.
//
// DirectXTK12 splits this two ways, and so do we:
//
//   LoadDDSTextureFromFile   -> parse the file, describe the subresources   -> ../dds
//   CreateDDSTextureFromFile -> the above, then create + upload the texture -> here
//
// Ours splits harder than theirs: DirectXTK12's Load* still takes an ID3D12Device
// because it creates the resource, whereas `dds` is pure — no device, no D3D12 types
// beyond `dxgi.FORMAT`. That is what lets the parser be unit-tested without a GPU
// (`odin test odin_port/dds`); everything below is the part that can't be.
package common

import "core:fmt"
import "core:mem"
import "core:os"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"
import "../dds"

// C++: DirectX::CreateDDSTextureFromFileEx(device, uploadBatch, filename, ...).
//
// Parses the DDS, creates the default-heap texture, and records the per-subresource
// copies on the batch (the upload intermediate is tracked and released after the batch's
// wait). The texture ends in PIXEL_SHADER_RESOURCE | NON_PIXEL_SHADER_RESOURCE, matching
// DirectXTK12's DDS_LOADER_DEFAULT. The caller owns (and Releases) the returned resource.
//
// Fail-fast on bad input, per the port's convention — the parser returns errors, this
// layer decides they're fatal.
create_dds_texture :: proc(
	batch: ^Resource_Upload_Batch,
	filename: string,
) -> (
	texture: ^d3d12.IResource,
	is_cube_map: bool,
) {
	data, read_err := os.read_entire_file(filename, context.allocator)
	if read_err != nil {
		// C++: the filesystem::exists check + MessageBox in TextureLib::Init.
		report_error(fmt.tprintf("%s not found.", filename))
		os.exit(1)
	}
	defer delete(data)

	info, subresources, err := dds.parse(data, context.temp_allocator)
	if err != .None {
		report_error(dds_error_message(filename, info, err))
		os.exit(1)
	}

	// The GPU-resident texture, born in COPY_DEST. (Unlike buffers, textures really are
	// created in that state — this is why DDS uploads emit no id-1328 warnings.)
	desc := d3d12.RESOURCE_DESC {
		Dimension = .TEXTURE2D,
		Alignment = 0,
		Width = u64(info.width),
		Height = info.height,
		DepthOrArraySize = u16(info.array_size),
		MipLevels = u16(info.mip_levels),
		// `dds.Format` is DXGI-numbered on purpose — the DDS DX10 header stores raw
		// DXGI_FORMAT values — so this is a plain cast, not a lookup. The dds package
		// deliberately doesn't import dxgi (it has to build on non-Windows), and
		// dds/format_dxgi_test.odin asserts the two enums agree value for value.
		Format = dxgi.FORMAT(info.format),
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
	// 256-byte-aligned row pitches (D3D12_TEXTURE_DATA_PITCH_ALIGNMENT). The file's rows
	// are tightly packed, so they must be re-pitched row by row on the way in.
	count := u32(len(subresources))
	layouts := make([]d3d12.PLACED_SUBRESOURCE_FOOTPRINT, count, context.temp_allocator)
	num_rows := make([]u32, count, context.temp_allocator)
	row_sizes := make([]u64, count, context.temp_allocator)
	total_bytes: u64
	batch.device->GetCopyableFootprints(
		&desc,
		0,
		count,
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

	for sub, i in subresources {
		// Cross-check the parser against the device: if these ever disagree, the pitch
		// math is wrong and the texture would upload skewed.
		assert(u64(sub.row_pitch) == row_sizes[i], "DDS row pitch disagrees with GetCopyableFootprints")
		assert(sub.num_rows == num_rows[i], "DDS row count disagrees with GetCopyableFootprints")

		dst := uintptr(mapped) + uintptr(layouts[i].Offset)
		dst_pitch := int(layouts[i].Footprint.RowPitch)
		for row in 0 ..< int(sub.num_rows) {
			mem.copy(
				rawptr(dst + uintptr(row * dst_pitch)),
				raw_data(data[int(sub.offset) + row * int(sub.row_pitch):]),
				int(sub.row_pitch),
			)
		}
	}

	upload->Unmap(0, nil)
	append(&batch.tracked, upload)

	// Record one GPU copy per subresource.
	for i in 0 ..< count {
		dst_loc := d3d12.TEXTURE_COPY_LOCATION {
			pResource = texture,
			Type      = .SUBRESOURCE_INDEX,
		}
		dst_loc.SubresourceIndex = i

		src_loc := d3d12.TEXTURE_COPY_LOCATION {
			pResource = upload,
			Type      = .PLACED_FOOTPRINT,
		}
		src_loc.PlacedFootprint = layouts[i]

		batch.cmd_list->CopyTextureRegion(&dst_loc, 0, 0, 0, &src_loc, nil)
	}

	barrier := transition_barrier(
		texture,
		{.COPY_DEST},
		{.PIXEL_SHADER_RESOURCE, .NON_PIXEL_SHADER_RESOURCE},
	)
	batch.cmd_list->ResourceBarrier(1, &barrier)

	return texture, info.is_cube_map
}

// C++: CreateTextureFromMemory for one uncompressed 2D subresource. Chapter 13 uses
// this to seed the three R32_FLOAT wave-simulation textures with zeroes.
create_texture_2d_from_memory :: proc(
	batch: ^Resource_Upload_Batch,
	width, height: u32,
	format: dxgi.FORMAT,
	data: rawptr,
	row_pitch: u32,
	after_state: d3d12.RESOURCE_STATES,
	flags: d3d12.RESOURCE_FLAGS = {},
) -> ^d3d12.IResource {
	desc := d3d12.RESOURCE_DESC {
		Dimension = .TEXTURE2D,
		Width = u64(width),
		Height = height,
		DepthOrArraySize = 1,
		MipLevels = 1,
		Format = format,
		SampleDesc = {Count = 1},
		Layout = .UNKNOWN,
		Flags = flags,
	}
	default_heap := d3d12.HEAP_PROPERTIES{Type = .DEFAULT}
	texture: ^d3d12.IResource
	hr_panic(
		batch.device->CreateCommittedResource(
			&default_heap, {}, &desc, {.COPY_DEST}, nil,
			d3d12.IResource_UUID, ptr(&texture),
		),
		"CreateCommittedResource(texture from memory)",
	)

	layout: d3d12.PLACED_SUBRESOURCE_FOOTPRINT
	num_rows: u32
	row_size: u64
	total_bytes: u64
	batch.device->GetCopyableFootprints(
		&desc, 0, 1, 0, &layout, &num_rows, &row_size, &total_bytes,
	)
	assert(row_size == u64(row_pitch))
	assert(num_rows == height)

	upload_desc := buffer_desc(total_bytes)
	upload_heap := d3d12.HEAP_PROPERTIES{Type = .UPLOAD}
	upload: ^d3d12.IResource
	hr_panic(
		batch.device->CreateCommittedResource(
			&upload_heap, {}, &upload_desc, d3d12.RESOURCE_STATE_GENERIC_READ, nil,
			d3d12.IResource_UUID, ptr(&upload),
		),
		"CreateCommittedResource(texture upload)",
	)
	mapped: rawptr
	hr_panic(upload->Map(0, nil, &mapped), "Map(texture upload)")
	for row in 0 ..< int(height) {
		dst := rawptr(uintptr(mapped) + uintptr(row * int(layout.Footprint.RowPitch)))
		src := rawptr(uintptr(data) + uintptr(row * int(row_pitch)))
		mem.copy(dst, src, int(row_pitch))
	}
	upload->Unmap(0, nil)
	append(&batch.tracked, upload)

	dst_loc := d3d12.TEXTURE_COPY_LOCATION{pResource = texture, Type = .SUBRESOURCE_INDEX}
	dst_loc.SubresourceIndex = 0
	src_loc := d3d12.TEXTURE_COPY_LOCATION{pResource = upload, Type = .PLACED_FOOTPRINT}
	src_loc.PlacedFootprint = layout
	batch.cmd_list->CopyTextureRegion(&dst_loc, 0, 0, 0, &src_loc, nil)
	barrier := transition_barrier(texture, {.COPY_DEST}, after_state)
	batch.cmd_list->ResourceBarrier(1, &barrier)
	return texture
}

// Turn a parser error into something actionable — for an unmapped format that means
// printing the header fields, so the reader knows exactly what to add to
// `dds/format.odin` (and `dds/README.md` says which ones are deliberately absent).
@(private = "file")
dds_error_message :: proc(filename: string, info: dds.Texture_Info, err: dds.Error) -> string {
	pf := info.pixel_format
	if err == .Unsupported_Format {
		return fmt.tprintf(
			"%s: unsupported DDS pixel format (flags=%#x fourCC=%#x bits=%d masks=%#x/%#x/%#x/%#x) — see odin_port/dds/README.md",
			filename, pf.flags, pf.four_cc, pf.rgb_bit_count,
			pf.r_bit_mask, pf.g_bit_mask, pf.b_bit_mask, pf.a_bit_mask,
		)
	}
	return fmt.tprintf("%s: cannot load DDS (%v)", filename, err)
}
