// Portable unit tests: every fixture is synthesized in memory, so this file needs no
// assets, no GPU, and no particular working directory. Tests that read real .dds files
// live in dds_files_test.odin.
//
//   odin test odin_port/dds
package dds

import "core:mem"
import "core:testing"

@(test)
test_layout_arithmetic_regressions :: proc(t: ^testing.T) {
	// Previously width*bpp wrapped to zero before division by eight.
	n, row, _, ok := surface_info(0x08000000, 1, .R8G8B8A8_UNORM)
	testing.expect(t, ok)
	testing.expect_value(t, row, u32(0x20000000))
	testing.expect_value(t, n, u32(0x20000000))
	for format in ([?]Format{.BC1_UNORM, .BC7_UNORM, .R32G32B32A32_FLOAT}) {
		_, _, _, valid := surface_info(max(u32), max(u32), format)
		testing.expectf(t, !valid, "%v: oversized surface must fail", format)
	}
	// Header-only checks avoid asking the unfixed parser to allocate attacker counts.
	for array_size in ([?]u32{0, 0x80000000}) {
		buf := make_dds_dx10(2, 2, 2, .R8G8B8A8_UNORM, array_size,
			payload_bytes = 4, allocator = context.temp_allocator)
		_, err := parse_info(buf)
		expected := array_size == 0 ? Error.Invalid_Layout : Error.Size_Overflow
		testing.expect_value(t, err, expected)
	}
	buf := make_dds_dx10(4, 4, 1, .BC1_UNORM, 0x80000000,
		misc_flag = RESOURCE_MISC_TEXTURECUBE, allocator = context.temp_allocator)
	_, err := parse_info(buf)
	testing.expectf(t, err != .None, "cube-face expansion wrapped")
}

@(test)
test_layout_boundaries :: proc(t: ^testing.T) {
	// A surface at the u32 boundary is representable; its header/array may not be.
	n, row, rows, ok := surface_info(max(u32), 1, .R8_UNORM)
	testing.expect(t, ok)
	testing.expect_value(t, n, max(u32))
	testing.expect_value(t, row, max(u32))
	testing.expect_value(t, rows, u32(1))
	_, _, _, ok = surface_info(max(u32), 2, .R8_UNORM)
	testing.expect(t, !ok)
	_, _, _, ok = surface_info(0, 1, .BC1_UNORM)
	testing.expect(t, !ok)
	_, _, _, ok = surface_info(1, 0, .R8_UNORM)
	testing.expect(t, !ok)
	// BC rounding must add three in u64, even when its final pitch fits u32.
	n, row, rows, ok = surface_info(0x7ffffffc, 1, .BC1_UNORM)
	testing.expect(t, ok)
	testing.expect_value(t, n, u32(0xfffffff8))
	testing.expect_value(t, row, n)
	testing.expect_value(t, rows, u32(1))
	testing.expect_value(t, subresource_count({array_size = max(u32), mip_levels = max(u32)}),
		u64(0xfffffffe00000001))

	// Exercise offsets and whole-array accumulation without allocating multi-GB files.
	info := Texture_Info{width = 1, height = 1, mip_levels = 1, array_size = 1,
		format = .R8_UNORM, data_offset = max(u32) - 1}
	size, err := layout_size(info)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, size, max(u32))
	info.data_offset = max(u32)
	_, err = layout_size(info)
	testing.expect_value(t, err, Error.Size_Overflow)
}

