// Integration tests against real .dds files on disk. Kept separate from dds_test.odin so
// that file stays portable — everything here needs assets, and skips (loudly) when they
// aren't present.
//
// Run FROM THE REPO ROOT, like the demos:
//   odin test odin_port/dds
//
// The core assertion is a **size identity**: walking every surface must consume the file
// exactly, `data_offset + Σ subresource.size == file size`. That single check catches a
// wrong block size, a missed mip, a bad array count, or an off-by-one in the mip chain —
// independently of DirectXTK12, because the file itself is the oracle.
package dds

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import dxgi "vendor:directx/dxgi"

// The book's textures, relative to the repo root.
@(private = "file")
BOOK_TEXTURES_DIR :: "Textures"

// A DDS from a different book/engine (Jason Zink's *Practical Rendering & Computation
// with Direct3D 11*, the Hieroglyph3 sample data) — an independent writer, so it exercises
// header conventions the book's own asset pipeline never produces. Absolute and
// user-specific, hence the skip.
@(private = "file")
FOREIGN_DDS :: "C:/Users/nathany/src/github.com/JasonZink/Hieroglyph3-mirror/Applications/Data/Textures/TropicalSunnyDay.dds"

@(private = "file")
Checked :: struct {
	files:      int,
	subresources: int,
	bytes:      i64,
}

// Parse one file and assert the size identity. Returns false if the file didn't parse.
@(private = "file")
check_file :: proc(t: ^testing.T, path: string, acc: ^Checked) -> bool {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		testing.expectf(t, false, "%s: cannot read (%v)", path, read_err)
		return false
	}
	defer delete(data)

	info, subs, err := parse(data, context.allocator)
	defer delete(subs)
	if err != .None {
		pf := info.pixel_format
		testing.expectf(
			t,
			false,
			"%s: parse failed (%v) — flags=%#x fourCC=%#x bits=%d masks=%#x/%#x/%#x/%#x",
			path, err, pf.flags, pf.four_cc, pf.rgb_bit_count,
			pf.r_bit_mask, pf.g_bit_mask, pf.b_bit_mask, pf.a_bit_mask,
		)
		return false
	}

	// Sanity: the header should describe a real texture.
	testing.expectf(t, info.width > 0 && info.height > 0, "%s: zero dimensions", path)
	testing.expectf(t, info.mip_levels >= 1, "%s: mip_levels < 1", path)
	testing.expectf(t, info.array_size >= 1, "%s: array_size < 1", path)
	testing.expectf(
		t,
		len(subs) == int(subresource_count(info)),
		"%s: %d subresources, expected %d",
		path, len(subs), subresource_count(info),
	)

	// A cubemap must have six faces (or a multiple, for cube arrays).
	if info.is_cube_map {
		testing.expectf(
			t,
			info.array_size % 6 == 0,
			"%s: cubemap array_size %d is not a multiple of 6",
			path, info.array_size,
		)
	}

	// THE identity: surfaces must tile the file exactly.
	total := i64(info.data_offset)
	for sub in subs {
		total += i64(sub.size)
	}
	testing.expectf(
		t,
		total == i64(len(data)),
		"%s: surfaces cover %d bytes but the file is %d (format %v, %dx%d, %d mips, %d slices)",
		path, total, len(data), info.format, info.width, info.height, info.mip_levels, info.array_size,
	)

	// The mip chain must halve down to 1x1 (or stop early, but never below 1).
	last := subs[len(subs) - 1]
	testing.expectf(t, last.width >= 1 && last.height >= 1, "%s: degenerate final mip", path)

	acc.files += 1
	acc.subresources += len(subs)
	acc.bytes += i64(len(data))
	return true
}

@(test)
test_all_book_textures_load :: proc(t: ^testing.T) {
	if !os.exists(BOOK_TEXTURES_DIR) {
		log.warnf(
			"SKIP: %q not found — run from the repo root (odin test odin_port/dds)",
			BOOK_TEXTURES_DIR,
		)
		return
	}

	acc: Checked
	formats := make(map[dxgi.FORMAT]int, context.allocator)
	defer delete(formats)
	cube_count := 0

	w := os.walker_create(BOOK_TEXTURES_DIR)
	defer os.walker_destroy(&w)

	for fi in os.walker_walk(&w) {
		if fi.type == .Directory {
			continue
		}
		if !strings.has_suffix(strings.to_lower(fi.name, context.temp_allocator), ".dds") {
			continue
		}

		if !check_file(t, fi.fullpath, &acc) {
			continue
		}

		// Re-parse cheaply for the census (check_file owns its own buffer).
		data, _ := os.read_entire_file(fi.fullpath, context.temp_allocator)
		if info, err := parse_info(data); err == .None {
			formats[info.format] += 1
			if info.is_cube_map {
				cube_count += 1
			}
		}
		free_all(context.temp_allocator)
	}

	if path, err := os.walker_error(&w); err != nil {
		testing.expectf(t, false, "walking %s failed at %s: %v", BOOK_TEXTURES_DIR, path, err)
	}

	testing.expectf(t, acc.files > 0, "no .dds files found under %q", BOOK_TEXTURES_DIR)

	// Census in the log, so a future chapter adding assets shows up as a diff here.
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%d files, %d subresources, %.1f MiB; %d cubemaps; formats:",
		acc.files, acc.subresources, f64(acc.bytes) / (1024 * 1024), cube_count)
	for format, n in formats {
		fmt.sbprintf(&b, " %v=%d", format, n)
	}
	log.info(strings.to_string(b))
}

