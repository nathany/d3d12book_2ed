# `dds` — a DDS file parser

Nothing in Odin's `core:` or `vendor:` reads DDS, so the port hand-rolls one. This package
is the **parsing half** only: DDS bytes in, a `Texture_Info` and a per-surface layout out.
No Direct3D device, no GPU, no file-I/O policy, no `os.exit`.

```odin
// Inside a procedure; imports: core:os, core:fmt and this package as dds.
data, read_err := os.read_entire_file("Textures/WoodCrate01.dds", context.allocator)
if read_err != nil {
    // Report or return the file error according to your application's policy.
    return
}
defer delete(data)
info, subresources, err := dds.parse(data, context.allocator)
if err != .None {
    // Report or return the parse error before consuming the metadata.
    return
}
defer delete(subresources)
// Use info and subresources while data remains alive: offsets refer into data.
// This asset has format .BC3_UNORM and ten mip levels.
fmt.println(info.format, info.mip_levels, len(subresources))
```

The Direct3D 12 half — creating the resource, re-pitching rows into an upload heap, and
recording the copies — lives in [`../common/texture_upload.odin`](../common/texture_upload.odin).

## Why the split

DirectXTK12 splits the same way, which is where the shape came from:

| DirectXTK12 | Does | Here |
|---|---|---|
| `LoadDDSTextureFromFile` | parse the file, describe subresources | `dds.parse` |
| `CreateDDSTextureFromFile` | the above, then create + upload | `common.create_dds_texture` |

Ours splits harder: DirectXTK12's `Load*` still takes an `ID3D12Device` because it creates
the resource, while this package touches no D3D12 type at all. That is what lets the parser
be unit-tested with synthetic bytes and no GPU. The full `just test dds` suite also reads
bundled assets, so run it from the repo root.

Errors are **returned, not fatal**. The demos' fail-fast convention (`report_error` then
exit) belongs to the caller — a parser that tests feed malformed input to can't be the thing
that decides to kill the process.

## Layout validation

The parser keeps `u32` offsets and pitches, with a **UINT32_MAX-byte file/layout limit**,
matching DirectXTK12's file-size and surface-size bounds. It widens operands before doing
arithmetic, then checks the result before narrowing. It rejects zero dimensions and DX10
arrays, overflowing cube-face counts, nonsquare/incomplete cubes, and mip chains longer
than the dimensions permit. A stored mip count of zero still means one level.

`parse_info` validates the header and the representability of its complete layout without
reading payload. `layout_size(info)` also validates caller-constructed metadata and returns
the required file size, including `data_offset`. `subresource_count(info)` returns a `u64`
product; it does not validate metadata by itself. Both `parse` and `parse_subresources`
check payload length before allocation or writing entries. A short destination returns
`Destination_Too_Small`; allocation failure returns `Out_Of_Memory`.

D3D12 dimension, array and mip limits belong in `common/texture_upload.odin`, before the
resource description narrows counts to `u16`. The format subset and resource limits also
bound upload row pitches. This keeps file-format rules separate from graphics-device rules.

## No graphics API required

The parser imports only `core:mem`. Keeping file-format parsing separate from resource
creation makes malformed-header tests possible without setting up a graphics device.
This project's setup and validation target Windows and DirectX 12.

So `Format` is declared locally in [`format_ids.odin`](format_ids.odin), **using DXGI's
numbering** — not a concession to Direct3D but the file format's own vocabulary, since a
DX10-extended header stores a raw `DXGI_FORMAT` integer. Converting to D3D12 is therefore a
plain cast, no lookup table:

```odin
Format = dxgi.FORMAT(info.format)
```

[`format_dxgi_test.odin`](format_dxgi_test.odin) asserts all 51 members agree with
`vendor:directx/dxgi` value-for-value, so that cast can't drift. It is the only file here
that imports a graphics API, and it's gated `#+build windows`.

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
| `DX10` extended header | any format `bits_per_pixel` knows a stride for — includes BC6H and BC7 |

Structural features: mip chains, texture arrays, cubemaps (legacy `caps2` bits and the DX10
`miscFlag`), and `mip_map_count == 0` normalized to 1.

## Intentionally not supported

Absent because no book asset needs them, not because they're hard. Each fails with a
specific `Error` and, for formats, a message naming the header fields — so extending means
adding a table row, never debugging a corrupt texture.

| Not supported | `Error` | Why |
|---|---|---|
| 3D / volume and 1D textures | `.Unsupported_Dimension` | No book demo uses one |
| Partial cubemaps (< 6 faces) | `.Partial_Cube_Map` | D3D12 has no partial-cube resource; DirectXTK12 rejects these too |
| Packed formats (`R8G8_B8G8`, `YUY2`, `Y210`, `Y216`) | `.Unsupported_Format` | Video formats; the book has none |
| Planar/YUV formats (`NV12`, `P010`, `NV11`, …) | `.Unsupported_Format` | Need per-plane subresource handling |
| Palettized (`P8`, `A8P8`) | `.Unsupported_Format` | No DXGI equivalent |
| `maxsize` downscaling / mip skipping | — | DirectXTK12 can drop large mips on load; we take the file as-is |
| `DDS_LOADER_FORCE_SRGB`, `MIP_AUTOGEN`, `MIP_RESERVE` | — | Loader flags the book never sets |
| Alpha-mode metadata (`DDS_ALPHA_MODE`) | — | Parsed by DirectXTK12, unused by the book's shaders |

`bits_per_pixel` covers a subset of DXGI's ~120 formats. A DX10-header file naming something
outside it returns `.Unsupported_Format` rather than guessing a stride — the failure mode
that matters, since a wrong stride uploads a skewed texture instead of erroring.

## Tests and reference comparison

Run from the repository root:

```bash
just test dds       # synthetic layouts, malformed inputs and all bundled DDS assets
just test-upload   # D3D12 metadata limits (also includes skull boundaries)
```

Both run in `just validate` without a graphics device. The parser tests cover format mappings,
row/surface overflow, cube expansion, mip/array sums, final offsets, truncation and allocation
failure. A panic allocator proves invalid/truncated files fail before allocation. The bundled
file test verifies `data_offset + sum(subresource.size) == file size` for all 100 textures;
`format_dxgi_test.odin` checks all 51 local enum values against the installed DXGI bindings.
Rendering the textured demos checks the separate upload and sampling path.

An earlier one-off C++ oracle comparison against DirectXTK12 matched 101 files and 1,365
subresources, including one external legacy cubemap fixture. That harness and external asset
are not tracked and are not prerequisites for the checked-in suite. The permanent tests above
are the repeatable checks; the historical comparison does not cover every malformed input.

## Layout notes worth knowing

- **`mip_map_count == 0` means one level**, not zero. `Textures/tile0.dds` is 512×512 BC1
  with 0 in that field, and its size is exactly `128 + 512*512/2` — one level. Ten of the
  book's files are written this way.
- **Block-compressed pitch** is `max(1, (w+3)/4) * block_bytes`, with 8 bytes per block for
  BC1/BC4 and 16 for BC2/BC3/BC5/BC6H/BC7. A 1×1 BC1 mip still occupies a whole 8-byte
  block, so mip chains don't shrink to nothing.
- **`row_pitch` is the file's tight pitch**, not D3D12's 256-byte-aligned upload pitch. The
  upload layer re-pitches row by row, and `create_dds_texture` asserts the two agree on the
  tight value from `GetCopyableFootprints`.
- **Subresource order is slice-major** (`index = mip + array_slice * mip_levels`), matching
  both the DDS file layout and D3D12's subresource indexing — so one linear walk serves
  arrays and cubes.
