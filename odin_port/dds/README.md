# `dds` — a DDS file parser

Nothing in Odin's `core:` or `vendor:` reads DDS, so the port hand-rolls one. This package
is the **parsing half** only: DDS bytes in, a `Texture_Info` and a per-surface layout out.
No Direct3D device, no GPU, no file-I/O policy, no `os.exit`.

```odin
data, _ := os.read_entire_file("Textures/WoodCrate01.dds", context.allocator)
info, subresources, err := dds.parse(data, context.allocator)
// info.format == .BC3_UNORM, info.mip_levels == 10, len(subresources) == 10
```

The Direct3D 12 half — creating the resource, re-pitching rows into an upload heap, and
recording the copies — lives in [`../common/texture_upload.odin`](../common/texture_upload.odin).

## Why the split

DirectXTK12 splits the same way, which is where the shape came from:

| DirectXTK12 | Does | Here |
|---|---|---|
| `LoadDDSTextureFromFile` | parse the file, describe subresources | `dds.parse` |
| `CreateDDSTextureFromFile` | the above, then create + upload | `common.create_dds_texture` |

Ours splits a little harder than theirs. DirectXTK12's `Load*` still takes an
`ID3D12Device` because it creates the resource; this package touches no D3D12 type at all
beyond the `dxgi.FORMAT` enum. That is what lets the parser be unit-tested with no GPU and
no assets:

```
odin test odin_port/dds      # run from the repo root
```

Errors are **returned, not fatal**. The demos' fail-fast convention (`report_error` then
exit) belongs to the caller — a parser that tests need to feed malformed input to can't be
the thing that decides to kill the process.

## Supported formats

Everything the book's 100 `.dds` files use, plus the rest of the legacy mapping that came
along for free:

| Source | Maps to |
|---|---|
| FourCC `DXT1` | `BC1_UNORM` |
| FourCC `DXT2`, `DXT3` | `BC2_UNORM` |
| FourCC `DXT4`, `DXT5` | `BC3_UNORM` |
| FourCC `ATI1`, `BC4U` / `BC4S` | `BC4_UNORM` / `BC4_SNORM` |
| FourCC `ATI2`, `BC5U` / `BC5S` | `BC5_UNORM` / `BC5_SNORM` |
| FourCC 36, 110–116 (D3DFMT enums) | the 16/32-bit float + SNORM formats |
| 32-bpp RGB masks | `R8G8B8A8_UNORM`, `B8G8R8A8_UNORM`, `B8G8R8X8_UNORM`, `R10G10B10A2_UNORM`, `R16G16_UNORM`, `R32_FLOAT` |
| 16-bpp RGB masks | `B5G5R5A1_UNORM`, `B5G6R5_UNORM`, `B4G4R4A4_UNORM`, `R8G8_UNORM`, `R16_UNORM` |
| 8-bpp RGB mask | `R8_UNORM` |
| `DDPF_LUMINANCE`, `DDPF_ALPHA`, `DDPF_BUMPDUDV` | `R8_UNORM` / `R8G8_UNORM` / `R16_UNORM` / `A8_UNORM` / the SNORM pair |
| `DX10` extended header | any `DXGI_FORMAT` the tables below know a pitch for — includes BC6H and BC7 |

Structural features: mip chains, texture arrays, cubemaps (legacy `caps2` bits and the
DX10 `miscFlag`), and `mip_map_count == 0` normalized to 1 (ten of the book's files are
written that way).

## Intentionally not supported

These are absent because no book asset needs them, not because they're hard. Each one
fails with a specific `Error` and, for formats, a message naming the header fields — so
extending is a matter of adding a table row, never of debugging a corrupt texture.