@(test)
test_foreign_dds_loads :: proc(t: ^testing.T) {
	if !os.exists(FOREIGN_DDS) {
		log.warnf("SKIP: %q not present on this machine", FOREIGN_DDS)
		return
	}

	acc: Checked
	if !check_file(t, FOREIGN_DDS, &acc) {
		return
	}

	data, _ := os.read_entire_file(FOREIGN_DDS, context.temp_allocator)
	defer free_all(context.temp_allocator)
	info, err := parse_info(data)
	testing.expect_value(t, err, Error.None)

	// A legacy (no DX10 header) BGRA cubemap with mip_map_count == 0 — three of the
	// format's sharper corners in one file, and none of them appear together in the
	// book's own assets.
	testing.expect_value(t, info.format, dxgi.FORMAT.B8G8R8A8_UNORM)
	testing.expect(t, info.is_cube_map)
	testing.expect_value(t, info.array_size, u32(6))
	testing.expect_value(t, info.mip_levels, u32(1))
	testing.expect_value(t, info.width, u32(512))
	testing.expect_value(t, info.height, u32(512))
	testing.expect_value(t, info.data_offset, u32(128)) // no DX10 header
}

@(test)
test_known_book_files_have_expected_formats :: proc(t: ^testing.T) {
	// Spot-checks with values read straight out of the file headers — these pin the
	// legacy FourCC path, the DX10 path, and the three uncompressed mask variants.
	Case :: struct {
		path:        string,
		format:      dxgi.FORMAT,
		width:       u32,
		mips:        u32,
		array_size:  u32,
		is_cube:     bool,
	}
	cases := [?]Case {
		{"Textures/WoodCrate01.dds", .BC3_UNORM, 512, 10, 1, false},
		{"Textures/water1.dds", .BC1_UNORM, 256, 9, 1, false},
		{"Textures/bricks0_color.dds", .BC1_UNORM, 1024, 11, 1, false},
		// mip_map_count == 0 in the header; must normalize to 1.
		{"Textures/tile0.dds", .BC1_UNORM, 512, 1, 1, false},
		{"Textures/white1x1.dds", .B8G8R8A8_UNORM, 1, 1, 1, false},
		// DDPF_RGB without DDPF_ALPHAPIXELS -> the X8 variant.
		{"Textures/default_glossHeightAoMap.dds", .B8G8R8X8_UNORM, 1, 1, 1, false},
		// DX10 header: BC7 texture array, 3 slices (ch 12's billboards).
		{"Textures/treeArray2.dds", .BC7_UNORM, 208, 9, 3, false},
		// Legacy BC1 cubemap, six faces.
		{"Textures/grasscube1024.dds", .BC1_UNORM, 1024, 11, 6, true},
	}

	for c in cases {
		if !os.exists(c.path) {
			log.warnf("SKIP: %q not found", c.path)
			continue
		}
		data, _ := os.read_entire_file(c.path, context.temp_allocator)
		info, err := parse_info(data)
		testing.expectf(t, err == .None, "%s: %v", c.path, err)
		if err != .None {
			continue
		}
		testing.expectf(t, info.format == c.format, "%s: format %v, want %v", c.path, info.format, c.format)
		testing.expectf(t, info.width == c.width, "%s: width %d, want %d", c.path, info.width, c.width)
		testing.expectf(t, info.mip_levels == c.mips, "%s: mips %d, want %d", c.path, info.mip_levels, c.mips)
		testing.expectf(
			t,
			info.array_size == c.array_size,
			"%s: array_size %d, want %d", c.path, info.array_size, c.array_size,
		)
		testing.expectf(t, info.is_cube_map == c.is_cube, "%s: is_cube_map %v", c.path, info.is_cube_map)
		free_all(context.temp_allocator)
	}
}

// Guard against the filepath import being dropped by a future edit; also documents that
// paths here are repo-relative on purpose.
@(test)
test_paths_are_relative :: proc(t: ^testing.T) {
	testing.expect(t, !filepath.is_abs(BOOK_TEXTURES_DIR))
}
