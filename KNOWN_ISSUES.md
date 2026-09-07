# Known Issues

Issues originally recorded on 2026-08-11, revalidated against the Odin port, matching
C++ demos, shaders, and vendored DirectXTK12 on 2026-09-06. **All implementation fixes
below remain proposed and unapplied.** The documentation audit does not authorize code changes.

This ledger separates defects from their priority in a learning-oriented project. A successful
run on bundled assets does not disprove a failure path; a different constant does not prove
a visual defect unless a shader or another consumer uses it.

## Priority and educational impact

- **P1:** fix promptly; normal demo execution can violate a fundamental correctness guarantee.
- **P2:** scheduled correctness work, including book-behavior mismatches and shared boundary errors.
- **P3:** optional defensive or teaching cleanup with low impact on current bundled demos.

| Issue | Status / priority | Relationship to reference | Recommended change size |
| --- | --- | --- | --- |
| Graphics-memory page retirement | Confirmed, P1 | Lifetime lost in DirectXTK12 reduction | Small ordering change across 15 frame draw paths |
| DDS layout arithmetic | Reproduced, P2 for bundled demos; P1 before external-input use | Validation omitted or weakened in reduced loader | Moderate parser/upload-boundary work |
| DXC method failure | Source-confirmed, P2 | Weakness also present in book C++ | Small shared-helper change |
| Billboard transparent depth | Source-confirmed, P2 | Missing C++ PSO assignment | One assignment restores parity |
| WavesCS defaults | Source-confirmed, P2 | Earlier demo defaults copied | Two values restore parity |
| BasicTessellation zoom | Source-confirmed, P2 | Crate controls copied | Restore scales and clamp bounds |
| BezierPatch camera/zoom | Source-confirmed, P2 | Other demo defaults and controls copied | Restore initialization and zoom constants |
| Skull counts and indices | Source-confirmed, P3 | Book also trusts bundled model | Focused parser checks |
| Chapter 14 unused lights / stale attribution | Confirmed differences, P3 cleanup | Lights differ but shaders do not consume them | Optional constant, naming and comment cleanup |

Recommended sequence: allocator ordering, small demo parity fixes, shared shader/parser
boundary checks, then optional cleanup. Keep individual demos reviewable and obtain the
appropriate implementation go-ahead. Retain the per-demo structure and existing Odin idioms.

## P1: Graphics-memory pages can be recycled before the GPU is finished

Affected code:

- `odin_port/common/graphics_memory.odin`, especially `commit`
- Every frame draw path that calls `common.commit` before `ExecuteCommandLists`
  (15 frame draw paths across the Chapter 7 through Chapter 14 demos)

The reduced allocator queues its private fence signal from `commit`. The draw paths call
`commit` before they submit the command list that consumes the constants allocated from
the active upload pages. Queue ordering therefore places the signal before the consuming
draw. Once that signal completes, a later `commit` can move the page to the free list and a
subsequent frame can overwrite it while the original draw is still executing.

The matching DirectXTK12 code is safe despite the book demos calling `Commit` before
submission because `GraphicsResource` retains a reference to its allocator page.
`LinearAllocator::FenceCommittedPages` only fences a page when the allocator owns the last
reference. The Odin reduction discarded that handle/reference-count lifetime and returns
only a GPU virtual address, so it cannot rely on the original ordering.

Suggested fix:

- Move each frame's `common.commit` call after its consuming `ExecuteCommandLists`, as the
  one-time compute path in `C13_VecAddCS` already does.
- Correct the allocator header's false claim that either order works, plus dependent handle
  comments. Explain: submit consumers, signal afterward, recycle only after completion.

This small, necessary deviation from the book's call order restores its intended lifetime
guarantee. Restoring DirectXTK12's page-retaining resource handles is a much larger alternative
and is not recommended for these demos. See `External/DirectXTK12/Src/LinearAllocator.cpp`,
`FenceCommittedPages` and its refcount test.

Verify under deliberate GPU backlog, not only an unconstrained local run. Constant data
must remain stable when the CPU gets ahead of the GPU, with no unexpected debug-layer messages or live allocations.
See `AGENTS.md` for detector requirements and the known-benign warning exception.

