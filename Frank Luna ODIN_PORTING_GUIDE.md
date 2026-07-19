# Porting Luna's *Introduction to 3D Game Programming with DirectX 12* (2nd ed.) to Odin

A chapter-by-chapter companion for porting the book's C++ samples to Odin by hand, as a learning
exercise. It deliberately does **not** port the code for you — it tells you what to port first,
which library replaces what, and where the traps are.

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

Worth knowing early: `ID3D12InfoQueue1` (message callbacks → stderr) and DRED are **already
bound** in `vendor:directx/d3d12`, so the ch 4 side quest needs no binding work.

### Odin-side leak detection (Tracking_Allocator) *(added with ch 7, 2026-07-19)*

The D3D debug layer catches COM leaks; `core:mem.Tracking_Allocator` catches Odin heap
leaks — the analogue of the C++ demos' CRT debug-heap check, wrapped in
`common/mem_track.odin`.

Every demo main starts with `context = common.mem_track_init()`, which wraps **both**
`context.allocator` and `context.temp_allocator` in debug builds, and ends with
`common.mem_track_report()` immediately before `os.exit` — *before*, because `os.exit`
skips defers. Clean runs stay silent; leaks print `[odin-leak] N bytes at file(line:col)`;
bad frees (double free, freeing a borrowed pointer) **panic at the offending call site**,
which is the default `bad_free_callback`.

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

### Verifying a demo end-to-end

Each windowed demo gets the same check before it counts as done: a screenshot matching the
C++ framing, a resize storm, Escape → exit 0, debug layer silent, both leak reports silent.
The automation is PowerShell plus P/Invoke, and every trap below cost real time to find.

- **Make the probe thread per-monitor DPI aware** (`SetThreadDpiAwarenessContext(-4)`). At
  150% scale an unaware process gets DPI-virtualized `GetWindowRect` coordinates, so
  `CopyFromScreen` crops the window — a centered box looks off-center and you go hunting a
  rendering bug that was never there. `PrintWindow` with `PW_RENDERFULLCONTENT` additionally
  captures windows that are overlapped.
- **Escape arrives on `WM_KEYUP`,** not `WM_KEYDOWN` — that's where the book's `MsgProc`
  handles `VK_ESCAPE`. A posted KEYDOWN is silently ignored and the demo never exits.
