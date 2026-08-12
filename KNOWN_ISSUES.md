# Known Issues

These issues were found while reviewing the `odin` branch against `main` on
2026-08-11. They are deliberately deferred; none of the implementation fixes described
below have been applied yet.

## P1: Graphics-memory pages can be recycled before the GPU is finished

Affected code:

- `odin_port/common/graphics_memory.odin`, especially `commit`
- Every frame draw path that calls `common.commit` before `ExecuteCommandLists`
  (the Chapter 7 through Chapter 14 demos)

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
  one-time compute path in `C13_VecAddCS` already does; or
- Restore DirectXTK12-style page-retaining resource handles and retirement semantics.

Verify under deliberate GPU backlog, not only an unconstrained local run. Constant data
must remain stable when the CPU gets ahead of the GPU, and the debug layer and both leak
reports must remain silent.

## P1: Malformed DDS headers can overflow layout arithmetic

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

For a concrete failure, `array_size = 0x80000000` and `mip_levels = 2` makes
`subresource_count` wrap to zero. `parse` allocates an empty destination, but
`parse_subresources` still enters the original array/mip loops and writes `dst[0]`, causing
a bounds panic. Other wrapped surface calculations can make malformed data appear large
enough, produce overlapping offsets, or reach `texture_upload.odin` before array and mip
counts are silently narrowed to `u16`.

Suggested fix:

- Reject zero or illegal dimensions, DX10 array sizes, mip counts, and cube counts.
- Enforce D3D12 dimension, array, mip, row-pitch, and subresource-count limits before
  resource creation.
- Perform every product, sum, and offset update with checked `u64`/`uint` arithmetic.
- Check representability before narrowing to `u32` or `u16`.
- Add malformed-header tests for zero arrays, cube multiplication, subresource-count
  overflow, row/surface overflow, accumulated-offset overflow, and D3D12 limit violations.

## P2: A failing DXC `Compile` call dereferences a nil result

Affected code: `odin_port/common/d3d_util.odin`, `compile_shader`.

If `IDxcCompiler3::Compile` itself returns a failing HRESULT, its `IResult` output may stay
nil. The current code still registers `result->Release` and calls `result->GetOutput` before
passing the HRESULT to `hr_panic`, turning the failure into an access violation. The HRESULT
returned by `IResult::GetStatus` is also ignored.

Suggested fix:

- Check the `Compile` HRESULT and require a non-nil result immediately after the call.
- Only register `Release` after that validation.
- Check the HRESULT from `GetStatus` separately, then inspect the compilation status and
  diagnostic output.
- Preserve the existing stderr and `MessageBoxW` fatal-error reporting behavior.

Add a failure-path test or temporary fault injection that proves a method-level `Compile`
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
later trees viewed through it fail their depth test instead of being composited through the
water.

Suggested fix:

```odin
transparent_pso_desc.DepthStencilState.DepthWriteMask = .ZERO
```

Place this mutation before creating the transparent PSO. Visually compare the result with
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

Suggested fix: restore the `WavesCSApp.h` defaults while retaining the existing ImGui
slider ranges and per-frame constant update. Compare animation over multiple captures—not
only a still frame—with the C++ demo, then perform the standard resize, Escape,
debug-layer, and leak checks.

## P2: BasicTessellation retains crate-demo controls and lighting

Affected code: `odin_port/C14_BasicTessellation/basic_tessellation_app.odin`.

The initial camera values match `BasicTessellationApp`, but other copied values do not:

| Setting | Current Odin | Matching C++ |
| --- | ---: | ---: |
| Right-drag scale | `0.005` | `0.05` |
| Radius clamp | `3.0 .. 25.0` | `5.0 .. 150.0` |
| Light 0 strength | `{0.9, 0.8, 0.7}` | `{0.8, 0.75, 0.7}` |
| Light 1 strength | `{0.4, 0.4, 0.4}` | `{0.3, 0.3, 0.3}` |

Because the valid initial radius is `50`, the first right-button drag clamps it immediately
to `25`. The light differences also change the intended shading.

Suggested fix: restore the C++ constants in `on_mouse_move` and `update_main_pass_cb`, and
replace the remaining `CrateApp` attribution comments with the matching
`BasicTessellationApp` source references while touching those sections. Verify initial
framing, zoom behavior, lighting, and wireframe tessellation against the C++ demo.

## P2: BezierPatch uses the wrong camera, controls, and lighting

Affected code: `odin_port/C14_BezierPatch/bezier_patch_app.odin`.

This file retains initialization and interaction values copied from another demo:

| Setting | Current Odin | Matching C++ |
| --- | ---: | ---: |
| Initial theta | `1.3 * PI` | `0.7 * PI` |
| Initial phi | `0.25 * PI` | `0.42 * PI` |
| Initial radius | `50.0` | `30.0` |
| Right-drag scale | `0.005` | `0.05` |
| Radius clamp | `3.0 .. 25.0` | `5.0 .. 150.0` |
| Light 0 strength | `{0.9, 0.8, 0.7}` | `{0.8, 0.75, 0.7}` |
| Light 1 strength | `{0.4, 0.4, 0.4}` | `{0.3, 0.3, 0.3}` |

These differences change the sample's initial framing, make the first zoom gesture snap an
out-of-range radius, and alter the patch shading.

Suggested fix: restore the values from `BezierPatchApp.h/.cpp` in initialization,
`on_mouse_move`, and `update_main_pass_cb`. Replace the remaining `CrateApp` attribution
comments with `BezierPatchApp` references while touching the affected sections. Verify the
default view, tessellation slider, zoom range, lighting, and wireframe patch against the C++
demo.

## Validation status when recorded

The implementation was not changed during the review. The commands underlying
`just validate` all passed:

- Release and debug type checks for every app, test, and support package
- Chapter 1-3 math tests
- DDS unit and integration tests: 100 book textures and 1,359 subresources
- Portable Linux AMD64 object build of `odin_port/dds`

The `just` executable was not available in the review shell, so the recipe's commands were
run directly. Interactive window rendering, resize storms, Escape handling, debug-layer
output, and COM/Odin leak checks were not rerun during this review.

`git diff --check main...HEAD` also reported mixed space/tab indentation in six signature
lines in `odin_port/libs/imgui/backends/dx12/imgui_impl_dx12.odin` (lines 38-44 at the time
of review). This is kept as a validation note rather than a behavioral finding.