## P2: Malformed DDS headers can overflow layout arithmetic

Affected code:

- `odin_port/dds/dds.odin`: `parse_info`, `subresource_count`, `parse_subresources`, and
  `parse`
- `odin_port/dds/format.odin`: `surface_info`
- `odin_port/common/texture_upload.odin`: narrowing array and mip counts into the D3D12
  resource description

Header-derived dimensions and counts are kept in `u32` and multiplied without checked
arithmetic. This includes cube-array expansion, `array_size * mip_levels`, compressed block
counts, row sizes, surface sizes, and accumulated offsets. A DX10 `array_size` of zero is
also normalized to one, whereas DirectXTK12 rejects it.

A temporary probe on 2026-09-06 reproduced the bounds panic using a 1x1 DX10 RGBA8
header with `array_size = 0x80000000`, `mip_levels = 2`, and four payload bytes.
`subresource_count` wraps to zero. `parse` allocates an empty destination, but
`parse_subresources` still enters the original array/mip loops and writes `dst[0]`, causing
a bounds panic. Other wrapped surface calculations can make malformed data appear large
enough, produce overlapping offsets, or reach `texture_upload.odin` before array and mip
counts are silently narrowed to `u16`.

Suggested fix:

- In `dds`, reject invalid dimensions, zero DX10 arrays, illegal mip chains and invalid cube
  counts. Preserve the valid legacy convention that a stored mip count of zero means one.
- Widen operands before products and sums; check arithmetic overflow, destination
  representability, accumulated offsets and allocation bounds before allocation or indexing.
  Apply the contract to public layout helpers as well as the allocating `parse` wrapper.
- In `common/texture_upload.odin`, enforce D3D12 dimension, array, mip, pitch and subresource
  restrictions before narrowing or resource creation. Keep graphics imports out of `dds`.
- Add malformed-header tests for zero arrays, cube expansion, subresource-count overflow,
  row/surface overflow and accumulated offsets, plus focused upload-boundary limit checks.

The same probe confirmed that `surface_info(0x08000000, 1, .R8G8B8A8_UNORM)` returns
zero bytes and success, and that a zero DX10 array is accepted as one layer. Ordinary Odin
integer arithmetic wraps; widening only after multiplication cannot repair the result.

P2 reflects the current bundled, developer-controlled assets. Treat this as P1 before accepting
external DDS files or presenting the parser as safe for general reuse. The proposed work is
moderate in size but stays in shared loaders; demo draw code and the supported-format subset
need not change. Preserve returned parser errors and caller-owned fatal-error policy.

## P2: A failing DXC `Compile` call dereferences a nil result

Affected code: `odin_port/common/d3d_util.odin`, `compile_shader`.

If `IDxcCompiler3::Compile` itself returns a failing HRESULT, its `IResult` output may stay
nil. The current code still registers `result->Release` and calls `result->GetOutput` before
passing the HRESULT to `hr_panic`, turning the failure into an access violation. The HRESULT
returned by `IResult::GetStatus` is also ignored. The book's `Common/d3dUtil.cpp` contains
the same method-failure/status-handling weaknesses: inherited defensive debt, rather than
a difference in the successful compilation path.

Suggested fix:

- Check the `Compile` HRESULT and require a non-nil result immediately after the call.
- Only register `Release` after that validation.
- Check the HRESULT from `GetStatus` separately, then inspect the compilation status and
  diagnostic output.
- Preserve the existing stderr and `MessageBoxW` fatal-error reporting behavior.

This is a small shared-helper change; preserve the current shader-warning policy and
startup flow. Add a failure-path test or temporary fault injection that proves a method-level `Compile`
failure reports the HRESULT without dereferencing the output.

## P3: The skull loader trusts file-derived counts and indices

Affected code: `odin_port/common/geometry_builders.odin`, `build_skull_geometry`.