@(test)
test_layout_rejects_caller_metadata :: proc(t: ^testing.T) {
	invalid := [?]Texture_Info{
		{width = 0, height = 4, mip_levels = 1, array_size = 1, format = .BC1_UNORM},
		{width = 4, height = 0, mip_levels = 1, array_size = 1, format = .BC1_UNORM},
		{width = 4, height = 4, mip_levels = 0, array_size = 1, format = .BC1_UNORM},
		{width = 4, height = 4, mip_levels = 1, array_size = 0, format = .BC1_UNORM},
		{width = 4, height = 4, mip_levels = 4, array_size = 1, format = .BC1_UNORM},
		{width = 4, height = 2, mip_levels = 1, array_size = 6, format = .BC1_UNORM, is_cube_map = true},
		{width = 4, height = 4, mip_levels = 1, array_size = 7, format = .BC1_UNORM, is_cube_map = true},
	}
	for info in invalid {
		_, err := layout_size(info)
		testing.expect_value(t, err, Error.Invalid_Layout)
		testing.expect_value(t, parse_subresources(info, nil, nil), Error.Invalid_Layout)
	}
	overflow := [?]Texture_Info{
		// Valid mip chain, overflowing subresource count.
		{width = 2, height = 2, mip_levels = 2, array_size = 0x80000000, format = .R8_UNORM},
		// Each surface fits, but the array or mip sum does not.
		{width = 0x80000000, height = 1, mip_levels = 1, array_size = 2, format = .R8_UNORM},
		{width = max(u32), height = 1, mip_levels = 2, array_size = 1, format = .R8_UNORM},
		{width = 1, height = 1, mip_levels = 1, array_size = 1, format = .R8_UNORM, data_offset = max(u32)},
		// Would overflow u64 too if pitch*height were evaluated before bounding pitch.
		{width = max(u32), height = max(u32), mip_levels = 1, array_size = 1, format = .R32G32B32A32_FLOAT},
	}
	for info in overflow {
		_, err := layout_size(info)
		testing.expect_value(t, err, Error.Size_Overflow)
		testing.expect_value(t, parse_subresources(info, nil, nil), Error.Size_Overflow)
	}
}

@(test)
test_parse_rejects_before_allocation :: proc(t: ^testing.T) {
	// panic_allocator proves metadata/truncation rejection happens before allocation.
	for array_size in ([?]u32{0, 0x80000000}) {
		buf := make_dds_dx10(2, 2, 2, .R8G8B8A8_UNORM, array_size,
			payload_bytes = 4, allocator = context.temp_allocator)
		_, subs, err := parse(buf, mem.panic_allocator())
		expected := array_size == 0 ? Error.Invalid_Layout : Error.Size_Overflow
		testing.expect_value(t, err, expected)
		testing.expect(t, subs == nil)
	}
	// The originally reported 1x1/two-mip panic is rejected as an impossible mip chain.
	original := make_dds_dx10(1, 1, 2, .R8G8B8A8_UNORM, 0x80000000,
		payload_bytes = 4, allocator = context.temp_allocator)
	_, _, original_err := parse(original, mem.panic_allocator())
	testing.expect_value(t, original_err, Error.Invalid_Layout)
	// Legal count but tiny payload: do not allocate billions of descriptors.
	buf := make_dds_dx10(1, 1, 1, .R8_UNORM, 0x80000000,
		payload_bytes = 1, allocator = context.temp_allocator)
	_, subs, err := parse(buf, mem.panic_allocator())
	testing.expect_value(t, err, Error.Data_Truncated)
	testing.expect(t, subs == nil)
	// Zero dimensions and cube expansion also fail through the allocating entry point.
	zero := make_dds(0, 4, 1, pf_four_cc("DXT1"), allocator = context.temp_allocator)
	_, _, err = parse(zero, mem.panic_allocator())
	testing.expect_value(t, err, Error.Invalid_Layout)
	cube := make_dds_dx10(4, 4, 1, .BC1_UNORM, 0x80000000,
		misc_flag = RESOURCE_MISC_TEXTURECUBE, allocator = context.temp_allocator)
	_, _, err = parse(cube, mem.panic_allocator())
	testing.expect_value(t, err, Error.Size_Overflow)
}

@(test)
test_parse_destination_and_allocator_failure :: proc(t: ^testing.T) {
	buf := make_dds(4, 4, 1, pf_four_cc("DXT1"), payload_bytes = 8, allocator = context.temp_allocator)
	info, err := parse_info(buf)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, parse_subresources(info, buf, nil), Error.Destination_Too_Small)
	_, subs, alloc_err := parse(buf, mem.nil_allocator())
	testing.expect_value(t, alloc_err, Error.Out_Of_Memory)
	testing.expect(t, subs == nil)
	// Exact-size success and a one-byte truncation exercise the same preflight bound.
	_, subs, err = parse(buf)
	defer delete(subs)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, len(subs), 1)
	_, _, err = parse(buf[:len(buf)-1], mem.panic_allocator())
	testing.expect_value(t, err, Error.Data_Truncated)
}

// ---------------------------------------------------------------------------
// Fixture builders
// ---------------------------------------------------------------------------

