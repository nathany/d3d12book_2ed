# Porting Luna's *Introduction to 3D Game Programming with DirectX 12* (2nd ed.) to Odin

A chapter-by-chapter companion for porting the book's C++ samples to Odin by hand, as a learning
exercise. It deliberately does **not** port the code for you — it tells you what to port first,
which library replaces what, and where the traps are.

Worked implementations of every demo live in [`odin_port/`](odin_port/), one package per demo.
Treat them as an answer key: write your own version first, then compare. Most chapters below
end with a **Reference port** note covering what that implementation ran into — the things
worth knowing before you lose an evening to them, and what a correct result looks like when
you arrive.

## The stack

| Book dependency                                                                                 | Odin replacement                                                                         | Notes                                                                                                                                         |
| ----------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| Win32 (`windows.h`)                                                                             | `core:sys/windows`                                                                       | Comprehensive; binds the wide (`...W`) variants                                                                                               |
| D3D12 / DXGI                                                                                    | `vendor:directx/d3d12`, `vendor:directx/dxgi`                                            | Ships with the compiler. Covers everything the book uses, incl. DXR & mesh shaders — plus `IInfoQueue1` and DRED (see ch 4 side quest)        |
| dxc COM API (runtime shader compile)                                                            | `vendor:directx/dxc`                                                                     | **Fully bound**, and `dxcompiler.dll`/`dxil.dll` ship in the vendor folder — the book's runtime-compile flow ports 1:1 |
| DirectXMath / SimpleMath                                                                        | built-in `matrix[4,4]f32` + `[N]f32` arrays + `core:math/linalg`                         | Operator overloading exists! But conventions differ — read the Matrices section carefully                                                     |
| DirectXCollision                                                                                | *hand-roll* (small)                                                                      | Needed at ch 16–17                                                                                                                            |
| Dear ImGui 1.85 + Win32/DX12 backends                                                           | community **Capati/odin-imgui** (bundles 1.92.x-docking, includes win32 + dx12 backends) | Not in vendor; the book's widget calls map 1:1                                                                                                |
| DirectXTK12 (`ResourceUploadBatch`, `CreateStaticBuffer`, `DDSTextureLoader`, `GraphicsMemory`) | *hand-roll*                                                                              | Two small helpers — **plus a DDS parser**: nothing in `core:`/`vendor:` reads DDS, the port's biggest single gap (ch 9)                       |
| PPL (`parallel_for`)                                                                            | serial loop or `core:thread`                                                             | Only the CPU Waves demos (ch 7–12)                                                                                                            |
| Agility SDK 614 (`D3D12SDKVersion` export)                                                      | optional                                                                                 | See ch 4 — on Windows 11 the inbox runtime already has SM 6.6; ship Agility only if you need it                                               |

No version juggling: `vendor:` and `core:` track the Odin compiler itself, so there is no
third-party binding layer to keep in sync with your compiler version. Grab a current Odin
release and everything above is present.

## Global conventions (read once, applies everywhere)

### Matrices — the big one, read twice

Start from what the **book** does, on both sides of the CPU/GPU boundary:

| | CPU (DirectXMath → your Odin) | GPU (HLSL in this book) | Match? |
|---|---|---|---|
| Vector convention | row-vector (`v * M`) | row-vector (`mul(v, M)`) | ✅ |
| Matrix storage | row-major | column-major (HLSL default) | ❌ |

**The convention agrees; only the storage disagrees — and that is the entire reason the transpose
exists.** `XMMatrixTranspose` before a constant-buffer write is a pure byte-layout fix; it has
nothing to do with row-vector vs column-vector.

Worth spelling out, because it's a common mix-up: HLSL has **no default vector convention**.
`mul()` is a generic matrix multiply — `mul(v, M)` is 1×4 · 4×4 (row vector), `mul(M, v)` is
4×4 · 4×1 (column vector), and both compile. Luna chose row-vector and the shaders use it
uniformly (`mul(float4(vin.PosL, 1.0f), gWorld)`, `mul(posW, gViewProj)`, …); there is not a
single `mul(matrix, vector)` in `Shaders/`. Column-major *storage*, by contrast, is a real HLSL
default, and the book leaves it alone — no `row_major` keyword, no `#pragma pack_matrix`, and
the `-Zpr`/`-Zpc` dxc flags sit commented out in `d3dUtil.h`.

Odin then differs from DirectXMath on *both* axes, and they interact:

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
   fields, and mark every GPU-facing struct **`#packed`**.

`#packed` is not optional, and the reason is an Odin-specific trap: Odin's `matrix` types are
SIMD-aligned — `align_of(Mat4)` is **32** — so any plain struct embedding one gets phantom
padding HLSL doesn't have (a `float4x4` at byte 48 silently moves to 64). The book's structs
hand-place every field at its natural offset already, so `#packed` strips only the phantom
alignment. Then pin the sizes: `#assert(size_of(Per_Pass_CB) == 1552)` turns a dropped pad
field into a compile error instead of garbage transforms — which is what getting rule 2 wrong
produces at runtime, never an error message. Matrices go in transposed, same as the book (see
Matrices).

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

Worth knowing early: `ID3D12InfoQueue1` (message callbacks → stderr) and DRED are **already
bound** in `vendor:directx/d3d12`, so the ch 4 side quest needs no binding work.

### Odin-side leak detection (Tracking_Allocator)

The D3D debug layer catches COM leaks; `core:mem.Tracking_Allocator` catches Odin heap leaks —
the analogue of the C++ demos' CRT debug-heap check. Worth wiring up as soon as you have a run
loop, which in practice means ch 4; the reference port didn't get to it until ch 7 and
promptly found a bug it had been carrying since ch 4 (below).

The shape is small enough to write once and forget (`common/mem_track.odin` in the reference
port): wrap **both** `context.allocator` and `context.temp_allocator` at the top of `main` in
debug builds, and report at the very end — *before* `os.exit`, since `os.exit` skips defers.
Clean runs stay silent, leaks print with their allocation site, and bad frees (double free, or
freeing a pointer you only borrowed) **panic at the offending call site**, which is
`core:mem`'s default `bad_free_callback`.

**Context plumbing — the part that isn't obvious.** Odin's context is implicit but it is
not global state: it's a hidden parameter passed down `proc "odin"` call chains. A
`proc "system"` or `proc "c"` callback is entered *from C*, which severs that chain, so the
callback has to rebuild a context itself.

Rebuilding it with `runtime.default_context()` hands back the *raw* allocators, and that
doesn't merely skip tracking — it corrupts it in both directions: memory allocated tracked
but freed raw leaves a phantom leak in the report, while the reverse panics on a perfectly
valid free. So `d3d_app_init` captures main's context into `common.app_context`, and the
WndProc and ImGui SRV callbacks restore that instead. It's the same move as parking
`^D3D_App` in `GWLP_USERDATA`: state that can't ride through the C boundary gets left where
the callback can find it.