`vcount` and `tcount` are parsed as signed `int` values and immediately used as slice
lengths. The expression `3 * tcount` is unchecked, byte sizes are later narrowed to `u32`,
and parsed indices are narrowed to `i32` without verifying that they address a loaded
vertex. A malformed model can therefore panic on a negative or overflowed allocation,
attempt an unreasonable allocation, wrap buffer-view sizes, or submit out-of-range GPU
indices.

This is lower priority than the DDS parser issues because `Models/skull.txt` is a bundled,
developer-controlled asset rather than a general input format, and the matching C++
`BuildSkullGeometry` implementation also trusts its counts and indices. It is still worth
fixing because the shared Odin loader otherwise turns a damaged or edited asset into an
allocator, bounds, or GPU-validation failure instead of a useful parse error.

Suggested fix:

- Require positive counts within explicit application and D3D12 limits.
- Use checked sufficiently-wide arithmetic for triangle-to-index and byte-size products.
- Verify every parsed index is nonnegative, representable as `i32`, and less than
  `vcount` before creating buffers.
- Report malformed input through `report_error` rather than allowing an allocator or
  bounds panic.

Add focused malformed-model tests if the loader is separated enough to test without a D3D
device; otherwise prove each rejection with a small parser-level helper.

## P2: Billboard water incorrectly writes depth

Affected code: `odin_port/C12_BillboardsGS/billboard_app.odin`, `build_psos`.

The C++ `BillboardApp` sets the transparent PSO's depth write mask to
`D3D12_DEPTH_WRITE_MASK_ZERO`. The Odin PSO inherits the default `ALL` value. Transparent
water is drawn before the billboard sprites, so the water can populate depth and make
later overlapping tree fragments fail their depth test. Disabling depth writes restores the
book's draw behavior; it does not introduce general transparency sorting or guarantee physically
correct compositing of sprites drawn after water.

Suggested fix:

```odin
transparent_pso_desc.DepthStencilState.DepthWriteMask = .ZERO
```

This one-assignment fix restores C++ parity. Place it before creating the transparent PSO. Visually compare the result with
the C++ demo from camera angles where water overlaps tree sprites, then perform the standard
resize, Escape, debug-layer, and leak checks.

## P2: WavesCS uses the wrong simulation defaults

Affected code: `odin_port/C13_WavesCS/waves_cs_app.odin`, application initialization.

The Odin demo initializes `wave_speed` to `8.0` and `wave_damping` to `0.1`, copied from
the earlier CPU-waves demos. The matching `WavesCSApp.h` initializes them to `3.5` and
`0.3`. Those values are passed into `gpu_waves_init` and reapplied by
`gpu_waves_set_constants`, so the port starts with a materially faster and less damped
simulation than the Chapter 13 reference.

| Setting | Current Odin | Matching C++ |
| --- | ---: | ---: |
| Wave speed | `8.0` | `3.5` |
| Wave damping | `0.1` | `0.3` |

Suggested fix: restore the two `WavesCSApp.h` defaults (no deliberate divergence) while retaining the existing ImGui
slider ranges and per-frame constant update. Compare animation over multiple captures—not
only a still frame—with the C++ demo, then perform the standard resize, Escape,
debug-layer, and leak checks.

## P2: BasicTessellation retains crate-demo zoom controls

Affected code: `odin_port/C14_BasicTessellation/basic_tessellation_app.odin`.

The initial camera values match `BasicTessellationApp`, but copied zoom controls do not:

| Setting | Current Odin | Matching C++ |
| --- | ---: | ---: |
| Right-drag scale | `0.005` | `0.05` |
| Radius clamp | `3.0 .. 25.0` | `5.0 .. 150.0` |

Because the valid initial radius is `50`, the first right-button drag clamps it immediately
to `25`. This also changes the distance-dependent tessellation demonstrated by
`Shaders/BasicTessellation.hlsl`.

Suggested fix: restore the C++ constants in `on_mouse_move`. This is a small parity
restoration. Verify initial framing, smooth zoom across the book's range, and the resulting
wireframe tessellation. Unused lights and copied attribution are separate cleanup below.

## P2: BezierPatch uses the wrong camera and zoom controls