- **ImGui clicks need a real cursor** (`SetCursorPos` + `mouse_event`, saving and restoring
  the user's position), because the win32 backend re-reads `GetCursorPos` every focused
  frame and overwrites posted mouse positions. Call `SetForegroundWindow` first or the click
  lands in whatever window has focus.
- **`CW_USEDEFAULT` cascades window positions** per boot session, so never hardcode the
  origin: read `GetWindowRect`, then map `physical = origin + 1.5 × window-relative-virtual`
  at 150% scale.
- **PowerShell 5.1 needs `$null = $p.Handle`** cached before the process exits, or
  `$p.ExitCode` comes back empty.
- **Check line endings with `file`**, which names CRLF explicitly — not with
  `grep -c $'\r'`, because MSYS tools translate line endings on read and report CRLF for
  files that are pure LF.

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
  **Ported:** `odin_port/C1_XMVECTOR` (`odin test odin_port/C1_XMVECTOR`) — one `.odin` file
  per C++ variant (the three commented-out mains included), one `@(test)` each, asserting
  values captured from the C++ demos' output. Float-compare helpers in
  `odin_port/test_util` (exact values use `testing.expect_value`; cout-rounded values use
  `expect_close` with eps sized to the 6th significant digit).
- **Ch 2 Matrix Algebra** — matrix rows; `matrix[4,4]f32` semantics (column-major storage —
  reread the Matrices section so it doesn't surprise you in ch 6).
  **Ported:** `odin_port/C2_XMMATRIX`. With `Mat4 :: #row_major matrix[4,4]f32` the C++
  `XMMATRIX A(…)` literal is typed with the same 16 numbers in the same positions, `A * B`
  stays `A * B`, and the demo's printed rows are our rows — zero convention edits.
  Confirmed: `#row_major` matrices pass straight through linalg's generic
  `transpose`/`determinant`/`inverse`.
- **Ch 3 Transformations** — start `d3d_math.odin` here: rotation/translation/scaling matrices
  typed from the book's printed forms; verify an `S*R*T` chain against the book's numbers.
  **Ported:** `odin_port/C3_TRANSFORMATIONS` + `odin_port/d3d_math` (the builders, typed in
  the book's row-vector forms, verified against a DXM ground-truth program — including
  Rodrigues' rotation-axis form and `RollPitchYaw = Rz·Rx·Ry` left-to-right). `S * Ry * T`
  reads exactly as the book writes it, with a deliberate negative assert showing the
  reversed spelling is a different transform. DXM approximation note: `XMScalarSinCos` puts
  cos(π/4) at 0.70710671 vs core:math's 0.70710677 — same category as `XMVectorCos`.

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

**Ported:** `odin_port/APPENDIX_A` (`odin run odin_port/APPENDIX_A`) — the appendix-text
program with `d3dApp.cpp`'s conventions, since no Appendix A sample ships in the 2nd ed.

Notes that materialized: plain `RegisterClassW`/`WNDCLASSW` are bound, not just the Ex
variants. `windows.L("…")` is `intrinsics.constant_utf16_cstring`, i.e. compile-time wide
literals. `IDI_APPLICATION`/`IDC_ARROW` are typed as `cstring`, so cast `win._IDI_APPLICATION`
(a `rawptr`) to `LPCWSTR` for the W loaders. `GetMessageW` returns `INT`, so the book's `-1`
error check ports directly. And Odin makes unreachable code a compile error — mind that when
temporarily injecting error-path tests.

Fatal errors follow the port convention: `report_error` writes to stderr *and* shows a
`MessageBoxW`, both verified. The console subsystem is kept deliberately for the ch 4 stderr
story (`-subsystem:windows` for ship builds).

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

**Ported (part 1 — core):** `odin_port/C4_Init_Direct3D` + `odin_port/common`
(`odin run odin_port/C4_Init_Direct3D -debug`).

The C++ virtual base class became struct `D3D_App` with proc-pointer virtuals (`update` and
`draw`, plus optional mouse hooks); demos embed it via `using base: common.D3D_App` and cast
back — Odin's subtype-polymorphism idiom. The `GetApp()` singleton became a `^D3D_App`
parked in `GWLP_USERDATA`, a plain thin pointer. Both `wnd_proc` and the InfoQueue1 callback
must establish a context on entry (see the leak-detection section for which one, and why it
matters more than it looks).

Manual COM discipline throughout, per the plan: enumerated adapters are released when not
kept, QI-upgrades release the old interface, and `d3d_app_shutdown` releases
children-before-device after a queue flush.

Verified: pixel-exact LightSteelBlue via screen sampling, five programmatic resizes, debug
layer enabled with InfoQueue1→stderr and zero messages, Escape → clean exit, ~8900 fps on the
9070 XT. Gotcha: vendor's `PFN_MESSAGE_CALLBACK` is `proc "c"` (cdecl), not `"system"`.

**Ported (part 2 — ImGui, 2026-07):** the Options panel renders, verified by screenshot — frame stats
plus VideoMemoryInfo via `QueryVideoMemoryInfo`. (The GraphicsMemoryStatistics section waits
for the ch 6–7 upload arena.) Capati/odin-imgui is vendored at `odin_port/libs/imgui` with
the win32+dx12 backends; build and copy steps are in `odin_port/README.md`, and need Python,
premake5, and MSBuild.

Findings: Dear ImGui 1.92's DX12 backend replaced the book's single-SRV `Init` with an
`InitInfo` struct whose `SrvDescriptorAllocFn`/`FreeFn` callbacks map *exactly* onto
`CbvSrvUavHeap.NextFreeIndex`/`ReleaseIndex` — where the book leans on a C++ singleton, the
heap is passed explicitly through `InitInfo.UserData`. `WndProcHandler` hooks the message
pump first, as in `MainWndProc`.

Shutdown order matters: ImGui before the heap before the base, so the SRV free callbacks
still have a live heap to release into and the leak report stays silent (it does).

One build bug found and fixed locally in the Capati checkout (PR-worthy): its premake script
patches `imgui_impl_win32.cpp` by hardcoded line numbers, which went stale in ImGui 1.92.8
and produced `error C2159`. Ours patches by pattern instead.

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

**Proving the pipe works — how to simulate a debug-layer error (verified 2026-07):**

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

**Ported (2026-07-18):** `odin_port/C6_Box` + `odin_port/C6_BoxGrid`
(`odin run odin_port/C6_Box -debug` **from the repo root** — the shader path
`Shaders/BasicColor.hlsl` and the DXC DLLs resolve relative to it; see
`odin_port/README.md` for the one-time DLL copy).

New common code:

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

`d3d_math` gained `look_at_lh` and `perspective_fov_lh` — ch 5's derivations, [0,1] depth.
`D3D_App` gained the `on_resize` virtual: overrides call `common.on_resize` first (the C++
base call) and then recompute the projection, and it defaults to the base body when unset, so
C4 needed no changes.

Findings and traps from the port:

- **Vendor DXC 1.6.2112 works** — `BasicColor.hlsl` compiles as `vs_6_6`/`ps_6_6`, PDB
  output (`DXC_OUT_PDB`) included. The 1.9-from-`External\dxc` fallback wasn't needed.
- **DLL pinning:** the exe loads `dxcompiler.dll` at process start (load-time linking
  against vendor's import lib), and the Vulkan SDK also puts a `dxcompiler.dll` on PATH —
  so the vendor DLLs are copied to the repo root (= exe dir, which wins the search order),
  deliberately pinning the version. Both are gitignored; see the README for the copy step.
- **Benign warning pair on every run:** id 1328 `CreateCommittedResource: Ignoring
  InitialState D3D12_RESOURCE_STATE_COPY_DEST. Buffers are effectively created in state
  D3D12_RESOURCE_STATE_COMMON` — this is `create_static_buffer` creating the default-heap
  buffer in `COPY_DEST`, exactly what DirectXTK12's `CreateStaticBuffer` does, so the C++
  demos emit the same two warnings (invisibly, to the debugger channel). Ours are visible
  because InfoQueue1 pipes warnings to stderr. Harmless: buffers implicitly promote from
  COMMON to COPY_DEST on first copy, and the recorded `COPY_DEST → final` barrier stays
  legal.
- **The first screenshot looked wrong and wasn't** — a DPI trap in the harness, not a
  rendering bug. This is where the "Verifying a demo end-to-end" section above came from;
  read it before trusting any capture.

Verified (both demos): colored box(es) over LightSteelBlue matching the C++ framing — Box
centered with cyan/yellow/red/white corners, BoxGrid's 3×3 with per-object translations;
Wireframe checkbox toggled live via an injected cursor click (wireframe PSO renders, then
back to solid); five programmatic resizes with the projection recomputed through the new
`on_resize` virtual; Escape → exit 0; debug layer silent; leak report silent.

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

**Ported (Shapes, 2026-07-18):** `odin_port/C7_Shapes`
(`odin run odin_port/C7_Shapes -debug`, from the repo root).

New common code: `mesh_gen.odin` is the full MeshGen — box, grid, sphere, geosphere,
cylinder, quad, plus `subdivide` and `append_submesh`; `Mesh_Gen_Data` owns dynamic arrays,
so call `mesh_gen_data_destroy` once uploaded. `graphics_memory.odin` is a **reduced port of
DirectXTK12's GraphicsMemory, with a provenance header**: 64 KiB upload pages,
`allocate_constant` at 256-byte alignment, `commit(queue)` to fence this frame's pages and
recycle retired ones, and `get_statistics` feeding the ImGui GraphicsMemoryStatistics
section — which exists in the port for the first time here. The allocator lives on `D3D_App`
as `linear_allocator` (C++ `mLinearAllocator`), and pages are allocated lazily, so ch 4/6
demos pay only for its fence.

Demo-side, this is where the book's CPU/GPU parallelism arrives: a `FrameResource` ring
(per-frame allocator, pass CB, and fence value) means **Draw no longer flushes** and Update
waits only when the ring wraps. Render items live in `[dynamic]^Render_Item` plus per-layer
lists (`[Render_Layer][dynamic]^Render_Item`). Bindings switch to root **descriptors**
(`SetGraphicsRootConstantBufferView`) from ch 6's tables.

The C++'s `unordered_map` shader/PSO/geometry tables become Odin maps, with one wrinkle: map
values aren't addressable, so `mGeometries` becomes `map[string]^Mesh_Geometry` with explicit
`new`/`free`.

Verified: the book's shapes scene (wireframe defaults ON, per the header), the stats panel
live and stable at 3 pages / 196 KiB total with one page in flight — proving the arena
recycles rather than grows — plus orbit drag, five resizes, Escape → exit 0, debug layer
silent, leak report silent.

**Ported (Waves, 2026-07-19):** `odin_port/C7_Waves`
(`odin run odin_port/C7_Waves -debug`, from the repo root).

The wave sim in `waves.odin` is the book's finite-difference scheme ported verbatim, with one
**deliberate deviation: it is serial.** The C++ wraps both interior loops in
`concurrency::parallel_for` (PPL); the port keeps plain loops, because multithreading waits
until much later in this project and there's no TSan on Windows to check it with. At 128×128
the serial update doesn't dent the frame time.

New moving parts versus Shapes: `Upload_Buffer` gained the C++'s second `CopyData` overload as
`copy_data_slice` (contiguous array, asserts it isn't a 256-strided CB), and each
`FrameResource` carries a `waves_vb` — an `Upload_Buffer(Color_Vertex)` of 128×128 vertices
that `update_waves` refills from the solution each frame.

**The trap worth remembering** is the line that re-points the water geometry at that buffer.
In C++, `geo->VertexBufferGPU = currWavesVB->Resource()` silently AddRefs through ComPtr, so
its destructor's Release is balanced. In Odin the same assignment is a plain borrow, so
teardown must nil the field before `mesh_geometry_destroy` or it double-Releases a buffer the
frame resource already released. Expect this any time a demo aliases a resource it doesn't own.

Smaller notes: land geometry is a MeshGen grid plus the hills height function and
height-banded vertex colors; water indices are **R32_UINT**, since 128×128 exceeds 0xffff; and
`MathHelper::Rand`/`RandF` map to `core:math/rand`'s `int_max` (mind the +1 for the book's
inclusive range) and `float32_range`.

Verified: animated ripples (two captures 1.2 s apart differ), hills color bands, the three
wave sliders at C++ defaults, five resizes, Escape → exit 0, debug layer silent, and a silent
leak report — which is specifically what proves the borrowed-VB teardown is balanced. Chapter
7 complete.

### Ch 8 — Lighting  *(LitShapes, LitWaves)*

**New this chapter:** `Light`/`MaterialData` in `shared_types.odin` — the float3-next-to-scalar
packing minefield at its worst; normals in `MeshGen`. Nothing new externally.

### Ch 9 — Texturing  *(Crate, TexturedShapes, TexWaves)*

**Port first:**

- **DDS loader** — the biggest Odin-specific gap: nothing in `core:`/`vendor:` reads DDS
  (stb_image doesn't either). Hand-roll: magic + `DDS_HEADER` + optional DX10 header + map the
  handful of formats the book's ~60 textures use (BC1/BC3/BC5/BC7 + a few uncompressed), then
  compute per-mip pitches. Reference implementation: DirectXTK12's `DDSTextureLoader.cpp`.
  Budget 200–300 lines / an evening or two. (Check for a community Odin DDS package first —
  the situation may have improved.)
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
| `shared_types.odin` (grow per chapter) | ch 6 | small | `SharedTypes.h` |
| dxc `compile_shader` + shader table | ch 6 | small | `d3dUtil::CompileShader` + `ShaderLib` (bindings pre-exist) |
| `mesh_gen.odin` (box/grid/sphere/geosphere/cylinder/quad) | ch 7 | medium | book's `MeshGen` |
| Linear upload arena + `Frame_Resource` ring | ch 7 | medium | DirectXTK12 `GraphicsMemory` + book's Common |
| `mem_track.odin` (Tracking_Allocator wiring) | ch 7 | tiny | CRT debug-heap leak check |
| **DDS parser** | ch 9 | **medium-large** | DirectXTK12 `DDSTextureLoader` — Odin's biggest gap |
| Texture upload helper (mips → arrays → cubes → from-memory) | ch 9 (12, 18, 21) | medium | DirectXTK12 `ResourceUploadBatch` |
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
`core:` or `vendor:` reads DDS, so budget an evening or two of format parsing before ch 9. And
the **D3D-convention matrix builders**, because `core:math/linalg`'s are GL-flavored
column-vector: view, projection, and rotation come from your own `d3d_math.odin`, typed from
the forms Luna prints, with linalg demoted to vectors, quaternions, and convention-agnostic
operations. Neither gap is hidden or hard, and the inventory table above lists everything else.