One deliberate exception: the `IInfoQueue1` debug callback keeps `default_context()`,
because D3D12 may invoke it from driver threads and `app_context` carries main's
*thread-local* temp arena. That callback only prints, so nothing is lost.

Two more details that make it correct:

- **Per-frame `free_all(context.temp_allocator)`** at the bottom of the `d3d_app_run` loop.
  Adding the tracker exposed a latent bug — nothing ever reset the temp arena, so
  C7_Waves' per-frame vertex slice (~450 KB) grew it without bound. The arena answers
  `.Free_All` to `Query_Features`, so the temp tracker sets `clear_on_free_all` and empties
  its map each frame too; steady-state overhead is near zero.
- **Init order:** `tracking_allocator_init` must run while `context.allocator` is still the
  raw heap allocator, so the trackers' own bookkeeping stays untracked. The tracker's mutex
  is not reentrant — self-tracking deadlocks.

The C1–C3 test packages need none of this: `odin test` already wraps each test in its own
tracking allocator (`ODIN_TEST_TRACK_MEMORY`, on by default).

### Knowing a demo is correct

Five checks per demo, and the last two are the ones that get skipped:

1. **The render matches the C++.** Run the book's build alongside yours — framing, colors, and
   camera should agree, not merely look plausible.
2. **Repeated resizing still works.** A single resize proves nothing; the `OnResize`/`GetBuffer`
   ref-counting trap (ch 4) usually survives one and dies on the fifth.
3. **Escape exits cleanly**, with code 0. Note the book's `MsgProc` handles `VK_ESCAPE` on
   `WM_KEYUP`, not `WM_KEYDOWN`.
4. **The debug layer is silent.** Piping `InfoQueue1` to stderr (ch 4 side quest) gives you this
   for free in any terminal; treat every warning as an error and your port ends up more correct
   than the original.
5. **Both leak reports are silent** — `ReportLiveObjects` for COM objects (ch 4) and the
   tracking allocator for Odin heap memory (above).

That last one has a catch worth internalizing: a detector you have never seen fire is not
evidence of anything. Leak a fence on purpose once, and separately leak a `make()` allocation,
and confirm each report actually names it. Then silence means something.

### Shaders

Two workable options, and the book's own flow is one of them:

- **Mirror the book (recommended here):** `vendor:directx/dxc` binds `IDxcCompiler3`/`IDxcUtils`
  fully and ships `dxcompiler.dll` + `dxil.dll`. Port `d3dUtil::CompileShader` and the
  `ShaderLib::Init` table nearly line-for-line; you keep edit-shader-and-rerun iteration with no
  build step.
- **Precompile offline:** Odin has no integrated build system, so offline compilation
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
| `XMVectorAbs/Cos/Sqrt/...` | `linalg.abs/cos/sqrt` … | element-wise variants in linalg (`extended.odin`) |
| `XMVectorLog/Exp` | `linalg.log2` / `linalg.exp2` | **base 2** in DirectXMath despite the names; Odin computes them via `ln`/`exp`, so even power-of-two results land an ulp off — assert with tolerance, not equality |
| `XMVectorPow(u, p)` | per-lane `math.pow` | no vector-exponent pow in linalg |
| `XMVector3ComponentsFromNormal` | `linalg.projection(w, n)` + `w - proj` | n must be unit length |
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
  **Reference port:** `odin_port/C1_XMVECTOR` (`odin test odin_port/C1_XMVECTOR`) — one
  `.odin` file per C++ variant (including the three commented-out mains), one `@(test)` each,
  asserting values captured from the C++ demo's output. Float-compare helpers live in
  `odin_port/test_util`: exact values use `testing.expect_value`, while cout-rounded values
  use `expect_close` with eps sized to the 6th significant digit.