// Assemble a legacy (non-DX10) DDS byte buffer: magic + header + `payload` bytes.
@(private = "file")
make_dds :: proc(
	width, height, mip_count: u32,
	pf: Pixel_Format,
	caps2: u32 = 0,
	payload_bytes: int = 0,
	flags: u32 = 0,
	allocator := context.allocator,
) -> []byte {
	buf := make([]byte, size_of(u32) + size_of(Header) + payload_bytes, allocator)

	magic := DDS_MAGIC
	mem.copy(raw_data(buf), &magic, size_of(u32))

	header := Header {
		size          = size_of(Header),
		flags         = flags,
		height        = height,
		width         = width,
		mip_map_count = mip_count,
		ddspf         = pf,
		caps2         = caps2,
	}
	mem.copy(raw_data(buf[size_of(u32):]), &header, size_of(Header))
	return buf
}

// Assemble a DX10-extended DDS byte buffer.
@(private = "file")
make_dds_dx10 :: proc(
	width, height, mip_count: u32,
	format: Format,
	array_size: u32,
	misc_flag: u32 = 0,
	dimension: u32 = RESOURCE_DIMENSION_TEXTURE2D,
	payload_bytes: int = 0,
	truncate_dx10: bool = false,
	allocator := context.allocator,
) -> []byte {
	pf := Pixel_Format {
		size    = size_of(Pixel_Format),
		flags   = DDPF_FOURCC,
		four_cc = FOURCC_DX10,
	}
	head_size := size_of(u32) + size_of(Header)
	total := head_size + (truncate_dx10 ? 4 : size_of(Header_Dxt10) + payload_bytes)
	buf := make([]byte, total, allocator)

	magic := DDS_MAGIC
	mem.copy(raw_data(buf), &magic, size_of(u32))

	header := Header {
		size          = size_of(Header),
		height        = height,
		width         = width,
		mip_map_count = mip_count,
		ddspf         = pf,
	}
	mem.copy(raw_data(buf[size_of(u32):]), &header, size_of(Header))

	if !truncate_dx10 {
		dx10 := Header_Dxt10 {
			dxgi_format        = u32(format),
			resource_dimension = dimension,
			misc_flag          = misc_flag,
			array_size         = array_size,
		}
		mem.copy(raw_data(buf[head_size:]), &dx10, size_of(Header_Dxt10))
	}
	return buf
}

@(private = "file")
pf_four_cc :: proc(tag: string) -> Pixel_Format {
	return {size = size_of(Pixel_Format), flags = DDPF_FOURCC, four_cc = make_four_cc(tag)}
}

@(private = "file")
pf_rgb32 :: proc(r, g, b, a: u32) -> Pixel_Format {
	flags := DDPF_RGB | (a != 0 ? DDPF_ALPHAPIXELS : 0)
	return {
		size = size_of(Pixel_Format),
		flags = flags,
		rgb_bit_count = 32,
		r_bit_mask = r,
		g_bit_mask = g,
		b_bit_mask = b,
		a_bit_mask = a,
	}
}

// ---------------------------------------------------------------------------
// surface_info — the pitch math, where a mistake silently skews every texture
// ---------------------------------------------------------------------------

@(test)
test_surface_info_bc1 :: proc(t: ^testing.T) {
	// BC1: 8 bytes per 4x4 block.
	n, row, rows, ok := surface_info(8, 8, .BC1_UNORM)
	testing.expect(t, ok)
	testing.expect_value(t, row, u32(16)) // 2 blocks wide * 8
	testing.expect_value(t, rows, u32(2)) // 2 blocks high
	testing.expect_value(t, n, u32(32))

	// Sub-block mips still occupy a whole block — the classic off-by-a-mip bug.
	n, row, rows, ok = surface_info(1, 1, .BC1_UNORM)
	testing.expect(t, ok)
	testing.expect_value(t, row, u32(8))
	testing.expect_value(t, rows, u32(1))
	testing.expect_value(t, n, u32(8))

	// Non-multiple-of-4 rounds up.
	n, _, _, ok = surface_info(5, 5, .BC1_UNORM)
	testing.expect(t, ok)
	testing.expect_value(t, n, u32(2 * 8 * 2)) // 2x2 blocks
}