| Not supported | `Error` | Why |
|---|---|---|
| 3D / volume textures | `.Unsupported_Dimension` | No book demo uses one |
| 1D textures | `.Unsupported_Dimension` | Same |
| Partial cubemaps (< 6 faces) | `.Partial_Cube_Map` | D3D12 has no partial-cube resource; DirectXTK12 rejects these too |
| Packed formats (`R8G8_B8G8`, `YUY2`, `Y210`, `Y216`) | `.Unsupported_Format` | Video formats; the book has none |
| Planar/YUV formats (`NV12`, `P010`, `NV11`, …) | `.Unsupported_Format` | Need per-plane subresource handling |
| Palettized (`P8`, `A8P8`) | `.Unsupported_Format` | No DXGI equivalent |
| `maxsize` downscaling / mip skipping | — | DirectXTK12 can drop large mips on load; we always take the file as-is |
| `DDS_LOADER_FORCE_SRGB`, `MIP_AUTOGEN`, `MIP_RESERVE` | — | Loader flags the book never sets |
| Alpha-mode metadata (`DDS_ALPHA_MODE`) | — | Parsed by DirectXTK12, unused by the book's shaders |

`bits_per_pixel` also deliberately covers a subset of DXGI's ~120 formats. A DX10-header
file naming something outside it returns `.Unsupported_Format` rather than guessing a
stride — the failure mode that matters, since a wrong stride uploads a skewed texture
instead of erroring.

## Validation

Three independent checks, all currently green.

**1. Byte-for-byte against DirectXTK12.** The two functions where a table typo would
silently corrupt a texture — `GetDXGIFormat` (format mapping) and `GetSurfaceInfo` (pitch
math) — are `inline` in DirectXTK12's `Src/LoaderHelpers.h`, so they can be called
directly. A small C++ harness calls *their* code (plus their `LoadTextureDataFromFile` for
header validation) and dumps, per file: format, dimensions, mip count, array size, cube
flag, data offset, and every subresource's offset / byte count / row pitch / row count.
The same dump from this package was diffed against it:

> **101 files, 1365 subresources, zero differing lines.**

That covers all 100 book textures plus `TropicalSunnyDay.dds` from Jason Zink's
*Hieroglyph3* (a Direct3D 11 book) — a different asset pipeline, and the only file on hand
that combines a legacy BGRA cubemap with `mip_map_count == 0`.

To re-run it: build `oracle.cpp` (kept out of the repo — it needs
`External/DirectXTK12`, which the C++ demos' NuGet restore provides) against
`/I External/DirectXTK12/Src /I External/DirectXTK12/Inc`, feed it a list of `.dds` paths,
and diff its output against the same dump from `dds.parse`.

**2. A size identity over every file**, in `dds_files_test.odin` — walking the surfaces
must consume each file *exactly*: `data_offset + Σ subresource.size == file size`. This is
independent of DirectXTK12 (the file itself is the oracle) and catches a wrong block size,
a missed mip, a bad array count, or an off-by-one in the mip chain. All 100 book files pass,
totalling 439 MiB.

**3. The demos render.** Chapter 9's crate, tiled floor, and scrolling water are the
end-to-end proof that the bits land where the sampler expects them.

## Layout notes worth knowing

- **`mip_map_count == 0` means one level**, not zero. `Textures/tile0.dds` is 512×512 BC1
  with 0 in that field, and its file size is exactly `128 + 512*512/2` — one level.
- **Block-compressed pitch** is `max(1, (w+3)/4) * block_bytes`, with 8 bytes per block for
  BC1/BC4 and 16 for BC2/BC3/BC5/BC6H/BC7. A 1×1 BC1 mip still occupies a whole 8-byte
  block, so mip chains do not shrink to nothing.
- **`row_pitch` here is the file's tight pitch**, not D3D12's 256-byte-aligned upload
  pitch. The upload layer re-pitches row by row; `create_dds_texture` asserts the two agree
  on the tight value it gets back from `GetCopyableFootprints`.
- **Subresource order is slice-major** (`index = mip + array_slice * mip_levels`), matching
  both the DDS file layout and D3D12's own subresource indexing — so a single linear walk
  serves arrays and cubes.