Affected code: `odin_port/C14_BezierPatch/bezier_patch_app.odin`.

This file retains initialization and interaction values copied from another demo:

| Setting | Current Odin | Matching C++ |
| --- | ---: | ---: |
| Initial theta | `1.3 * PI` | `0.7 * PI` |
| Initial phi | `0.25 * PI` | `0.42 * PI` |
| Initial radius | `50.0` | `30.0` |
| Right-drag scale | `0.005` | `0.05` |
| Radius clamp | `3.0 .. 25.0` | `5.0 .. 150.0` |

These differences change the sample's initial framing and make the first zoom gesture snap
an out-of-range radius.

Suggested fix: restore the values from `BezierPatchApp.h/.cpp` in initialization and
`on_mouse_move`. This is a small parity restoration. Verify the default view, tessellation
slider, zoom range, and wireframe patch against the C++ demo.

## P3: Chapter 14 unused lights and stale attribution

Both Chapter 14 Odin demos use light strengths `{0.9, 0.8, 0.7}` and `{0.4, 0.4, 0.4}`;
the corresponding C++ uses `{0.8, 0.75, 0.7}` and `{0.3, 0.3, 0.3}`. These differences are
real, but the earlier claim that they alter shading is withdrawn: `PS` in both
`Shaders/BasicTessellation.hlsl` and `Shaders/BezierTessellation.hlsl` returns constant white.
There is no present visual defect or meaningful lighting comparison to run for these values.

Optionally match the unused C++ values for reference fidelity. Both packages also retain
`Crate_App` and `CrateApp` comments, including descriptions of crate geometry and zoom controls.
Rename the application types and update attribution to the matching Chapter 14 sources in a
later code-editing pass. Correct copied waves-index comments too: 128x128 vertices fit in
16-bit indices; the port's 32-bit choice matches C++, but is not required by that vertex count.
These are teaching improvements, not additional rendering defects.

## Validation evidence and remaining checks

The 2026-08-11 review recorded successful direct execution of the commands underlying
`just validate`; interactive checks were not rerun. On 2026-09-06, the fresh audit again
passed those checks and used a temporary DDS probe to reproduce the malformed-input behavior
above. The probe was outside the repository and was not added to the permanent test suite.

During the 2026-09-06 documentation follow-up, **`just 1.58.0` resolved from the existing
WinGet PATH entry in Git Bash, and `just validate` itself passed**:

- 52 release/debug type checks: 19 apps, four test packages, three support packages
- 29 tests: four Chapter 1, one Chapter 2, five Chapter 3, and 19 DDS tests
- DDS integration coverage: 100 book textures, 1,359 subresources, 439.4 MiB
- Portable Linux AMD64 object build of `odin_port/dds`

The suite was rerun successfully after the compiler update to
**`dev-2026-09-nightly:a2fb372`** (2026-09-06 local date / 2026-09-07 UTC). A temporary
compile probe also confirmed the guide's `Material_Data.mat_transform` offset of 48 bytes
and `Per_Pass_CB` size of 1,552 bytes on that compiler.

The initial agent sandbox could not execute the installed WinGet tool. Running the same
Git Bash command with approved access resolved it; this was not a missing installation or
PATH entry. Discovery guidance belongs in `AGENTS.md`.

### September compiler runtime baseline

All **19 apps built with `-debug`**, launched from the repository root, survived six window
resizes, and exited **0 via Escape**. Each run has initial/later and post-resize captures.
The underlying source baseline is commit `eb50a0b`; subsequent edits in this pass are
documentation only. Tested hardware: **AMD Radeon RX 9070 XT**, driver **32.0.31041.1004**,
Windows x64 at 150% display scaling. The pinned DXC runtime was `dxcompiler.dll` 1.6.2112.16
with `dxil.dll` 101.6.2112.13. This is a baseline for this configuration, not a cross-driver
or release-runtime certification.