- **Ch 2 Matrix Algebra** — matrix rows; `matrix[4,4]f32` semantics (column-major storage —
  reread the Matrices section so it doesn't surprise you in ch 6).
  **Reference port:** `odin_port/C2_XMMATRIX`. With `Mat4 :: #row_major matrix[4,4]f32` the
  C++ `XMMATRIX A(…)` literal is typed with the same 16 numbers in the same positions, `A * B`
  stays `A * B`, and the demo's printed rows are your rows — zero convention edits. Also
  confirmed there: `#row_major` matrices pass straight through linalg's generic
  `transpose`/`determinant`/`inverse`.
- **Ch 3 Transformations** — start `d3d_math.odin` here: rotation/translation/scaling matrices
  typed from the book's printed forms; verify an `S*R*T` chain against the book's numbers.
  **Reference port:** `odin_port/C3_TRANSFORMATIONS` + `odin_port/d3d_math` — the builders
  typed in the book's row-vector forms and checked against a DXM ground-truth program,
  including Rodrigues' rotation-axis form and `RollPitchYaw = Rz·Rx·Ry` left-to-right.
  `S * Ry * T` reads exactly as the book writes it, and there's a deliberate negative assert
  showing the reversed spelling really is a different transform. One approximation note if
  your numbers disagree in the 7th digit: `XMScalarSinCos` puts cos(π/4) at 0.70710671 versus
  core:math's 0.70710677 — same category as `XMVectorCos`.

---

## Appendix A — Introduction to Windows Programming *(do between ch 3 and ch 4)*

**Depends on:** `core:sys/windows` only.

**Port notes:**

- Full surface available: `WNDCLASSEXW`, `RegisterClassExW`, `CreateWindowExW`, `ShowWindow`,
  `GetMessageW`/`PeekMessageW`, `TranslateMessage`, `DispatchMessageW`, `DefWindowProcW`,
  `WM_*` constants.
- Wide strings: window titles/class names are UTF-16 — `windows.utf8_to_wstring(...)` for
  runtime strings, `windows.L("…")` for literals.
- The `WndProc`: `wnd_proc :: proc "system" (hwnd, msg, wparam, lparam) -> LRESULT` — note
  `proc "system"` for the calling convention, and that a `"system"` proc has no default
  context (use `context = runtime.default_context()` inside if you need Odin features there).
- The book's appendix uses `GetMessage` (blocking); ch 4 switches to `PeekMessage` (game loop).
  Do both.

**Reference port:** `odin_port/APPENDIX_A` (`odin run odin_port/APPENDIX_A`) — the
appendix-text program written with `d3dApp.cpp`'s conventions, since no Appendix A sample
ships in the 2nd ed.

Small things you'll hit: plain `RegisterClassW`/`WNDCLASSW` are bound, not just the Ex
variants. `windows.L("…")` is `intrinsics.constant_utf16_cstring`, i.e. compile-time wide
literals. `IDI_APPLICATION`/`IDC_ARROW` are typed as `cstring`, so cast `win._IDI_APPLICATION`
(a `rawptr`) to `LPCWSTR` for the W loaders. `GetMessageW` returns `INT`, so the book's `-1`
error check ports directly. And Odin makes unreachable code a compile error — worth knowing
before you temporarily inject an error-path test and can't compile.

The reference port keeps the console subsystem deliberately, for the ch 4 stderr story; use
`-subsystem:windows` for ship builds. Fatal errors go to stderr *and* a `MessageBoxW`, via a
`report_error` helper — a convention every later demo inherits.

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

**Reference port (part 1 — core):** `odin_port/C4_Init_Direct3D` + `odin_port/common`
(`odin run odin_port/C4_Init_Direct3D -debug`).

The C++ virtual base class becomes struct `D3D_App` with proc-pointer virtuals (`update` and
`draw`, plus optional mouse hooks); demos embed it via `using base: common.D3D_App` and cast
back, which is Odin's subtype-polymorphism idiom. The `GetApp()` singleton becomes a `^D3D_App`
parked in `GWLP_USERDATA` — a plain thin pointer, no indirection needed. Both `wnd_proc` and
the InfoQueue1 callback have to establish a context on entry; see the leak-detection section
for which context each one wants, and why that choice matters more than it looks.

COM discipline is manual and pervasive: enumerated adapters released when not kept, QI-upgrades
releasing the old interface, and `d3d_app_shutdown` releasing children-before-device after a
queue flush.

Correct looks like: pixel-exact LightSteelBlue, five programmatic resizes surviving, the debug
layer enabled with zero messages on stderr, Escape → clean exit. Expect a few thousand fps on
a modern card (~8900 on a 9070 XT) since the demo draws nothing. One gotcha to save you a
compile error: vendor's `PFN_MESSAGE_CALLBACK` is `proc "c"` (cdecl), not `"system"`.

**Reference port (part 2 — ImGui):** the Options panel with frame stats plus VideoMemoryInfo
via `QueryVideoMemoryInfo`. (The GraphicsMemoryStatistics section has to wait for the ch 6–7
upload arena.) Capati/odin-imgui is vendored at `odin_port/libs/imgui` with the win32+dx12
backends; building it needs Python, premake5, and MSBuild, with steps in `odin_port/README.md`.

Expect one structural surprise: Dear ImGui 1.92's DX12 backend replaced the book's single-SRV
`Init` with an `InitInfo` struct whose `SrvDescriptorAllocFn`/`FreeFn` callbacks map *exactly*
onto `CbvSrvUavHeap.NextFreeIndex`/`ReleaseIndex`. Where the book's C++ reaches for a
singleton, you pass the heap explicitly through `InitInfo.UserData`. `WndProcHandler` still
hooks the message pump first, as in `MainWndProc`.

Shutdown order matters here and bites quietly: ImGui before the heap before the base, so the
SRV free callbacks still have a live heap to release into.

If you build the bindings yourself against ImGui 1.92.8, expect `error C2159` — the premake
script patches `imgui_impl_win32.cpp` by hardcoded line numbers that have gone stale. Patching
by pattern instead fixes it (worth upstreaming).

**DXC version note (checked 2026-07):** the vendor folder ships dxcompiler.dll **1.6.2112
(Dec 2021)** — old, but it postdates SM 6.6 (added in 1.6.2104), so it should compile the
book's shaders. The repo's `External\dxc\bin\x64` has 1.9.2602 (restored via NuGet for the
C++ demos); if 1.6 misbehaves, copy the newer DLLs next to the exe — exe-dir DLL search
beats everything. *(Resolved at ch 6: vendor 1.6 compiles the SM 6.6 shaders fine,
PDB output included — pinned next to the exe, fallback not needed. See the ch 6 note.)*

#### Side quest: debug-layer output to stderr

Same motivation as ever (debug layer speaks `OutputDebugString`; lightweight editors hear
nothing) — but in Odin this is nearly free, because **`ID3D12InfoQueue1` and
`RegisterMessageCallback` are already bound** in `vendor:directx/d3d12`:

- `QueryInterface` the device for `IInfoQueue1`, register a callback
  (`proc "system"` — set up a context inside before calling `fmt.eprintln`), print
  severity/ID/description to stderr. Vulkan-validation-layer experience achieved.
- `SetMuteDebugOutput(true)` to stop the duplicate debugger-channel output — **not bound**
  for the D3D12 info queue in vendor (harmless: that channel is only visible to debuggers).
  `SetBreakOnSeverity` for ERROR/CORRUPTION when a debugger is attached.
- **Leak reports (implemented & verified at ch 4):** vendor ships `dxgidebug.odin` with
  `IDXGIDebug.ReportLiveObjects` and the DXGI `IInfoQueue` fully bound — only the entry
  point is missing, and the trap is its location: **`DXGIGetDebugInterface1` is exported by
  `dxgi.dll`** (resolve via `GetModuleHandleW` + `GetProcAddress`), while the similarly
  named `DXGIGetDebugInterface` (no "1") is the one in `dxgidebug.dll`. At the end of
  `d3d_app_shutdown`: `ReportLiveObjects(DEBUG_ALL, .ALL)`, then poll the DXGI info queue
  (two-call `GetMessage`) onto stderr. A clean run prints nothing; a deliberately leaked
  fence prints `Live ID3D12Fence at …, Refcount: 1` plus the device it keeps alive.
  Independent backstop: if anything leaks past process exit, the D3D12 layer's "Process is
  terminating. Using simple reporting" warnings arrive through the InfoQueue1 callback too.
- **DRED enabled at ch 4** (`IDeviceRemovedExtendedDataSettings`, pre-bound, four lines,
  before device creation) — auto-breadcrumbs + page-fault data will pay off at the compute
  chapters.

**Proving the pipe works — how to simulate a debug-layer error:**

1. **Commit a real, recoverable API mistake:** omit the `PRESENT → RENDER_TARGET` barrier
   in `Draw` (a comment at that barrier in `C4_Init_Direct3D` marks the spot). Validation
   fires at `ExecuteCommandLists`: two ERRORs per frame on stderr — id 538
   `INVALID_RESOURCE_STATE` (with actual/expected/missing state bits spelled out) and
   id 527 (the closing barrier's before-state mismatch). Thousands of messages in seconds,
   fully readable in a terminal, no Visual Studio involved. Note the demo keeps "working"
   visually on the 9070 XT despite the errors — exactly the
   undefined-behavior-that-happens-to-work the debug layer exists to catch; another driver
   may show garbage for the same code.
2. **`ID3D12InfoQueue::AddApplicationMessage(severity, text)`** injects a custom message
   through the same queue — fires the callback without any API misuse. Tests the plumbing,
   not the validator; useful as a permanent one-line startup self-check.
3. **Escalations:** `SetBreakOnSeverity(ERROR)` to stop a debugger on the offending call
   (see below); GPU-based validation (`SetEnableGPUBasedValidation`, the line the book
   leaves commented out) catches what CPU validation can't — e.g. ch 13's missing UAV
   barriers.

**"When a debugger is attached" means a CPU-side user-mode debugger** — Visual Studio,
WinDbg, RAD Debugger, x64dbg: anything that attaches via the Win32 debugging API and
catches breakpoint exceptions. `SetBreakOnSeverity` makes the debug layer execute a
breakpoint when a matching message is queued, so the attached debugger stops on the exact
call that misbehaved — guard it with `IsDebuggerPresent()`, or an unattended run dies on
the unhandled breakpoint. **RenderDoc and PIX are not debuggers in this sense** — they are
GPU frame-capture/analysis tools that intercept API calls rather than attach as debuggers,
so they never see the breakpoint. Division of labor: the debug layer answers "is my API
usage legal?", a CPU debugger answers "which code path issued the illegal call?", and
RenderDoc/PIX answer "why do the pixels look wrong?". (RenderDoc prefers the debug layer
off during capture.)

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

**Reference port:** `odin_port/C6_Box` + `odin_port/C6_BoxGrid`
(`odin run odin_port/C6_Box -debug` **from the repo root** — the shader path
`Shaders/BasicColor.hlsl` and the DXC DLLs resolve relative to it; see
`odin_port/README.md` for the one-time DLL copy).

Shared code that appears in this chapter:

- `upload_buffer.odin` — `Upload_Buffer($T)`, where the C++ template became parametric
  polymorphism.
- `mesh_util.odin` — `Mesh_Geometry`, `Submesh_Geometry`, and a data-only `Bounding_Box`.
- `upload_batch.odin` — **DirectXTK12-derived, provenance header**: a synchronous
  `Resource_Upload_Batch` + `create_static_buffer`. The C++'s `std::future`-returning `End()`
  became end-and-wait, since the demos block on that future before the first draw anyway.
- In `d3d_util.odin`: `calc_constant_buffer_byte_size`, `buffer_desc`, the `CD3DX12_*_DESC`
  defaults spelled out as constants, `init_default_pso`, and the DXC `compile_shader`
  (`IDxcUtils`/`IDxcCompiler3`/`IDxcResult`, error text via `IDxcBlobUtf8` → `report_error`,
  shader PDBs written to `HLSL PDB/` in debug builds like the C++).

`d3d_math` gains `look_at_lh` and `perspective_fov_lh` — ch 5's derivations, [0,1] depth. And
`D3D_App` gains an `on_resize` virtual: overrides call `common.on_resize` first (mirroring the
C++ base call) and then recompute the projection. It defaults to the base body when unset, so
adding it doesn't disturb the ch 4 demo.

Three things worth knowing before you start:

- **Vendor DXC 1.6.2112 is old but sufficient.** `BasicColor.hlsl` compiles as
  `vs_6_6`/`ps_6_6`, PDB output (`DXC_OUT_PDB`) included. No need for the newer DLLs from
  `External\dxc`.
- **Pin your DXC DLLs next to the exe.** The exe loads `dxcompiler.dll` at process start
  (load-time linking against vendor's import lib), and the Vulkan SDK puts a *different*
  `dxcompiler.dll` on PATH. Copying vendor's copy to the exe directory wins the search order
  and pins the version deliberately.
- **Expect two `id 1328` warnings per run**, and don't chase them:
  `CreateCommittedResource: Ignoring InitialState D3D12_RESOURCE_STATE_COPY_DEST. Buffers are
  effectively created in state D3D12_RESOURCE_STATE_COMMON`. That's the static-buffer helper
  creating a default-heap buffer in `COPY_DEST`, exactly as DirectXTK12's `CreateStaticBuffer`
  does — the C++ demos emit the same pair, invisibly, to the debugger channel. Buffers
  implicitly promote from COMMON to COPY_DEST on first copy and the recorded barrier stays
  legal.

Correct looks like: colored box(es) over LightSteelBlue matching the C++ framing — Box centered
with cyan, yellow, red, and white corners; BoxGrid's 3×3 with per-object translations. The
Wireframe checkbox should swap PSOs live, resizing repeatedly should recompute the projection
through `on_resize`, and Escape should exit 0 with both the debug layer and the leak reports
silent.

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

**Reference port (Shapes):** `odin_port/C7_Shapes`
(`odin run odin_port/C7_Shapes -debug`, from the repo root).

Two pieces of shared code arrive here. `mesh_gen.odin` is the full MeshGen — box, grid, sphere,
geosphere, cylinder, quad, plus `subdivide` and `append_submesh`; `Mesh_Gen_Data` owns dynamic
arrays, so free it once you've uploaded. `graphics_memory.odin` is a **reduced port of
DirectXTK12's GraphicsMemory** (provenance header, since it isn't book code): 64 KiB upload
pages, `allocate_constant` at 256-byte alignment, `commit(queue)` to fence this frame's pages
and recycle retired ones, and `get_statistics` to feed the ImGui GraphicsMemoryStatistics
panel. It lives on `D3D_App` as `linear_allocator` (the C++ `mLinearAllocator`), and its pages
are lazy, so earlier demos pay only for its fence.

Demo-side, this is where the book's CPU/GPU parallelism arrives: a `FrameResource` ring
(per-frame allocator, pass CB, fence value) means **Draw no longer flushes**, and Update waits
only when the ring wraps. Render items live in `[dynamic]^Render_Item` plus per-layer lists
(`[Render_Layer][dynamic]^Render_Item`), and bindings switch from ch 6's descriptor tables to
root **descriptors** (`SetGraphicsRootConstantBufferView`).

The C++'s `unordered_map` shader, PSO, and geometry tables become Odin maps — with one wrinkle
that will bite you: **map values aren't addressable in Odin**, so you can't take a pointer to
one. `mGeometries` becomes `map[string]^Mesh_Geometry` with explicit `new`/`free`.

Correct looks like: the book's shapes scene with wireframe defaulting ON (per the demo's
header), and a stats panel that holds steady at 3 pages / 196 KiB with one page in flight — if
that number climbs frame over frame, your `commit` isn't recycling pages.

**Reference port (Waves):** `odin_port/C7_Waves`
(`odin run odin_port/C7_Waves -debug`, from the repo root).

The sim in `waves.odin` is the book's finite-difference scheme ported verbatim, with one
**deliberate deviation: it is serial.** The C++ wraps both interior loops in
`concurrency::parallel_for` (PPL); this port keeps plain loops, since at 128×128 the serial
update doesn't dent the frame time and threading it can wait. Do the same if you want to stay
on the book's path — or reach for `core:thread` if you'd rather take the detour now.

New moving parts versus Shapes: `Upload_Buffer` needs the C++'s second `CopyData` overload (a
contiguous array copy, here `copy_data_slice`), and each `FrameResource` carries a `waves_vb`
— an `Upload_Buffer(Color_Vertex)` of 128×128 vertices that gets refilled from the solution
every frame.

