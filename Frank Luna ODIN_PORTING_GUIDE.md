# Porting Luna's *Introduction to 3D Game Programming with DirectX 12* (2nd ed.) to Odin

A chapter-by-chapter companion for porting the book's C++ samples to Odin by hand, as a learning
exercise. It deliberately does **not** port the code for you — it tells you what to port first,
which library replaces what, and where the traps are. (Companion to `ZIG_PORTING_GUIDE.md`;
same book analysis, different target language.)

## The stack

| Book dependency                                                                                 | Odin replacement                                                                         | Notes                                                                                                                                         |
| ----------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| Win32 (`windows.h`)                                                                             | `core:sys/windows`                                                                       | Comprehensive; binds the wide (`...W`) variants                                                                                               |
| D3D12 / DXGI                                                                                    | `vendor:directx/d3d12`, `vendor:directx/dxgi`                                            | Ships with the compiler. Covers everything the book uses, incl. DXR & mesh shaders — plus `IInfoQueue1` and DRED (see ch 4 side quest)        |
| dxc COM API (runtime shader compile)                                                            | `vendor:directx/dxc`                                                                     | **Fully bound**, and `dxcompiler.dll`/`dxil.dll` ship in the vendor folder — the book's runtime-compile flow ports 1:1 (unlike the Zig stack) |
| DirectXMath / SimpleMath                                                                        | built-in `matrix[4,4]f32` + `[N]f32` arrays + `core:math/linalg`                         | Operator overloading exists! But conventions differ — read the Matrices section carefully                                                     |
| DirectXCollision                                                                                | *hand-roll* (small)                                                                      | Needed at ch 16–17; same gap as Zig                                                                                                           |
| Dear ImGui 1.85 + Win32/DX12 backends                                                           | community **Capati/odin-imgui** (bundles 1.92.x-docking, includes win32 + dx12 backends) | Not in vendor; the book's widget calls map 1:1                                                                                                |
| DirectXTK12 (`ResourceUploadBatch`, `CreateStaticBuffer`, `DDSTextureLoader`, `GraphicsMemory`) | *hand-roll*                                                                              | Same two helpers as the Zig port — **plus a DDS parser**: Odin has no DDS loader anywhere (biggest single gap vs Zig)                         |
| PPL (`parallel_for`)                                                                            | serial loop or `core:thread`                                                             | Only the CPU Waves demos (ch 7–12)                                                                                                            |
| Agility SDK 614 (`D3D12SDKVersion` export)                                                      | optional                                                                                 | See ch 4 — on Windows 11 the inbox runtime already has SM 6.6; ship Agility only if you need it                                               |

No version juggling: `vendor:` and `core:` track the Odin compiler itself — there is no
zwindows-style "does it build on this compiler version" prerequisite. Grab a current Odin
release and everything above is present.

## Global conventions (read once, applies everywhere)

### Matrices — the big one, read twice

Odin differs from DirectXMath on *both* axes, and they interact:

- **Storage:** Odin's `matrix[4,4]f32` is **column-major** in memory (DirectXMath is row-major).
- **Convention:** `core:math/linalg`'s builders (`matrix4_look_at`, `matrix4_perspective`,
  `matrix4_translate`…) are **column-vector** (`v' = M * v`, concatenate right-to-left) and
  **OpenGL-flavored** — `matrix4_perspective` produces depth in [-1, 1], not D3D's [0, 1].
  The `linalg/hlsl` subpackage provides HLSL-style *types* only, no D3D projection builders.

**The path this guide assumes — mirror DirectXMath exactly.** Keep the book's row-vector
convention *and* its row-major storage, via Odin's storage directive:

```odin
Mat4 :: #row_major matrix[4, 4]f32   // in d3d_math.odin — the one place this is decided
```

`#row_major` changes only the in-memory layout (internally `[4][4]f32`; indexing, operators,
and math are identical) — but that makes `Mat4` byte-identical to `XMFLOAT4X4`, so every matrix
line in the book ports literally:

- You hand-roll the D3D view/projection matrices anyway (linalg's are GL-convention), and Luna
  *prints every matrix he uses* (ch 3 rotations/translations, ch 5 perspective, ch 20
  orthographic) — type them into `d3d_math.odin` exactly as printed.
- Concatenation reads like the book: `world_view_proj := world * view * proj`.
- Transforming a point is `v * M` (Odin defines both `v * M` and `M * v`; use `v * M`,
  matching HLSL's `mul(pos, M)`).
- **Transpose before every CB upload, exactly like the book** — `XMMatrixTranspose(...)` becomes
  `linalg.transpose(...)`, same line, same reason (row-major storage vs HLSL's column-major
  packing).

Storage-vs-convention SIMD trivia: the docs' "column-major utilizes SIMD effectively" claim
assumes Odin's native `M * v` convention; for row-vector `v * M`, row-major storage is the
SIMD-friendly pairing — the same reason DirectXMath is row-major. At this book's scale the
difference is noise; fidelity is the right basis for the choice.

(Filed for after the book: with Odin's *default* column-major storage, a row-convention matrix's
bytes come out as columns-of-R — exactly what HLSL wants — so the transpose step can be deleted
entirely. It's a one-line alias change plus removing the transposes, once you no longer need
your code to match the text.)

**The cost of the row-vector convention:** don't mix in linalg's *matrix builders*
(`matrix4_translate`, `matrix4_from_quaternion`, `matrix4_rotate`…) without transposing them
first — they're column-convention, i.e. the transpose of what your `d3d_math.odin` produces.
linalg's convention-agnostic operations are all safe and recommended: `inverse`, `transpose`,
`determinant`, `dot`, `cross`, `normalize`, `length`, quaternion ops.

### Vectors — a genuine simplification

Odin's fixed arrays are first-class math types: `[3]f32`/`[4]f32` have component-wise `+ - * /`,
scalar broadcasting, and **swizzle fields** (`v.xyz`, `v.xxyy`). There is **no load/store split**
— `XMFLOAT3` vs `XMVECTOR` and every `XMLoadFloat3`/`XMStoreFloat3` pair in the book simply
disappears. The same `[3]f32` lives in your vertex structs and does math.

### Constant-buffer layout

Same two rules as any D3D12 port, both manual:

1. Each CB allocation is 256-byte aligned:
   `calc_cb_size :: proc(n: int) -> int { return (n + 255) &~ 255 }`.
2. HLSL packs fields into 16-byte registers (a `float3` then a `float` shares one; two `float3`s
   don't). Port `Shaders/SharedTypes.h` once into a `shared_types.odin` with explicit `_pad`
   fields (Odin struct layout is C-like by default, so explicit padding works the same way).

Getting rule 2 wrong produces garbage transforms, not errors. Matrices go in transposed, same
as the book (see Matrices).

### COM ref counting (the ComPtr replacement)

Odin's vendor bindings give you the arrow syntax — `device->CreateCommandQueue(...)`,
`swapchain->Present(...)` — so calls read like the C++. Lifetimes are still manual:

- Any call that fills a `^^T` out-param (`CreateDevice`, `CreateCommittedResource`, `GetBuffer`,
  `QueryInterface`…) hands you a reference **you own**. Pair it with `obj->Release()` — `defer`
  for locals, or in your shutdown proc for long-lived fields.
- Passing an interface *into* a call does not add refs. Per-frame code is all borrowing;
  ownership lives in init/resize/shutdown only.
- `ComPtr::Reset()` in the book = `obj->Release(); obj = nil`.
- `swapChain1.As(&mSwapChain)` = `QueryInterface` → you now hold **two** interfaces; release the
  `IDXGISwapChain1` after upgrading.
- The one famous trap is in `OnResize` — see ch 4.

### Error handling

`ThrowIfFailed(hr)` → a small `hr_panic :: proc(hr: d3d12.HRESULT, loc := #caller_location)`
that panics on `hr < 0` with the code and location. `#caller_location` gives you free
file:line in the panic — nicer than the C++ original. Do this on day one.

### d3dx12.h

Don't port it. Odin struct literals with field names cover the `CD3DX12_*` initializers; write
tiny helpers (`transition_barrier(resource, before, after)`) the first time a pattern repeats,
and grow a `d3d12_util.odin` organically.

### Debug layer

Enable `ID3D12Debug` (and GPU-based validation while learning) from the first triangle.

On AMD (RDNA 4): AMD drivers are stricter than the NVIDIA cards the book was tested on — treat
every debug-layer warning as an error and your port ends up *more* correct than the original.
The book's shaders/features are vendor-neutral (no wave intrinsics, no NVAPI); the 9070 XT runs
everything including ch 26–27.

Bonus vs the Zig stack: `ID3D12InfoQueue1` (message callbacks → stderr) and DRED are **already
bound** in `vendor:directx/d3d12` — the ch 4 side quest needs no binding work here.

### Shaders

Two workable options — and unlike the Zig port, the book's own flow is available:

- **Mirror the book (recommended here):** `vendor:directx/dxc` binds `IDxcCompiler3`/`IDxcUtils`
  fully and ships `dxcompiler.dll` + `dxil.dll`. Port `d3dUtil::CompileShader` and the
  `ShaderLib::Init` table nearly line-for-line; you keep edit-shader-and-rerun iteration with no
  build step.
- **Precompile offline:** Odin has no `build.zig`-style build system, so offline compilation
  means an external script (justfile/PowerShell) running `dxc.exe` before `odin build`, then
  embedding blobs with `#load("shader.dxil")`. Fine, but it's extra tooling for less flexibility.

Either way, every permutation is a `-D` define (`ALPHA_TEST`, `SKINNED`, `DRAW_INSTANCED`,
`IS_SHADOW_PASS`) and all targets are `*_6_6`.

---

## Part I — Mathematical Prerequisites (ch 1–3)

**Runs anywhere** — no GPU, no Windows needed. Port the `C1_XMVECTOR`/`C2_XMMATRIX` console
demos as Odin programs or test procs asserting expected values. Skip `XMVerifyCPUSupport`.

### DirectXMath → Odin cheat sheet

Types: `XMVECTOR` → `[4]f32`, `XMFLOAT2/3/4` → `[2/3/4]f32` (same type for storage *and* math —
no load/store), `XMMATRIX`/`XMFLOAT4X4` → `matrix[4,4]f32` (ditto), quaternions →
`quaternion128`. `import "core:math/linalg"` for the procs below.

| DirectXMath (as used in book) | Odin | Note |
|---|---|---|
| `XMVectorSet(x,y,z,w)` | `[4]f32{x, y, z, w}` | |
| `XMVectorZero()` | `[4]f32{}` | zero-init is the default |
| `XMVectorReplicate(s)` / `SplatOne` | `[4]f32{s, s, s, s}` | |
| `XMVectorSplatX(v)` | `v.xxxx` | built-in swizzle |
| `XMVectorSwizzle<...>(v)` | `v.zyxw` etc. | |
| `u + v`, `u - v`, `k * v` | same — native array ops | |
| `XMVectorMultiplyAdd(a,b,c)` | `a*b + c` | |
| `XMVectorAbs/Cos/Sqrt/...` | `linalg.abs/cos/sqrt` … | element-wise variants in linalg |
| `XMVectorMin/Max/Lerp/Saturate` | `linalg.min/max/lerp`, `linalg.clamp(v, 0, 1)` | |
| `XMVector3Dot(u,v)` | `linalg.dot(u, v)` | returns scalar (no splat dance) |
| `XMVector3Cross(u,v)` | `linalg.cross(u, v)` | |
| `XMVector3Length / LengthSq` | `linalg.length / length2` | |
| `XMVector3Normalize(v)` | `linalg.normalize(v)` | `normalize0` returns 0 for 0 input |
| `XMVector3Greater(u,v)` | `u.x > v.x && …` or compare + reduce | |
| `XMVectorGetX(v)` | `v.x` | |
| `XMLoadFloat3` / `XMStoreFloat3` (etc.) | *(delete them)* | no load/store split in Odin |
| `XMMatrixIdentity()` | `matrix[4,4]f32(1)` | scalar → diagonal |
| `XMMatrixScaling/Translation/RotationX/Y/Z` | your `d3d_math.odin` | type them from the book, row-vector form (see Matrices) |
| `XMMatrixRotationAxis / RollPitchYaw` | `d3d_math.odin` | or `linalg.matrix4_from_quaternion` **transposed** |
| `A * B`, `XMMatrixMultiply(A,B)` | `A * B` | operator overloading — same left-to-right order (row-vector path) |
| `XMMatrixTranspose(M)` | `linalg.transpose(M)` | still needed before CB upload (with `Mat4 :: #row_major …`) — same as the book |
| `XMMatrixInverse(&det, M)` | `linalg.inverse(M)` | |
| `XMMatrixDeterminant(M)` | `linalg.determinant(M)` | |
| `XMMatrixLookAtLH / PerspectiveFovLH / OrthographicOffCenterLH` | your `d3d_math.odin` | linalg's are GL-convention ([-1,1] depth) — do not use for D3D |
| `XMVector3TransformCoord(v, M)` | `([4]f32{v.x, v.y, v.z, 1} * M).xyz` | wrap as `transform_coord` |
| `XMVector3TransformNormal(v, M)` | same with `w = 0` | wrap as `transform_normal` |
| `XMConvertToRadians(d)` | `math.to_radians(d)` | `core:math` |
| `XM_PI` etc. | `math.PI` | |
| `XMQuaternionRotationAxis` | `linalg.quaternion_angle_axis` | ch 22 |
| `XMQuaternionSlerp` | `linalg.quaternion_slerp` | ch 22 |
| `XMMatrixRotationQuaternion` | `linalg.matrix4_from_quaternion` + `transpose` | column-convention output — transpose for the row-vector path |

**Known gaps** (all small; the book derives each formula, so implementing them *is* the
exercise):

- D3D-convention view/projection builders (`look_at_lh`, `perspective_fov_lh`,
  `ortho_off_center_lh`) — the core of your `d3d_math.odin`; Luna prints all of them
- `XMMatrixReflect` / `XMMatrixShadow` (ch 11)
- `XMMatrixAffineTransformation` (ch 22–23) — compose scale · rotation · translation yourself
- everything from `DirectXCollision` (ch 16–17)
- `XMCOLOR` (packed 32-bit BGRA) → pack a `u32` yourself

### Chapter notes

- **Ch 1 Vector Algebra** — vector rows above. Enjoy deleting every load/store call.
- **Ch 2 Matrix Algebra** — matrix rows; `matrix[4,4]f32` semantics (column-major storage —
  reread the Matrices section so it doesn't surprise you in ch 6).
- **Ch 3 Transformations** — start `d3d_math.odin` here: rotation/translation/scaling matrices
  typed from the book's printed forms; verify an `S*R*T` chain against the book's numbers.

---

## Appendix A — Introduction to Windows Programming *(do between ch 3 and ch 4)*

**Depends on:** `core:sys/windows` only.

**Port notes:**

- Full surface available: `WNDCLASSEXW`, `RegisterClassExW`, `CreateWindowExW`, `ShowWindow`,
  `GetMessageW`/`PeekMessageW`, `TranslateMessage`, `DispatchMessageW`, `DefWindowProcW`,
  `WM_*` constants.
- Wide strings: window titles/class names are UTF-16 — `windows.utf8_to_wstring(...)`
  (or `L(...)` helpers); this is the one ergonomic difference from the ANSI-flavored Zig path.
- The `WndProc`: `wnd_proc :: proc "system" (hwnd, msg, wparam, lparam) -> LRESULT` — note
  `proc "system"` for the calling convention, and that a `"system"` proc has no default
  context (use `context = runtime.default_context()` inside if you need Odin features there).
- The book's appendix uses `GetMessage` (blocking); ch 4 switches to `PeekMessage` (game loop).
  Do both.

---

## Part II — Direct3D Foundations

### Ch 4 — Direct3D Initialization  ⟵ *the big front-load*

**Port first (becomes your permanent shared layer):**

- `GameTimer` — `windows.QueryPerformanceCounter/Frequency`, or `core:time` tick APIs. Trivial.
- `DescriptorUtil` — RTV/DSV heap wrappers now, CBV/SRV/UAV at ch 9. Handle math is
  `heap_start + index * increment_size`.
- The `D3DApp` equivalent — a struct + explicit init/shutdown procs; demos share the loop by
  copying it or via proc pointers.

**Agility SDK — probably optional for you:** on Windows 11 the inbox D3D12 runtime already
supports SM 6.6 (the book's baseline), so you can likely skip Agility entirely. If you do want
it (or are on Windows 10):

```odin
@(export) D3D12SDKVersion: u32 = 614
@(export) D3D12SDKPath: cstring = ".\\D3D12\\"
```

…and ship `D3D12Core.dll` in `.\D3D12\`. Verify the exports land in the exe's export table
(`dumpbin /exports`) — this is the fact to test, not assume.

**ComPtr traps concentrated in this chapter — the full list:**

1. **`OnResize` / `GetBuffer`.** Before `swapchain->ResizeBuffers(...)`, release every
   back-buffer reference (`for &b in buffers { b->Release(); b = nil }`) plus the depth buffer —
   or `ResizeBuffers` fails with `E_INVALIDARG` / "buffer still referenced". Each subsequent
   `GetBuffer` AddRefs; you own those again. Highest-density ref-counting spot in the book.
2. **`FlushCommandQueue` before releasing anything the GPU might still read** (resize,
   shutdown). Signal fence → `SetEventOnCompletion` → `WaitForSingleObject`. Port it exactly.
3. **`.As()` upgrades** = `QueryInterface` (AddRefs) — release the old interface. Applies to
   `IDXGISwapChain1` → newer, `ID3D12Debug` → `ID3D12Debug1`, and `ID3D12Device` →
   `ID3D12Device5` at ch 27.
4. **Adapter enumeration** — each `EnumAdapters` result is a reference; release the ones you
   don't keep.
5. **Shutdown order** — flush queue first; children before parents; device last;
   `ReportLiveObjects` in debug to catch leaks.

**imgui:** add Capati/odin-imgui with its win32 + dx12 backends. Call the backend's WndProc
handler first in your `wnd_proc`; init/new-frame/render mirror the book's `D3DApp` wiring.
Per-demo UI is `im.text/slider_float/checkbox` — 1:1 with the book's calls.

**Verify:** cornflower-blue window, FPS in title bar, repeated resize works (trap #1), debug
layer silent.

#### Side quest: debug-layer output to stderr

Same motivation as ever (debug layer speaks `OutputDebugString`; lightweight editors hear
nothing) — but in Odin this is nearly free, because **`ID3D12InfoQueue1` and
`RegisterMessageCallback` are already bound** in `vendor:directx/d3d12`:

- `QueryInterface` the device for `IInfoQueue1`, register a callback
  (`proc "system"` — set up a context inside before calling `fmt.eprintln`), print
  severity/ID/description to stderr. Vulkan-validation-layer experience achieved.
- `SetMuteDebugOutput(true)` to stop the duplicate debugger-channel output;
  `SetBreakOnSeverity` for ERROR/CORRUPTION when a debugger is attached.
- DXGI's separate info queue (leak reports at exit) still needs `dxgidebug.dll` — check the
  dxgi bindings; poll at shutdown if present.

**DRED** (`ID3D12DeviceRemovedExtendedData` — breadcrumbs + page faults on device removal) is
also already bound; enabling it is a few lines and worth doing before the compute chapters.
DirectX Dump Files remain preview-only (preview Agility SDK + preview driver + preview PIX) —
park until retail (~Fall 2026).

### Ch 5 — The Rendering Pipeline

Theory, no demo. Two porting hooks: this chapter *derives the perspective matrix* — implement
`perspective_fov_lh` in `d3d_math.odin` from it — and explains the data you'll lay out in
`shared_types.odin` at ch 6.

### Ch 6 — Drawing in Direct3D  *(Box, BoxGrid)*

**Port first:**

- `UploadBuffer` — mapped upload-heap buffer with the 256-byte CB stride. Map once, copy per
  frame, never unmap. ~40 lines.
- `MeshGeometry`/`SubmeshGeometry` (from `MeshUtil.h`) — buffer views struct; stash submesh
  bounds as plain `[3]f32` min/max for now (functional at ch 16).
- **Buffer-upload helper** (replaces DirectXTK12 `CreateStaticBuffer`): default-heap resource +
  upload-heap staging + `CopyBufferRegion` + barrier. **Keep the staging buffer alive until the
  copy's fence completes** — the #2 lifetime bug after the resize trap.
- The dxc-based `CompileShader` (per the Shaders convention — `vendor:directx/dxc` makes this a
  near-1:1 port of `d3dUtil::CompileShader`).
- Root signature + PSO + input layout. Semantic names in `D3D12_INPUT_ELEMENT_DESC` are
  `cstring`s.

**Watch out:**

- First contact with CB packing and transpose-on-upload. A sheared or garbled box = one of those
  two (or a `Mat4` that isn't `#row_major` — check the alias). Verify the CB bytes once and
  trust it afterward.
- `Camera` first appears (simple form); port what's needed, full version at ch 15.

### Ch 7 — Drawing Part II  *(Shapes, Waves)*

**New this chapter:**

- The **FrameResource** pattern (per-frame allocator + upload buffers + fence value) — the
  book's core CPU/GPU parallelism idiom; internalize it here.
- `MeshGen` (procedural box/grid/sphere/cylinder) — pure math; with Odin's swizzles it ports
  cleanly.
- Render-item lists (`[dynamic]RenderItem`, `core:mem` allocators as you prefer).
- Waves CPU sim: `parallel_for` → serial first; `core:thread` later if you care.

**Watch out:** fence bookkeeping — wait only when the frame-resource ring wraps. Off-by-one =
flicker or hangs.

### Ch 8 — Lighting  *(LitShapes, LitWaves)*

**New this chapter:** `Light`/`MaterialData` in `shared_types.odin` — the float3-next-to-scalar
packing minefield at its worst; normals in `MeshGen`. Nothing new externally.

### Ch 9 — Texturing  *(Crate, TexturedShapes, TexWaves)*

**Port first:**

- **DDS loader** — the biggest Odin-specific gap: nothing in `core:`/`vendor:` reads DDS
  (stb_image doesn't either). Hand-roll: magic + `DDS_HEADER` + optional DX10 header + map the
  handful of formats the book's ~60 textures use (BC1/BC3/BC5/BC7 + a few uncompressed), then
  compute per-mip pitches. Reference implementations: zwindows `dds_loader.zig` or DirectXTK12's
  `DDSTextureLoader.cpp`. Budget 200–300 lines / an evening or two. (Check for a community Odin
  DDS package first — the situation may have improved.)
- **Texture upload helper** (replaces `ResourceUploadBatch`): `GetCopyableFootprints` → copy
  into upload buffer respecting the **256-byte-aligned row pitch** (row by row, not one copy) →
  `CopyTextureRegion` per subresource → barrier. DDS mips are pre-baked; no mip generation
  anywhere in the book.
- `TextureLib`/`MaterialLib` — name→resource maps (`map[string]^d3d12.IResource`); load only
  what the chapter needs.
- CBV/SRV/UAV heap in `DescriptorUtil`; static samplers array.

**Watch out:** the book's shaders index `ResourceDescriptorHeap[]` (SM 6.6 dynamic resources) —
the shader-visible heap layout is the contract; keep indices identical to the book's or textures
silently swap.

### Ch 10 — Blending  *(BlendDemo)*

**New this chapter:** blend/alpha-test PSO variants — config, not code.

### Ch 11 — Stenciling  *(Stenciling)*

**New this chapter:**

- Depth/stencil PSO states.
- Hand-roll `matrix_reflect(plane)` / `matrix_shadow(plane, light)` into `d3d_math.odin` —
  the chapter derives both. Keep them in the row-vector form you standardized on.

### Ch 12 — The Geometry Shader  *(BillboardsGS)*

**New this chapter:** GS stage in the PSO; a texture2DArray DDS — your DDS loader + upload
helper must handle `array_size * mip_levels` subresources. Extend them now if you cut that
corner.

### Ch 13 — The Compute Shader  *(VecAddCS, Blur, WavesCS)*

**New this chapter:**

- UAVs + compute PSOs/root signatures.
- `VecAddCS`: readback heap + `Map` after fence (the book's one GPU→CPU copy).
- `Blur`: UAV/SRV descriptor ping-pong; `WavesCS`: ch 7 waves on GPU.

**Watch out:** UAV barriers between dependent dispatches — the debug layer won't always catch a
missing one; AMD shows you artifacts instead. (You enabled DRED in ch 4, right?)

### Ch 14 — The Tessellation Stages  *(BasicTessellation, BezierPatch)*

**New this chapter:** HS/DS stages, control-point patch topology, `hs_6_6`/`ds_6_6` entries in
your shader table. Nothing else new.

---

## Part III — Topics

### Ch 15 — First Person Camera

No demo — finish the `Camera` you stubbed at ch 6 (strafe/walk/pitch/rotate-Y, view rebuild).
Pure `d3d_math` + linalg. Portable-laptop chapter.

### Ch 16 — Instancing and Frustum Culling

**Port first:**

- The book centralizes shaders/PSOs here (`ShaderLib`/`PsoLib`) — in Odin these are natural
  tables: `map[string]^dxc.IDxcBlob` and a PSO-desc table.
- **`collision.odin`**: `Bounding_Box` (center/extents), `Bounding_Frustum` from the projection
  matrix, box-vs-frustum test. Book explains the plane math; `DirectXCollision.h` is the
  reference if stuck.

**New this chapter:** structured-buffer instance data (SRV — no 256-byte/packing rules).

**Watch out:** frustum is extracted in view space, transformed to local space with
`inverse(world * view)` — wrong space = flickering culling. Also mind conventions: your
frustum-extraction code must match the row-vector matrices you build.

### Ch 17 — Picking

**New this chapter:** ray/AABB and ray/triangle (Möller–Trumbore) tests into `collision.odin`.
Picking ray: screen → NDC → view → local, all `inverse` + `v * M`.

### Ch 18 — Cube Mapping  *(C18C19_CubeAndNormalMapping, DynamicCubeMap)*

**New this chapter:**

- Cubemap DDS (6 array slices × mips — the ch 12 array path covers it) + TextureCube SRV.
- `CubeRenderTarget` (per-demo): 6 RTVs into array slices, per-face cameras, extra pass
  constants.

**Watch out:** sky PSO uses `LESS_EQUAL` depth + no culling.

### Ch 19 — Normal Mapping

Nothing structural — tangents (already in `MeshGen`) + more DDS. Breather; pay down helper debt.

### Ch 20 — Shadow Mapping  *(Shadows)*

**New this chapter:**

- `ShadowMap` helper: depth-only pass, DSV+SRV on one resource, null RTV, viewport switch.
- Depth-bias PSO — book values are NVIDIA-tuned; tweak `DepthBias`/`SlopeScaledDepthBias` on
  the 9070 XT if you see acne. Expected variance, not a bug.
- `ortho_off_center_lh` lands in `d3d_math.odin` (the chapter derives it).

**Watch out:** shadow map state ping-pongs `DEPTH_WRITE` ↔ `PIXEL_SHADER_RESOURCE` every frame.

### Ch 21 — Ambient Occlusion  *(Ssao)*

**New this chapter:** normal/depth prepass targets, random-vector texture from CPU memory (your
ch 9 upload helper, from a byte slice), offset vectors CB, bilateral blur ping-pong. Most
render-target plumbing so far; nothing new in dependencies.

### Ch 22 — Quaternions  *(QuatDemo)*

**New this chapter:**

- `quaternion128` + `linalg.quaternion_angle_axis` / `quaternion_slerp` /
  `matrix4_from_quaternion` (**transpose** the matrix result — column-convention, see Matrices).
- Hand-rolled `affine_transformation` (scale · rotation-about-origin · translation).
- Keyframe animation helper — lerp/slerp between keys.

### Ch 23 — Character Animation  *(SkinnedMesh)*

**New this chapter:**

- `.m3d` parser + `SkinnedData`: the format is plain text with labeled sections —
  `core:strings` + `strconv`; a pleasant evening.
- Skinned vertex adds `bone_weights: [3]f32` + `bone_indices: [4]u8` (4th weight =
  `1 - sum`; input layout slot is `R8G8B8A8_UINT`).
- Bone palette CB + the `SKINNED` shader define.

### Ch 24 — Terrain Rendering  *(Terrain)*

**New this chapter:** `.raw` heightmap = flat `[]u16` (`os.read_entire_file` + transmute/slice
reinterpret; ~10 lines). Blend maps are more DDS. Reuses ch 14 tessellation + `collision.odin`
patch culling.

### Ch 25 — Particle Systems  *(ParticlesCS)*

**New this chapter:** structured-buffer particle pools; emit/update/post-update CS entries;
blend PSOs from ch 10; `Random.h` → `core:math/rand`.

**Watch out:** UAV barriers between the three dispatches.

### Ch 26 — Amplification & Mesh Shaders  *(ParticlesMS, TerrainMS)*

**New this chapter:**

- `IGraphicsCommandList6->DispatchMesh` (bound), `ms_6_6`/`as_6_6` targets,
  `CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS7)`.

**Watch out — the PSO changes shape:** mesh-shader PSOs go through
`ID3D12Device2->CreatePipelineState` with a **pipeline state stream** — packed, alignment-
sensitive `{subobject-type tag, payload}` records. The bindings define the enum/desc types but
there's no `CD3DX12_PIPELINE_STATE_STREAM` equivalent — build the stream struct yourself with
`#align` / explicit padding. Fiddliest struct-layout task in the port (same as in Zig).

### Ch 27 — Ray Tracing  *(IntroRayTracing, HybridRayTracing)*

**New this chapter:**

- DXR, all bound: `ID3D12Device5` (via `QueryInterface` — **new reference, release at
  shutdown**), `CreateStateObject`, BLAS/TLAS builds, shader binding table, `DispatchRays`.
- `lib_6_6` target (DXR shaders are libraries — no `-E`; one more shader-table variant).
- The `Prepass` module (hybrid G-buffer) first appears.

**Watch out:**

1. SBT alignment — records 32-byte aligned, table start 64-byte aligned; use named constants.
2. Scratch + result AS buffers live until the build's fence — same rule as the ch 6 staging
   buffer.
3. UAV barrier between BLAS and TLAS builds.

---

## Appendices B–D

- **B (HLSL reference)** — your HLSL is unchanged from the book's.
- **C (Analytic geometry)** — pairs with `collision.odin`.
- **D (Selected solutions)** — doing the exercises in Odin is where the port pays off.

## Hand-rolled code inventory

| Piece | First needed | Size | Replaces |
|---|---|---|---|
| `hr_panic` + debug layer + InfoQueue1→stderr | ch 4 | tiny | `ThrowIfFailed` + VS output window (bindings pre-exist) |
| `GameTimer`, `DescriptorUtil`, app loop | ch 4 | medium | book's Common |
| `d3d_math.odin` (row-vector matrix builders, grows: ch 3 → 5 → 11 → 20) | ch 3 | small | DirectXMath conventions |
| `UploadBuffer` + `calc_cb_size` | ch 6 | small | book's Common |
| Static-buffer upload helper | ch 6 | small | DirectXTK12 `CreateStaticBuffer` |
| `shared_types.odin` (grow per chapter) | ch 6 | small | `SharedTypes.h` |
| dxc `compile_shader` + shader table | ch 6 | small | `d3dUtil::CompileShader` + `ShaderLib` (bindings pre-exist) |
| **DDS parser** | ch 9 | **medium-large** | DirectXTK12 `DDSTextureLoader` — Odin's biggest gap |
| Texture upload helper (mips → arrays → cubes → from-memory) | ch 9 (12, 18, 21) | medium | DirectXTK12 `ResourceUploadBatch` |
| `matrix_reflect`/`matrix_shadow` | ch 11 | tiny | DirectXMath |
| `collision.odin` (AABB, frustum, ray tests) | ch 16–17 | small | DirectXCollision |
| `affine_transformation` | ch 22 | tiny | DirectXMath |
| `.m3d` parser + `SkinnedData` | ch 23 | medium | book's Common |
| `.raw` heightmap reader | ch 24 | tiny | book code |
| Pipeline-state-stream struct | ch 26 | small-fiddly | `CD3DX12_PIPELINE_STATE_STREAM` |

## Odin vs Zig for this port — the honest one-paragraph comparison

Odin starts ahead: `vendor:` ships with the compiler (no zwindows-on-0.16 prerequisite), dxc is
fully bound (the book's shader flow ports 1:1), InfoQueue1/DRED are pre-bound (the stderr side
quest is trivial), operator overloading keeps math readable, and the load/store split disappears
(one vector type, one matrix type — with `Mat4 :: #row_major matrix[4,4]f32` it's byte-identical
to DirectXMath, so even the transpose-on-upload reads line-for-line with the book). It gives two
things back: **no DDS loader anywhere** (the one genuinely missing piece — an evening or two of
format parsing before ch 9), and a **math-library mismatch** — `core:math/linalg`'s builders are
GL-flavored column-vector, so the view/projection/rotation matrices come from your own
`d3d_math.odin` (typed from the book's printed forms) rather than the standard library, and
linalg is demoted to vectors, quaternions, and convention-agnostic ops. Both are manageable;
neither is hidden. Where Zig wins: zwindows hands you the DDS loader, and zmath *is* a
DirectXMath port — no convention decisions to make at all.