@(test)
test_surface_info_bc3_and_bc7 :: proc(t: ^testing.T) {
	// BC3 and BC7 are both 16 bytes per block. BC7 is the regression guard: an earlier
	// draft omitted it from the block table, so it fell through to the 32-bpp path and
	// computed an 8x-too-large pitch without erroring.
	for format in ([?]Format{.BC3_UNORM, .BC7_UNORM}) {
		n, row, rows, ok := surface_info(16, 16, format)
		testing.expectf(t, ok, "%v should be supported", format)
		testing.expect_value(t, row, u32(64)) // 4 blocks * 16
		testing.expect_value(t, rows, u32(4))
		testing.expect_value(t, n, u32(256))
		testing.expectf(t, is_compressed(format), "%v should be block-compressed", format)
	}
}

@(test)
test_surface_info_uncompressed :: proc(t: ^testing.T) {
	n, row, rows, ok := surface_info(4, 4, .B8G8R8A8_UNORM)
	testing.expect(t, ok)
	testing.expect_value(t, row, u32(16))
	testing.expect_value(t, rows, u32(4))
	testing.expect_value(t, n, u32(64))

	// 16-bpp path.
	_, row, _, ok = surface_info(4, 4, .B5G6R5_UNORM)
	testing.expect(t, ok)
	testing.expect_value(t, row, u32(8))
}

@(test)
test_surface_info_rejects_unknown :: proc(t: ^testing.T) {
	// Must fail rather than guess a stride.
	_, _, _, ok := surface_info(4, 4, .UNKNOWN)
	testing.expect(t, !ok)
	testing.expect_value(t, bits_per_pixel(.UNKNOWN), u32(0))
}

// ---------------------------------------------------------------------------
// Format mapping
// ---------------------------------------------------------------------------

@(test)
test_format_mapping_four_cc :: proc(t: ^testing.T) {
	testing.expect_value(t, format_from_pixel_format(pf_four_cc("DXT1")), Format.BC1_UNORM)
	testing.expect_value(t, format_from_pixel_format(pf_four_cc("DXT3")), Format.BC2_UNORM)
	testing.expect_value(t, format_from_pixel_format(pf_four_cc("DXT5")), Format.BC3_UNORM)
	// Pre-multiplied-alpha variants share the BC bits.
	testing.expect_value(t, format_from_pixel_format(pf_four_cc("DXT2")), Format.BC2_UNORM)
	testing.expect_value(t, format_from_pixel_format(pf_four_cc("DXT4")), Format.BC3_UNORM)
	testing.expect_value(t, format_from_pixel_format(pf_four_cc("ATI1")), Format.BC4_UNORM)
	testing.expect_value(t, format_from_pixel_format(pf_four_cc("ATI2")), Format.BC5_UNORM)
	testing.expect_value(t, format_from_pixel_format(pf_four_cc("ZZZZ")), Format.UNKNOWN)
}

@(test)
test_format_mapping_32bpp_masks :: proc(t: ^testing.T) {
	// The three the book's files actually use — note R and B swap between the first two.
	testing.expect_value(
		t,
		format_from_pixel_format(pf_rgb32(0x000000ff, 0x0000ff00, 0x00ff0000, 0xff000000)),
		Format.R8G8B8A8_UNORM,
	)
	testing.expect_value(
		t,
		format_from_pixel_format(pf_rgb32(0x00ff0000, 0x0000ff00, 0x000000ff, 0xff000000)),
		Format.B8G8R8A8_UNORM,
	)
	testing.expect_value(
		t,
		format_from_pixel_format(pf_rgb32(0x00ff0000, 0x0000ff00, 0x000000ff, 0)),
		Format.B8G8R8X8_UNORM,
	)
	// D3DFMT_X8B8G8R8 has no DXGI equivalent — must stay UNKNOWN, not fall back.
	testing.expect_value(
		t,
		format_from_pixel_format(pf_rgb32(0x000000ff, 0x0000ff00, 0x00ff0000, 0)),
		Format.UNKNOWN,
	)
}

// ---------------------------------------------------------------------------
// Header parsing
// ---------------------------------------------------------------------------