**Then there's the trap.** Each frame, the water geometry's vertex buffer is re-pointed at the
current frame resource's buffer. In C++ that line —
`geo->VertexBufferGPU = currWavesVB->Resource()` — silently AddRefs through ComPtr, so the
eventual destructor Release is balanced. In Odin the same assignment is a plain **borrow**, so
teardown must nil the field before destroying the mesh, or it double-Releases a buffer the
frame resource already released. Expect this any time you alias a COM object you don't own; it
is the single easiest way to turn a clean port into a heisenbug.

Smaller notes: land geometry is a MeshGen grid plus the hills height function and
height-banded vertex colors; water indices must be **R32_UINT**, since 128×128 exceeds 0xffff;
and `MathHelper::Rand`/`RandF` map to `core:math/rand`'s `int_max` (mind the `+1` — the book's
range is inclusive) and `float32_range`.

Correct looks like: ripples that actually animate and interfere, hills banded sand through
snow behind the water, and the three sliders at the book's defaults (1.0 / 8.0 / 0.1). A silent
leak report matters more than usual here — it's what proves the borrowed vertex buffer above is
balanced.

### Ch 8 — Lighting  *(LitShapes, LitWaves)*

**New this chapter:**

- The **real `Shaders/SharedTypes.h` structs**. The C++ shares that header between HLSL and C++
  via macros; Odin can't include it, so this is where you port `PerObjectCB`, `PerPassCB`,
  `Light`, and `MaterialData` byte-for-byte into `shared_types.odin` — full structs, since the
  HLSL side declares every field even though ch 8 reads a handful. This retires the trimmed
  demo-local cbuffer structs you've used since ch 6. It is the float3-next-to-scalar packing
  minefield at its worst, plus the Odin matrix-alignment trap — reread **Constant-buffer
  layout** above before typing, and `#assert` the sizes (192 / 48 / 1552 / 120).