| Demo | Observed scene/output | Expected id 1328 messages |
| --- | --- | ---: |
| `APPENDIX_A` | White Win32 window; uses KEYDOWN for Escape | 0 |
| `C4_Init_Direct3D` | LightSteelBlue clear and Options overlay | 0 |
| `C6_Box` | Interpolated vertex colors on the box | 2 |
| `C6_BoxGrid` | Multiple colored boxes | 2 |
| `C7_Shapes` | Box, cylinders and spheres in wireframe | 2 |
| `C7_Waves` | Height-colored terrain and moving wireframe water | 3 |
| `C8_LitShapes` | Lit skull, colonnade and floor | 4 |
| `C8_LitWaves` | Shaded green hills and blue water; later/orbited captures show ripples | 3 |
| `C9_Crate` | Wood texture and Direct3D lettering | 2 |
| `C9_TexturedShapes` | Brick columns, tiled floor, stone spheres and skull | 4 |
| `C9_TexWaves` | Grass and animated textured water | 5 |
| `C10_BlendDemo` | Fog, alpha-tested fence and blended water | 5 |
| `C11_Stenciling` | Skull, ice-mirror reflection and projected floor shadow | 4 |
| `C12_BillboardsGS` | Tree sprites over the fogged landscape; known depth-write issue remains | 7 |
| `C13_Blur` | Blurred scene with readable UI | 6 |
| `C13_VecAddCS` | Crate scene; all 32 tuples match `(0, 2*i, i, i, -i)` | 5 |
| `C13_WavesCS` | GPU-displaced textured water; known parameter difference remains | 6 |
| `C14_BasicTessellation` | White wireframe tessellated surface | 2 |
| `C14_BezierPatch` | White wireframe Bezier surface; known initial camera difference remains | 2 |

Stock demo stderr contained **no unexpected messages**, `[odin-leak]` entries or DXGI
live-object reports. The D3D12 debug callback, COM report and Odin tracker were positively
checked in an **isolated temporary copy**: an application message reached stderr, an
intentionally leaked fence appeared in both D3D12 and DXGI reports, and a 123-byte Odin
allocation was reported with its source location. These deliberate probe diagnostics are
excluded from the stock-demo results. Appendix A has no D3D12 or tracking-allocator setup.
GPU-based validation remained off; no new missing-barrier probe or GPU-backlog test ran.

Representative input checks confirmed orbit-camera changes, the Box wireframe checkbox,
and the Bezier Tess Factor slider. Static and later frames were inspected for geometry,
texturing, lighting, animation, reflection and tessellation. Some initial captures were
invalidated by another foreground window and discarded; valid runs checked the target
window identity. Existing `imgui.ini` and `results.txt` state was restored after testing.

**Limits:** this pass inspected Odin renders against the matching source and expected chapter
behavior; it did not produce synchronized new C++/Odin image pairs or exercise every control
and camera angle. The billboard, WavesCS and Chapter 14 differences above remain pending.
An ordinary successful render does not close the allocator fence-ordering issue. The
per-issue acceptance checks still apply when implementing fixes.

### ImGui restore verification

A clean temporary checkout of Capati/odin-imgui at
`6987747b1c78f984ac529e2d0cc1f59fd60c50ac` successfully generated and built the **1.92.8-docking**
native library with Win32/DX12. Its automatic pattern patch changed two Win32 declarations;
the previous manual C2159 workaround was unnecessary. The existing vendored `imgui.odin`
matches the local older checkout at `a29e17ad139d7bacb5a7c5507ed2ea3334a4ffbe` by SHA-256.
Temporary demo copies using the rebuilt library rendered, resized and exited normally,
including a clean BezierPatch run. See `odin_port/README.md` for the tested restore commands.

The current upstream default is 1.92.9b-docking. Its newer bindings were **not** substituted
or validated here; restoring the current library and upgrading the binding set are separate
operations. No implementation, vendored binding, installed project library or permanent
test was changed in this documentation pass.

The existing `git diff --check main...HEAD` warnings concern mixed space/tab indentation in six
signature lines of `odin_port/libs/imgui/backends/dx12/imgui_impl_dx12.odin` (38-44).
They are a validation note, not a behavioral finding.