@(test)
test_parse_rejects_malformed :: proc(t: ^testing.T) {
	// Too small.
	short := make([]byte, 16, context.temp_allocator)
	_, err := parse_info(short)
	testing.expect_value(t, err, Error.Too_Small)

	// Right size, wrong magic.
	buf := make_dds(4, 4, 1, pf_four_cc("DXT1"), allocator = context.temp_allocator)
	buf[0] = 'X'
	_, err = parse_info(buf)
	testing.expect_value(t, err, Error.Bad_Magic)

	// Bad header size field.
	buf2 := make_dds(4, 4, 1, pf_four_cc("DXT1"), allocator = context.temp_allocator)
	bad := u32(99)
	mem.copy(raw_data(buf2[4:]), &bad, size_of(u32))
	_, err = parse_info(buf2)
	testing.expect_value(t, err, Error.Bad_Header)

	// Unknown pixel format reports the fields it saw rather than guessing.
	odd := pf_rgb32(0xdead0000, 0x0000beef, 0x000000ff, 0)
	buf3 := make_dds(4, 4, 1, odd, allocator = context.temp_allocator)
	info, err3 := parse_info(buf3)
	testing.expect_value(t, err3, Error.Unsupported_Format)
	testing.expect_value(t, info.pixel_format.r_bit_mask, u32(0xdead0000))

	// Truncated DX10 header.
	buf4 := make_dds_dx10(4, 4, 1, .BC7_UNORM, 1, truncate_dx10 = true, allocator = context.temp_allocator)
	_, err4 := parse_info(buf4)
	testing.expect_value(t, err4, Error.Truncated_Dx10_Header)
}

@(test)
test_parse_mip_count_zero_means_one :: proc(t: ^testing.T) {
	// ~10% of the book's DDS files write 0 here; it means one level, not zero.
	buf := make_dds(4, 4, 0, pf_four_cc("DXT1"), payload_bytes = 8, allocator = context.temp_allocator)
	info, err := parse_info(buf)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, info.mip_levels, u32(1))
	testing.expect_value(t, subresource_count(info), u64(1))
}

@(test)
test_parse_cube_map :: proc(t: ^testing.T) {
	CUBE_ALL :: u32(0x200) | u32(0xfc00)

	// All six faces -> array_size 6.
	buf := make_dds(
		4, 4, 1, pf_four_cc("DXT1"),
		caps2 = CUBE_ALL, payload_bytes = 8 * 6,
		allocator = context.temp_allocator,
	)
	info, err := parse_info(buf)
	testing.expect_value(t, err, Error.None)
	testing.expect(t, info.is_cube_map)
	testing.expect_value(t, info.array_size, u32(6))
	testing.expect_value(t, subresource_count(info), u64(6))

	// Missing faces must be rejected, not silently treated as a full cube.
	partial := make_dds(
		4, 4, 1, pf_four_cc("DXT1"),
		caps2 = u32(0x200) | u32(0x400), // CUBEMAP | +X only
		allocator = context.temp_allocator,
	)
	_, err = parse_info(partial)
	testing.expect_value(t, err, Error.Partial_Cube_Map)
}

@(test)
test_parse_dx10_array :: proc(t: ^testing.T) {
	// BC7 texture array with 3 slices — the shape of Textures/treeArray2.dds.
	buf := make_dds_dx10(
		8, 8, 1, .BC7_UNORM, 3,
		payload_bytes = 4 * 16 * 3, // 2x2 blocks * 16 bytes * 3 slices
		allocator = context.temp_allocator,
	)
	info, subs, err := parse(buf, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, info.format, Format.BC7_UNORM)
	testing.expect_value(t, info.array_size, u32(3))
	testing.expect(t, !info.is_cube_map)
	testing.expect_value(t, len(subs), 3)
	// Slices are consecutive, 64 bytes each.
	testing.expect_value(t, subs[0].offset, info.data_offset)
	testing.expect_value(t, subs[1].offset, info.data_offset + 64)
	testing.expect_value(t, subs[2].offset, info.data_offset + 128)
}

@(test)
test_parse_dx10_cube_and_volume :: proc(t: ^testing.T) {
	// DX10 cubemap: array_size is multiplied by 6.
	buf := make_dds_dx10(
		4, 4, 1, .BC1_UNORM, 1,
		misc_flag = RESOURCE_MISC_TEXTURECUBE, payload_bytes = 8 * 6,
		allocator = context.temp_allocator,
	)
	info, err := parse_info(buf)
	testing.expect_value(t, err, Error.None)
	testing.expect(t, info.is_cube_map)
	testing.expect_value(t, info.array_size, u32(6))

	// 3D/volume textures are out of scope and must say so.
	vol := make_dds_dx10(4, 4, 1, .BC1_UNORM, 1, dimension = 4, allocator = context.temp_allocator)
	_, err = parse_info(vol)
	testing.expect_value(t, err, Error.Unsupported_Dimension)
}