- **Materials**: a CPU-side `Material` table, mirrored into a per-frame `MaterialData` buffer.
  It's an `Upload_Buffer` with `is_constant_buffer = false` — a StructuredBuffer, so elements
  stay tightly packed (120 bytes, no 256-byte rounding) — and it binds as a **root SRV**
  (`SetGraphicsRootShaderResourceView`), no descriptor involved. `num_frames_dirty` starts at
  the ring depth and each frame's update decrements it, so an edit reaches all three frame
  resources.
- **`ModelVertex`** (pos/normal/uv/tangent, stride 44) replaces the per-vertex color, and the
  shape/skull geometry builders move into shared code — mirroring the C++, which promotes
  `BuildShapeGeometry`/`BuildSkullGeometry` into `d3dUtil` this chapter.
- **No shader porting.** `BasicLit.hlsl` and `LightingUtil.hlsl` compile as-is. BasicLit is the
  first shader with `#include`s — the default include handler you wired into `compile_shader`
  back in ch 6 finally earns its keep. Top-level includes resolve against the working
  directory, nested ones against the including file's folder: one more reason demos run from
  the repo root.

**Watch out:** the pass CB is no longer two matrices — it's the full 1552-byte struct with six
view/proj variants (`linalg.inverse` is convention-agnostic and safe here), eye position,
ambient color, and the light array. Zero it (`app.main_pass_cb = {}` = the C++ `ZeroMemory`)
before filling, and set `num_dir_lights = 3` or `ComputeLighting`'s loops do nothing and
everything renders ambient-only.

**Reference port (LitShapes):** `odin_port/C8_LitShapes`
(`odin run odin_port/C8_LitShapes -debug`, from the repo root).

`common/shared_types.odin` holds the shared-header structs and their size asserts;
`common/geometry_builders.odin` holds `Model_Vertex`, `Material`, and the two builders. The
skull loader is the C++'s `fin >> token` istream loop re-spelled as
`strings.fields_iterator` + `strconv` over the whole file — ~370k tokens, parses in
milliseconds — with the tangents and spherical-projection UVs generated exactly as the C++
does (the file only carries positions and normals).

The lights rotate in `update`: `rotation_y(angle)` applied to the three base directions with
`transform_normal` (w = 0 — a direction, not a point), then written into the pass CB's light
array each frame.

Correct looks like: the skull on the green box between the sphere-and-cylinder colonnade,
wireframe defaulting **OFF** this time. The light-gray floor deliberately reads warm
off-white, not gray — ambient (0.25, 0.25, 0.35) plus the warm (0.9, 0.8, 0.7) key light does
that; don't go hunting a color bug. The specular highlights crawl across the spheres as the
lights orbit (slowly — 0.1 rad/s; watch one for a few seconds).

**Reference port (LitWaves):** `odin_port/C8_LitWaves`
(`odin run odin_port/C8_LitWaves -debug`, from the repo root).

`waves.odin` is byte-identical to ch 7's copy (the C++ duplicates `Waves.cpp` per demo too) —
this chapter just finally *reads* the normals the simulation was already computing. The
dynamic VB streams `Model_Vertex` now (position + sim normal, uv/tangent zeroed), the land
keeps its analytic `get_hills_normal` — ported back in ch 7 as an unused leftover, now
load-bearing — and materials replace ch 7's height-banded vertex colors. The
borrowed-vertex-buffer trap from ch 7 is unchanged: teardown still nils `vertex_buffer_gpu`
before destroying the water mesh.