// ---------------------------------------------------------------------------
// Subresource walk
// ---------------------------------------------------------------------------

@(test)
test_subresource_mip_chain :: proc(t: ^testing.T) {
	// 4x4 BC1 with 3 mips: every level is one 8-byte block (4x4, 2x2, 1x1 all round up).
	buf := make_dds(
		4, 4, 3, pf_four_cc("DXT1"),
		payload_bytes = 24,
		allocator = context.temp_allocator,
	)
	info, subs, err := parse(buf, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, len(subs), 3)

	testing.expect_value(t, subs[0].width, u32(4))
	testing.expect_value(t, subs[1].width, u32(2))
	testing.expect_value(t, subs[2].width, u32(1))

	for sub, i in subs {
		testing.expectf(t, sub.size == 8, "mip %d size %d, want 8", i, sub.size)
		testing.expect_value(t, sub.offset, info.data_offset + u32(i) * 8)
		testing.expect_value(t, sub.array_slice, u32(0))
		testing.expect_value(t, sub.mip, u32(i))
	}
}

@(test)
test_subresource_ordering_is_slice_major :: proc(t: ^testing.T) {
	// D3D12 indexes subresources as mip + slice*mip_levels; the walk must match, or a
	// cubemap's faces land on the wrong sides.
	buf := make_dds_dx10(
		4, 4, 2, .BC1_UNORM, 1,
		misc_flag = RESOURCE_MISC_TEXTURECUBE,
		payload_bytes = 8 * 2 * 6,
		allocator = context.temp_allocator,
	)
	info, subs, err := parse(buf, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, len(subs), 12)

	for sub, i in subs {
		want_slice := u32(i) / info.mip_levels
		want_mip := u32(i) % info.mip_levels
		testing.expectf(
			t,
			sub.array_slice == want_slice && sub.mip == want_mip,
			"subresource %d is slice %d mip %d, want slice %d mip %d",
			i, sub.array_slice, sub.mip, want_slice, want_mip,
		)
	}
}

@(test)
test_subresource_detects_truncation :: proc(t: ^testing.T) {
	// Header claims 3 mips but only one block of payload is present.
	buf := make_dds(
		4, 4, 3, pf_four_cc("DXT1"),
		payload_bytes = 8,
		allocator = context.temp_allocator,
	)
	_, _, err := parse(buf, context.temp_allocator)
	testing.expect_value(t, err, Error.Data_Truncated)
}

// DirectXTK12 maps legacy FourCC 110/115 to these 64-bit formats. Exercise the
// complete parser as well as DX10 headers, so a mapping without a stride cannot pass.
@(test)
test_legacy_64_bit_formats :: proc(t: ^testing.T) {
	cases := [?]struct {four_cc: u32, format: Format} {
		{110, .R16G16B16A16_SNORM},
		{115, .R32G32_FLOAT},
	}
	for c in cases {
		for dx10 in ([?]bool{false, true}) {
			pf := Pixel_Format{size = size_of(Pixel_Format), flags = DDPF_FOURCC, four_cc = c.four_cc}
			// 3x2 plus 1x1 mip: 48 + 8 bytes, with tight row pitches 24 and 8.
			buf := dx10 ? make_dds_dx10(3, 2, 2, c.format, 1, payload_bytes = 56) :
				make_dds(3, 2, 2, pf, payload_bytes = 56)
			defer delete(buf)
			info, subs, err := parse(buf)
			defer delete(subs)
			testing.expectf(t, err == .None, "FourCC %d / DX10=%v: %v", c.four_cc, dx10, err)
			if err != .None {continue}
			testing.expect_value(t, info.format, c.format)
			testing.expect_value(t, len(subs), 2)
			if len(subs) != 2 {continue}
			testing.expect_value(t, subs[0].row_pitch, u32(24))
			testing.expect_value(t, subs[0].size, u32(48))
			testing.expect_value(t, subs[1].row_pitch, u32(8))
			testing.expect_value(t, subs[1].size, u32(8))
			testing.expect_value(t, subs[0].offset, info.data_offset)
			testing.expect_value(t, subs[1].offset, info.data_offset + 48)
			testing.expect_value(t, int(subs[1].offset + subs[1].size), len(buf))
			_, _, short_err := parse(buf[:len(buf)-1], mem.panic_allocator())
			testing.expect_value(t, short_err, Error.Data_Truncated)
		}
	}
}