Correct looks like: uniformly green hills whose slopes shade dark-to-bright as they turn
through the light (that's the analytic normal working), lakeBlue water with specular glints
riding the moving ripples, and the three sliders still live. If the water is flat-shaded blue
with no glints, your streamed vertices aren't carrying the sim's normals.

### Ch 9 — Texturing  *(Crate, TexturedShapes, TexWaves)*

**Port first — the DDS loader**, the one genuinely missing piece in Odin: nothing in
`core:`/`vendor:` reads DDS (stb_image doesn't either). It is less work than it sounds if you
let two facts shrink it:

- **Load only what the chapter needs.** The C++ TextureLib loads all ~55 book textures up
  front, which would force you to speak every format on day one. The chapter-9 files are just
  legacy-FourCC `DXT1`/`DXT5` (→ `BC1_UNORM`/`BC3_UNORM`) plus three 1×1 uncompressed
  32-bit BGRA/BGRX defaults — no DX10 headers, no cubemaps yet. Map those, fail loudly on
  anything else (print the header fields — future-you will thank you), and extend when a
  later chapter's files demand it.
- **`GetCopyableFootprints` does the layout math for you.** Create the texture, ask the
  device for the per-subresource offsets and (256-byte-aligned) row pitches, copy the file's
  tightly-packed rows into an upload buffer at those pitches — row by row, never one big
  memcpy — then one `CopyTextureRegion` per subresource and a barrier. DDS mips are
  pre-baked; nothing in the book generates mips.

Traps that cost real time: a `mip_map_count` of **0 means 1**; block-compressed pitch is
`max(1, (w+3)/4) * block_size` with 8 bytes for BC1/BC4 and 16 for the rest; and the DDS
file's subresource order (all mips of face 0, then face 1, …) happens to match D3D12's, so a
single walk covers arrays and cubes when they arrive. Reference implementation: DirectXTK12's
`DDSTextureLoader.cpp` and `LoaderHelpers.h`.

**Split parsing from uploading**, the way DirectXTK12 does — `LoadDDSTexture*` describes the
subresources, `CreateDDSTexture*` also uploads them. Worth going one step further than they
do: keep the parser free of *any* D3D12 type (theirs still takes a device, because it creates
the resource). A parser that needs no GPU and no assets is one you can unit-test, feed
deliberately corrupt headers, and check against DirectXTK12 file by file — see
`odin_port/dds/README.md` for how that validation was run.

While you're at it, **don't let `dxgi.FORMAT` leak into the parser**.
`vendor:directx/dxgi` link-depends on three Windows `.lib`s, so any package that touches it
becomes Windows-only — and it *compiles* fine off-Windows, so you won't notice until
something tries to link. Declare the format enum locally, *using DXGI's numbers*: that's not
a concession to D3D but the file format's own vocabulary, since a DX10 header stores a raw
`DXGI_FORMAT` integer. Then `dxgi.FORMAT(f)` is a cast rather than a table, and the parser
stays something you could lift into another project unchanged.

**Then the bindless plumbing**, which is the chapter's actual lesson:

- Every texture gets a **bindless index** from the CbvSrvUav heap's free-list and an SRV at
  that slot; MaterialLib snapshots the indices; the material buffer carries them; the pixel
  shader does `ResourceDescriptorHeap[matData.DiffuseMapIndex]`. No per-texture root
  bindings, this chapter or ever again. Order matters: textures load → heap assigns indices →
  materials snapshot them.
- A **sampler heap** (not static samplers — the 2nd ed's shaders use SM 6.6
  `SamplerDescriptorHeap[]`) with seven fixed slots at the SAM_* indices from SharedTypes.h.
  The slot order is a contract with every shader from here on.
- Two new root-signature flags: `CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED` and
  `SAMPLER_HEAP_DIRECTLY_INDEXED`. Forget them and the debug layer rejects your PSO with a
  clear message; forget to bind the sampler heap in Draw and it rejects the draw.

**Watch out:** the heap index IS the contract — a texture SRV created at the wrong slot
doesn't error, it silently samples the wrong image. And `UpdateMaterialBuffer` uploads more
now (MatTransform transposed + three indices); if the crate renders untextured-white, you're
probably still uploading the ch 8 subset of `MaterialData`.

**Reference port:** `odin_port/C9_Crate`, `odin_port/C9_TexturedShapes`,
`odin_port/C9_TexWaves` (`odin run odin_port/C9_Crate -debug` etc., from the repo root).

The parser is its own package, `odin_port/dds` (`odin test odin_port/dds` — unit tests on
synthetic headers, plus integration tests over every `.dds` in the repo); the D3D12 upload
half is `common/texture_upload.odin`. Both carry provenance headers, since the flow and the
format tables are DirectXTK12-derived. TextureLib
and MaterialLib live in common like the C++ singletons, but are passed explicitly and grow
per chapter instead of loading the whole book's assets. The Sampler_Heap sits on `D3D_App`,
initialized where the C++ initializes its singleton. TexWaves' `AnimateMaterials` is the
first *runtime* material edit — it nudges the water's `MatTransform` translation row
(`[3][0]`/`[3][1]` in row-major) and re-arms `num_frames_dirty` every frame, which exercises
the dirty-propagation path the ring has carried since ch 8.

Correct looks like: the crate crisp with its "Direct 3D" stamp (Crate); the ch 8 scene
dressed in bricks, 8×8-tiled floor, and stone spheres (TexturedShapes); grass hills and
water whose texture visibly *drifts* diagonally on top of the wave motion (TexWaves — if the
water animates but the pattern never slides, AnimateMaterials isn't re-dirtying the
material). Textures start life in COPY_DEST legitimately, so the id-1328 warning count stays
at one per static *buffer* — texture uploads add none.

### Ch 10 — Blending  *(BlendDemo)*

**New this chapter:** blend/alpha-test PSO variants — config, not code.

**Reference port:** `odin_port/C10_BlendDemo`
(`odin run odin_port/C10_BlendDemo -debug`, from the repo root).

This is deliberately a small delta from `C9_TexWaves`: water moves to a transparent
render layer with source-alpha blending, the crate becomes a two-sided alpha-tested
wire-fence box compiled with `ALPHA_TEST=1`, and opaque/alpha-tested/transparent layers
draw in that order. `BasicBlend.hlsl` also activates the fog fields that have occupied
the shared pass-buffer layout since chapter 8; the Options panel exposes the same enable,
start, and end controls as the C++ demo.

Correct looks like: grass remains opaque behind translucent moving water, the wire fence
has actual cutouts rather than black squares, and distant hills fade into the gray fog
background. Wireframe should still replace all three PSOs live, Escape should exit 0, and
the debug/leak reports should contain no new warnings or live objects.

### Ch 11 — Stenciling  *(Stenciling)*

**New this chapter:**

- Depth/stencil PSO states.
- Hand-roll `matrix_reflect(plane)` / `matrix_shadow(plane, light)` into `d3d_math.odin` —
  the chapter derives both. Keep them in the row-vector form you standardized on.

**Reference port:** `odin_port/C11_Stenciling`
(`odin run odin_port/C11_Stenciling -debug`, from the repo root).

The frame resource now carries two pass constants: the normal pass and a reflected-light
copy. The mirror first writes stencil without touching the color or depth buffers; the
reflected skull then draws only where stencil equals one, followed by the transparent ice
surface and the projected shadow. `A`/`D`/`W`/`S` move the skull and update all three world
matrices every frame.

Correct looks like: a skull on the checkered floor, its reflection visible only through
the ice mirror, and a translucent black shadow lying on the floor without dark overlap.
Moving the skull must move the original, reflection, and shadow together.

### Ch 12 — The Geometry Shader  *(BillboardsGS)*

**New this chapter:** GS stage in the PSO; a texture2DArray DDS — your DDS loader + upload
helper must handle `array_size * mip_levels` subresources. Extend them now if you cut that
corner.

**Reference port:** `odin_port/C12_BillboardsGS`
(`odin run odin_port/C12_BillboardsGS -debug`, from the repo root).

The demo adds a two-element point input layout (world position and size), compiles the
`gs_6_6` entry from `TreeSprite.hlsl`, and swaps the PSO topology type to POINT. The shared
descriptor helper now creates Texture2DArray SRVs so the pixel shader can select among the
three tree slices using `SV_PrimitiveID`.

Correct looks like: a dense mix of three tree species across the hills, with every sprite
remaining upright and turning to face the camera. Their transparent backgrounds must be
clipped cleanly, including in the normal (non-wireframe) PSO.

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

**Watch out — quaternion multiply composes the *opposite* way from the book.** Two convention
traps, and neither is the quaternion's fault — they're the same row-vector / column-convention
mismatch the matrix layer already fights, now wearing a quaternion:

- **Composition order flips.** Odin's built-in `q1 * q2` is raw Hamilton — it applies **q2
  first, then q1** (right-to-left). DirectXMath deliberately *reversed* its
  `XMQuaternionMultiply(a, b)` so quaternions read left-to-right (`a` then `b`) like its
  row-vectors. So the book's `XMQuaternionMultiply(a, b)` ports to `b * a` in Odin — operands
  swapped. Port it verbatim and you get the rotation backwards, silently. Wrap it in a helper
  (`quat_concat :: proc(first, second) -> ... { return second * first }`) with a `// C++:` note
  so call sites read in book order.
- **`matrix4_from_quaternion` is transposed**, exactly like every other linalg builder — it emits
  the column-vector / column-major form. `transmute` it to `Mat4` (same trick as the matrix
  builders), or spell the conversion out from the book's formula.

Both caveats are artifacts of porting a *row-vector* book onto Odin's *column-vector-native*
stdlib — not defects. **Under a future column-vector/column-major engine they evaporate:** the
built-in `*` already composes right-to-left, which is what column-vector matrices do too (last
rotation on the left, for both), so the swap helper is gone; and `matrix4_from_quaternion`
returns exactly the matrix you want, so the transmute is gone. (Projection depth range `[0,1]`
vs linalg's GL `[-1,1]` is the one wrapper that survives the switch — but that's a camera issue,
unrelated to quaternions.)

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
`#align` / explicit padding. Fiddliest struct-layout task in the port.

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
| `shared_types.odin` (trimmed local structs ch 6–7; the full `#packed` mirror ch 8) | ch 6 | small | `SharedTypes.h` |
| dxc `compile_shader` + shader table | ch 6 | small | `d3dUtil::CompileShader` + `ShaderLib` (bindings pre-exist) |
| `mesh_gen.odin` (box/grid/sphere/geosphere/cylinder/quad) | ch 7 | medium | book's `MeshGen` |
| Linear upload arena + `Frame_Resource` ring | ch 7 | medium | DirectXTK12 `GraphicsMemory` + book's Common |
| `mem_track.odin` (Tracking_Allocator wiring) | ch 7 | tiny | CRT debug-heap leak check |
| `geometry_builders.odin` (`ModelVertex`, `Material`, shape + skull builders) | ch 8 | small | `d3dUtil::BuildShapeGeometry`/`BuildSkullGeometry` |
| `dds` package (pure parser + tests; grow formats per chapter) | ch 9 | medium (~400 lines) | DirectXTK12 `DDSTextureLoader` "Load" half + `LoaderHelpers` — Odin's biggest gap |
| `common/texture_upload.odin` (footprint upload) | ch 9 | small | DirectXTK12 `DDSTextureLoader` "Create" half + texture path of `ResourceUploadBatch` |
| `texture_lib.odin`/`material_lib.odin` + `Sampler_Heap` (grow per chapter) | ch 9 | small | book's `TextureLib`/`MaterialLib`/`SamplerHeap` singletons |
| Texture upload extensions (arrays → from-memory) | ch 12, 18, 21, 25 | small each | DirectXTK12 `ResourceUploadBatch` |
| `matrix_reflect`/`matrix_shadow` | ch 11 | tiny | DirectXMath |
| `collision.odin` (AABB, frustum, ray tests) | ch 16–17 | small | DirectXCollision |
| `affine_transformation` | ch 22 | tiny | DirectXMath |
| `.m3d` parser + `SkinnedData` | ch 23 | medium | book's Common |
| `.raw` heightmap reader | ch 24 | tiny | book code |
| Pipeline-state-stream struct | ch 26 | small-fiddly | `CD3DX12_PIPELINE_STATE_STREAM` |

## What Odin gives you, and what you build yourself

Two things shape the whole port, and it's worth knowing both before you start.

**What comes for free.** `vendor:` ships with the compiler, so D3D12, DXGI, DXC, and dxgidebug
are all present and version-matched — including `ID3D12InfoQueue1` and DRED, which reduces the
debug-output side quest to about a dozen lines. dxc being fully bound means the book's runtime
shader-compile flow ports 1:1 and you keep edit-shader-and-rerun iteration with no build step.
Operator overloading keeps matrix and vector math reading like the book rather than like
function calls.

Best of all, the load/store split disappears: `XMFLOAT3` versus `XMVECTOR`, and every
`XMLoadFloat3`/`XMStoreFloat3` pair in the book, collapses into one `[3]f32` that both stores
and computes. With `Mat4 :: #row_major matrix[4,4]f32` the matrix side is byte-identical to
`XMFLOAT4X4`, so even the transpose-on-upload line survives verbatim.

**What you build yourself.** A **DDS loader** is the one genuinely missing piece — nothing in
`core:` or `vendor:` reads DDS, so budget an evening of format parsing before ch 9 (less than
it sounds: the ch 9 guide explains why, and the reference port's is ~330 lines, upload
included). And the **D3D-convention matrix builders**, because `core:math/linalg`'s are
GL-flavored column-vector: view, projection, and rotation come from your own `d3d_math.odin`,
typed from the forms Luna prints, with linalg demoted to vectors, quaternions, and
convention-agnostic operations. Neither gap is hidden or hard, and the inventory table above
lists everything else.

## Things to learn next

The book ends where a working renderer begins. What follows is weighted toward the *quiet*
gaps — headline features advertise themselves, and you'll meet them in a blog post eventually.
The danger is finishing all 27 chapters without ever learning that a cleaner way exists.

A ✅ means `vendor:directx/d3d12` already binds it. None of this needs new bindings.

### You could finish the book and never know these exist

**Enhanced barriers.** The book uses legacy `ResourceBarrier` throughout — 134 calls, each
packing pipeline stage, access, and memory layout into one `D3D12_RESOURCE_STATES` value.
[Enhanced barriers](https://microsoft.github.io/DirectX-Specs/d3d/D3D12EnhancedBarriers.html)
split those into three independent axes and delete the implicit state promotion/decay rules,
which are the subtlest corner of the legacy model.
✅ `IGraphicsCommandList7.Barrier`, `BARRIER_GROUP`, `TEXTURE_BARRIER`, `BARRIER_LAYOUT`.

**Heaps and placed resources.** Every resource in the book is a *committed* resource — there is
not a single `CreateHeap` in the tree.
[Suballocation within heaps](https://learn.microsoft.com/en-us/windows/win32/direct3d12/suballocation-within-heaps)
is how you get arena-style bulk allocate-and-free (one heap per level, reset on unload), and
[D3D12MA](https://github.com/GPUOpen-LibrariesAndSDKs/D3D12MemoryAllocator) is the industrial
version for when per-object lifetimes outgrow that.
✅ `CreateHeap`, `CreatePlacedResource`, `CreateReservedResource`.

**Copy and compute queues.** The book never leaves a single `DIRECT` queue — even
`ResourceUploadBatch->Begin()` is handed `D3D12_COMMAND_LIST_TYPE_DIRECT`.
[Multi-engine synchronization](https://learn.microsoft.com/en-us/windows/win32/direct3d12/user-mode-heap-synchronization)
is where the frame-resource fencing from ch 7 stops being boilerplate and starts earning its
keep: uploads and async compute overlapping with graphics instead of serialized behind it. ✅

**Residency, as management rather than readout.** Every demo polls `QueryVideoMemoryInfo` and
prints Budget / CurrentUsage in its ImGui panel — but nothing ever *acts* on the numbers.
[Residency](https://learn.microsoft.com/en-us/windows/win32/direct3d12/residency) is the other
half: `MakeResident`/`Evict`, and deciding what to drop when you exceed budget. ✅

**DRED.** No demo handles device-removed beyond failing. Device Removed Extended Data gives you
GPU-side [breadcrumbs and page-fault data](https://learn.microsoft.com/en-us/windows/win32/direct3d12/use-dred)
— which command actually died, and which address it touched. This is the answer to "GPU crashes
are undebuggable," and it costs a few dozen lines.
✅ `IDeviceRemovedExtendedDataSettings`, `AUTO_BREADCRUMB_NODE`.

**GPU-based validation.** Already in the book's own source, one comment away — see
`debugController1->SetEnableGPUBasedValidation(true);` in `Common/d3dApp.cpp`. It's slow, so
it's dev-only, but it catches what the regular debug layer can't: notably out-of-bounds
descriptor indexing, which the 2nd edition's bindless design makes genuinely reachable.
[Docs](https://learn.microsoft.com/en-us/windows/win32/direct3d12/using-d3d12-debug-layer-gpu-based-validation).
✅ `IDebug1`, `IDebug3`.

### Worth knowing exist

- **[Native 16-bit shader ops](https://github.com/microsoft/DirectXShaderCompiler/wiki/16-Bit-Scalar-Types)** —
  real `float16_t`/`int16_t` in HLSL (SM6.2, `-enable-16bit-types`), as opposed to the old
  `min16float` hints a driver could quietly ignore. Half the register pressure means better
  occupancy, and some hardware runs packed 16-bit math at double rate. The natural uses are
  post-processing and anything already stored small — blur, tonemapping, bloom, SSAO, normals,
  colors — and the thing to keep at 32-bit is positions, depth, and long accumulations.
  ✅ `OPTIONS4.Native16BitShaderOpsSupported`
- **[Variable rate shading](https://microsoft.github.io/DirectX-Specs/d3d/VariableRateShading.html)** —
  shade coarser than per-pixel. Largely mutually exclusive with upscalers, which need the clean
  per-pixel history that VRS blocks destroy. ✅ `RSSetShadingRate`
- **[Sampler feedback](https://microsoft.github.io/DirectX-Specs/d3d/SamplerFeedback.html)** —
  the GPU records which mips/tiles it actually sampled, so you stream in exactly those instead
  of guessing. Pays off only when your textures don't all fit in VRAM — and even then, Sawicki's
  read is that most games should skip the *hardware* feature: working out the wanted mip yourself
  in a shader matches your own streaming granularity exactly and doesn't narrow your minimum spec.
  Worth understanding as a technique; optional as a DX12 feature. ✅ `SAMPLER_FEEDBACK`
- **[GPU upload heaps](https://microsoft.github.io/DirectX-Specs/d3d/D3D12GPUUploadHeaps.html)
  and [DirectStorage](https://github.com/microsoft/DirectStorage)** — two answers to "get bytes
  to the GPU efficiently." Upload heaps let the CPU write straight into VRAM but need ReBAR
  *and* Windows 11 *and* the user not having disabled ReBAR; DirectStorage does bulk NVMe→GPU
  with GPU-side decompression. Prefer DirectStorage over hand-rolling upload heaps.
  ✅ `HEAP_TYPE.GPU_UPLOAD` · ❌ DirectStorage ships as its own SDK and has no Odin bindings —
  that's a set of bindings to write, not a blocker.
- **[Work graphs](https://microsoft.github.io/DirectX-Specs/d3d/WorkGraphs.html)** — GPU-driven
  work generation. Hardware support is still thin, and Odin binds only the `WORK_GRAPHS_TIER`
  feature query, not the dispatch API — you'd be writing bindings first. ⚠️
- **PSO caching and partial graphics programs** — shader-compilation stutter is the classic
  shipping problem the book never hits, because it builds a handful of PSOs at startup while a
  real game has thousands. `ID3D12PipelineLibrary` ✅ is the in-box answer today;
  [partial graphics programs](https://devblogs.microsoft.com/directx/partial-graphics-programs/)
  are the more interesting new one — compile the shared prerasterization and pixel-shader halves
  once into a collection, then late-link them against the varying state (blend, say) and
  `SetProgram()` before the draw, so N variants stop costing N full compiles. That pays off in
  development too, not just at ship: editing a pixel shader only invalidates its half, so a
  hot reload rebuilds less.
  ⚠️ Odin binds the DXR-era `STATE_OBJECT_DESC` / `STATE_OBJECT_TYPE.COLLECTION` scaffolding but
  not the partial or generic program subobjects, and `SetProgram` lives on
  `IGraphicsCommandList10` where Odin stops at 7 — bindings to write first.

GPU debugging is also improving quickly — `.dxdmp` crash dumps readable in PIX, a scriptable
PIX API, an HLSL `DebugBreak()`, PIX markers propagating into drivers. All preview or announced
rather than shipped, so treat it as a reason for optimism, not a plan.

### Where to look things up

- [Direct3D 12 programming guide](https://learn.microsoft.com/en-us/windows/win32/direct3d12/directx-12-programming-guide) — the reference baseline.
- [DirectX-Specs](https://microsoft.github.io/DirectX-Specs/) — where features land *first*, and often the only real documentation for anything recent.
- [D3D11.3 functional spec](https://microsoft.github.io/DirectX-Specs/d3d/archive/D3D11_3_FunctionalSpec.htm) — still the best source on alignment and resource rules D3D12 inherited wholesale.
- [DXC wiki](https://github.com/microsoft/DirectXShaderCompiler/wiki) and [hlsl-specs](https://github.com/microsoft/hlsl-specs) — shader model details and proposed language features.
- [DirectX developer blog](https://devblogs.microsoft.com/directx/) — Agility SDK releases and tooling news.
- Adam Sawicki's [state of GPU hardware](https://asawicki.info/articles/state_of_gpu_hardware_2025.php) for deciding minimum spec, [sources of DX12 documentation](https://asawicki.info/news_1794_all_sources_of_directx_12_documentation), and [GDC 2026 commentary](https://asawicki.info/news_1801_directx_12_news_from_gdc_2026_-_my_comments).
