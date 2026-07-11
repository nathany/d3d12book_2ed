# Porting Luna's *Introduction to 3D Game Programming with DirectX 12* (2nd ed.) to Rust

A chapter-by-chapter companion for porting the book's C++ samples to Rust by hand, as a learning
exercise. It deliberately does **not** port the code for you — it tells you what to port first,
which library replaces what, and where the traps are.

## The stack

| Book dependency | Rust replacement | Notes |
|---|---|---|
| Win32 (`windows.h`) | **windows** crate (`Win32::UI::WindowsAndMessaging` etc.) | Wide (`...W`) variants; `w!("...")` macro for UTF-16 literals |
| D3D12 / DXGI | **windows** crate (`Win32::Graphics::Direct3D12`, `Dxgi`) | Covers everything the book uses, incl. DXR, mesh shaders, `ID3D12InfoQueue1`, DRED |
| dxc COM API (runtime shader compile) | **windows** crate (`Win32::Graphics::Direct3D::Dxc`) | `IDxcCompiler3`/`IDxcUtils` fully bound — but you ship `dxcompiler.dll`/`dxil.dll` yourself (DXC GitHub releases or NuGet) |
| DirectXMath / SimpleMath | **glam** | Ships D3D-style LH, `[0,1]`-depth projection builders — but column-vector convention; read the Matrices section carefully |
| DirectXCollision | *hand-roll* (small) | Needed at ch 16–17; see gap list |
| Dear ImGui 1.85 + Win32/DX12 backends | **imgui** crate (imgui-rs) + a DX12/Win32 backend | The widget API maps ~1:1; the backend is the weak spot — see ch 4 |
| DirectXTK12 (`ResourceUploadBatch`, `CreateStaticBuffer`, `DDSTextureLoader`, `GraphicsMemory`) | *hand-roll* + **ddsfile** crate | Three helpers: static-buffer upload, texture upload, and a per-frame linear upload arena (see GPU memory below); `ddsfile` parses the DDS container |
| PPL (`parallel_for`) | **rayon** `par_iter` | Genuinely 1:1; only the CPU Waves demos (ch 7–12) |
| Agility SDK 614 (`D3D12SDKVersion` export) | optional — `#[no_mangle] pub static` exports | See ch 4; on Windows 11 the inbox runtime already has SM 6.6 |
| CB/vertex byte layout | **bytemuck** (+ glam's `bytemuck` feature) | `#[repr(C)]` + `Pod` derive replaces every `memcpy` cast |

Everything above is on crates.io and current; no version juggling beyond normal `cargo update`
hygiene. Grab current versions of `windows`, `glam` (with the `bytemuck` feature), `bytemuck`,
`ddsfile`, `rayon` and you're set. The `windows` crate is feature-gated per API family — your
`Cargo.toml` grows a `features = [...]` list as chapters introduce new API surface
(`Win32_Graphics_Direct3D12`, `Win32_Graphics_Dxgi`, `Win32_Graphics_Dxgi_Common`,
`Win32_Graphics_Direct3D`, `Win32_Graphics_Direct3D_Dxc`, `Win32_UI_WindowsAndMessaging`,
`Win32_System_Threading`, `Win32_System_LibraryLoader`, `Win32_Graphics_Gdi`, …). Compile errors
name the missing feature — annoying once, mechanical forever after.

## Repository layout & port conventions

The port lives in **`rust_port/`** as a Cargo workspace — Rust conventions, not the book's
per-demo-solution layout:

```
rust_port/
├── Cargo.toml            # [workspace] members = ["common", "demos/*"]
├── common/               # the book's Common/ as a library crate
└── demos/
    ├── c1_xmvector/      # one binary crate per demo
    ├── c4_init_d3d/
    ├── c6_box/
    └── …
```

- **Assets are referenced in place** — the book's `Models/`, `Textures/`, `Shaders/` at the
  repo root are shared, not copied. `common::asset_path(rel)` resolves them by walking up
  from `current_exe()` until it finds the directory containing `Shaders/` + `Textures/`, so
  `cargo run` works from any working directory (and survives a custom `CARGO_TARGET_DIR`
  inside the repo). Use it for every shader/texture/model load.
- **Tool binaries (DXC, Agility SDK) are fetched by a documented setup step, not by
  `build.rs`** — `rust_port/setup.ps1` runs `nuget install -ExcludeVersion` (stable,
  version-free paths) into the gitignored `rust_port/tools/`. Demo `build.rs` scripts only
  *copy* DLLs from `tools/` to the exe directory and fail with a pointer to the README if
  `tools/` is missing; builds never touch the network.
- **Provenance comments are mandatory.** Some "Common" code in the 2nd edition is really
  DirectXTK12's, and the port must not blur that: any module that is a (partial) port of
  DirectXTK12 code gets a header comment naming the source file, e.g.
  `//! Partial port of DirectXTK12's GraphicsMemory/LinearAllocator (MIT License).`
  This applies at least to the upload arena (`GraphicsMemory`), the static-buffer helper
  (`BufferHelpers::CreateStaticBuffer`), and the texture-upload path
  (`ResourceUploadBatch`/`DDSTextureLoader`). Code ported from the book's own `Common/` or
  demo sources just names the book file (`//! Port of Common/d3dApp.cpp`). Reference-while-
  learning only works if the reader can tell which original to open.
- **Behavior parity first.** Match the C++ demos' behavior before polishing; `unsafe` is
  fine and expected, but every `unsafe` block carries a `// SAFETY:` comment stating the
  invariant that makes it sound, per Rust convention. Cleverness (safe wrappers, lifetimes,
  abstractions) is a later pass, if ever.
- **imgui-rs is adopted provisionally** — evaluated for real at the first demo that needs it
  (ch 4). If the backend situation disappoints, that's the decision point, not before.

### Building the C++ originals (the reference you're porting *from*)

Verified working (2026-07): VS 2022 Build Tools, per-demo solutions.

1. `nuget restore <demo>.sln` once per demo (fetches Agility SDK `Microsoft.Direct3D.D3D12`).
2. `msbuild <demo>.sln -p:Configuration=Debug -p:Platform=x64`. The two Part I console
   projects (C1, C2) are stale v140 projects — add
   `-p:PlatformToolset=v143 -p:WindowsTargetPlatformVersion=10.0` for those; everything else
   is already v143.
3. DXC binaries are gitignored out of `External\dxc` — restore them from the
   `Microsoft.Direct3D.DXC` NuGet into `External\dxc\bin\x64` + `External\dxc\lib\x64`, and
   copy `dxcompiler.dll`/`dxil.dll` into `bin\` next to the exes (exe-dir DLL search beats
   the Vulkan SDK's PATH entry — see the PATH trap under Shaders).
4. Run demos **from the `bin\` directory** (shader paths are relative to it).

## Global conventions (read once, applies everywhere)

### Matrices — the big one, read twice

glam differs from DirectXMath on convention but — unlike most GL-flavored math crates — **not on
target API**: glam's `_lh` builders produce exactly the left-handed, `[0,1]`-depth matrices the
book derives. Verified in the glam source:

- `Mat4::look_at_lh(eye, at, up)`
- `Mat4::perspective_lh(fov_y, aspect, z_near, z_far)` — depth `[0,1]`, D3D-style
- `Mat4::orthographic_lh(left, right, bottom, top, near, far)` — depth `[0,1]`, and it's
  off-center-capable, so it covers `XMMatrixOrthographicOffCenterLH` too (ch 20)

So the view/projection matrices come from the library — no hand-rolled `d3d_math` module for
those. What *does* differ is the convention:

- **glam is column-vector** (`v' = M * v`), so concatenation reads **right-to-left** — the
  reverse of the book. Every `world * view * proj` in the text becomes `proj * view * world`
  in your Rust. This is the one mental flip of the whole port; it applies to every matrix
  product in every chapter.
- **glam's matrix values are the transpose of the book's printed matrices.** A column-vector
  matrix is the transpose of the equivalent row-vector matrix, so when Luna prints a translation
  matrix with the offsets in the bottom row, glam puts them in the last *column*. When
  verifying ch 1–3 numbers, compare behavior (transform a known point) rather than eyeballing
  matrix elements.
- **Transpose before every CB upload, exactly like the book.** Keep the book's HLSL verbatim
  (`mul(pos, gWorldViewProj)`, default column-major packing) and do:

  ```rust
  let wvp = proj * view * world;          // reversed order (column-vector)
  cb.world_view_proj = wvp.transpose();   // same transpose line as the book
  ```

  This produces **byte-identical constant-buffer contents** to the book's
  `XMStoreFloat4x4(&cb, XMMatrixTranspose(worldViewProj))` — the two convention flips
  (transposed values, reversed order) and the storage flip (column-major vs row-major) cancel
  exactly. Trust the rule, verify the CB bytes once at ch 6, and never think about it again.

(Filed for after the book: glam's native path is to upload `Mat4` bytes *untransposed* and flip
the HLSL to `mul(gWorldViewProj, pos)` — that's what most Rust engines do, and it deletes every
transpose. It also stops matching the book's shader listings, so do it as a cleanup pass once
you no longer need your code to read line-for-line with the text.)

One more convention casualty: any code that *builds a matrix from basis vectors* (the ch 15
camera assembling its view matrix from right/up/look rows) — the book fills rows, you fill
columns (`Mat4::from_cols`), or build it the book's way and transpose once. Same for frustum
plane extraction at ch 16: plane-from-matrix formulas are convention-sensitive; use the
column-vector form (planes from rows of `proj`, i.e. columns of the book's version).

### Vectors — a genuine simplification

`Vec3`/`Vec4` are plain `#[repr(C)]` value types with full operator overloading, so there is
**no load/store split** — `XMFLOAT3` vs `XMVECTOR` and every `XMLoadFloat3`/`XMStoreFloat3`
pair in the book simply disappears. The same `Vec3` lives in your vertex structs and does math.
Swizzles come from traits: `use glam::{Vec3Swizzles, Vec4Swizzles};` gives you `v.xxxx()`,
`v.xyz()`, `v.zyxw()` as methods.

Nuance worth knowing once: `Vec3` is scalar (12 bytes); `Vec4`, `Quat`, and `Mat4` are
SIMD-backed. glam also has `Vec3A` (16-byte aligned SIMD `Vec3`) — **don't** use it, especially
not in GPU-visible structs: its 16-byte size breaks the HLSL `float3`-then-`float` packing that
plain `Vec3` + explicit pad fields models correctly. Plain `Vec3` everywhere is the right call
at this book's scale.

### Constant-buffer layout

Same two rules as any D3D12 port, both manual:

1. Each CB allocation is 256-byte aligned:
   `fn calc_cb_size(n: usize) -> usize { (n + 255) & !255 }`.
2. HLSL packs fields into 16-byte registers (a `float3` then a `float` shares one; two
   `float3`s don't). Port `Shaders/SharedTypes.h` once into a `shared_types.rs` of
   `#[repr(C)] #[derive(Clone, Copy, Pod, Zeroable)]` structs with explicit `_pad` fields.

Enable glam's `bytemuck` feature so `Vec3`/`Vec4`/`Mat4` are `Pod`, and every CB write is
`bytemuck::bytes_of(&cb)` into the mapped pointer — no casts, no UB. Getting rule 2 wrong
produces garbage transforms, not errors. Matrices go in transposed (see Matrices).

### GPU memory — no allocator crate needed

The book never suballocates GPU heaps: every resource in `Demos/` and `Common/` is a
**committed resource** (`CreateCommittedResource` — one implicit heap per resource,
driver-managed). No `CreatePlacedResource`, no DX12MA — so you don't need `gpu-allocator`
either. Skip it; it solves a problem the book never has. (Placed-resource suballocation is a
good *post-book* project, and `gpu-allocator` is the crate for it then.)

What the book *does* lean on is DirectXTK12's **`GraphicsMemory`** — a fence-retired linear
(bump) allocator over upload heaps. `D3DApp::Initialize` creates it, and every demo uses it
per frame: `mLinearAllocator->AllocateConstant(objectConstants)` per render item hands back a
GPU virtual address for a transient CB, and `Commit(queue)` after submit retires pages against
the fence. (The demos even display its `GetStatistics()` in the ImGui overlay.) Your
replacement is a **per-frame upload arena**: one big mapped upload buffer per frame-in-flight,
a bump pointer with 256-byte-aligned `alloc_constant(&cb) -> GpuVirtualAddress`, reset when
that frame's fence completes. ~60 lines, built once at ch 4–6, used by every demo after.

### COM ref counting — mostly free

This is the headline ergonomic win: **windows-rs interfaces *are* ComPtr.** Every
`ID3D12Device`, `IDXGISwapChain3`, `ID3D12Resource` is a smart pointer — `Clone` is `AddRef`,
`Drop` is `Release`. The book's ComPtr discipline compiles away:

- No `Release()` calls anywhere. Fields drop when your struct drops; locals drop at scope end.
- `swapChain1.As(&mSwapChain)` = `swap_chain1.cast::<IDXGISwapChain3>()?` — `QueryInterface`
  returning a new smart pointer; the old one just drops.
- `ComPtr::Reset()` = assigning `None` to an `Option<ID3D12Resource>` field.
- Out-params come in two shapes: some creators return `Result<T>` directly
  (`CreateCommandQueue`, `CreateFence`…), others fill a generic `&mut Option<T>`
  (`D3D12CreateDevice`, `CreateCommittedResource`, `GetBuffer`…). Both hand you an owned smart
  pointer; the shape difference is mechanical.

Two things ref counting still can't do for you:

1. **The `OnResize` trap survives, translated.** `ResizeBuffers` demands zero outstanding
   back-buffer references — in Rust that means *drop the handles*: store back buffers as
   `[Option<ID3D12Resource>; N]` (or a `Vec` you `clear()`) and `None` them all, plus the depth
   buffer, before calling `ResizeBuffers`. Forget one clone stashed somewhere and you get the
   same `E_INVALIDARG`. The borrow checker doesn't see COM refs.
2. **GPU lifetime is still manual.** Drop only proves the *CPU* is done. Staging buffers,
   scratch AS buffers, and anything in-flight must outlive the fence that retires them — park
   them in a `Vec<(u64 /* fence value */, ID3D12Resource)>` and drain it as fences complete.
   This replaces the book's "keep the ComPtr alive" comments and is the #1 remaining lifetime
   bug class.

### Error handling

`ThrowIfFailed(hr)` → the `?` operator. windows-rs APIs return
`windows::core::Result<T>`; make your init functions return `Result<()>` and every call is one
line ending in `?`, with a real error (HRESULT + message) propagating out. Nothing to write on
day one — the language did it.

### unsafe

Nearly every D3D12/DXGI method in windows-rs is `unsafe fn` — raw pointers, GPU lifetimes, and
mapped memory are genuinely unsafe and the bindings don't pretend otherwise. Expect `unsafe`
blocks around all rendering code. Don't fight it and don't over-wrap it: a few safe helpers
where a pattern repeats (barriers, CB writes via bytemuck), plain `unsafe` blocks elsewhere.
This is FFI-heavy systems code; the book's C++ was all "unsafe" too, just unlabeled.

### d3dx12.h

Don't port it. `..Default::default()` struct-update syntax covers most `CD3DX12_*`
initializers; write tiny helpers (`transition_barrier(resource, before, after)`) the first time
a pattern repeats, and grow a `d3d12_util.rs` organically. (The windows-rs repo's
`samples/windows/direct3d12` has a minimal `d3dx12.rs` worth skimming for idioms — barrier
helpers, subresource math — though it's triangle-sized, not book-sized.)

### Debug layer

Enable `ID3D12Debug` (and GPU-based validation while learning) from the first triangle:
`D3D12GetDebugInterface` → `EnableDebugLayer`, `.cast::<ID3D12Debug1>()` for GPU validation.

On AMD (RDNA 4): AMD drivers are stricter than the NVIDIA cards the book was tested on — treat
every debug-layer warning as an error and your port ends up *more* correct than the original.
The book's shaders/features are vendor-neutral (no wave intrinsics, no NVAPI); the 9070 XT runs
everything including ch 26–27.

`ID3D12InfoQueue1` (message callbacks → stderr) and DRED are already bound — the ch 4 side
quest needs no binding work.

### Shaders

Two workable options — the book's own flow is available:

- **Mirror the book (recommended):** `Win32::Graphics::Direct3D::Dxc` binds
  `DxcCreateInstance`, `IDxcCompiler3`, `IDxcUtils`, `IDxcResult` fully. Port
  `d3dUtil::CompileShader` and the `ShaderLib::Init` table nearly line-for-line; you keep
  edit-shader-and-rerun iteration with no build step. One chore the bindings don't do:
  **ship `dxcompiler.dll` + `dxil.dll` next to your exe** (from the `Microsoft.Direct3D.DXC`
  NuGet package or DirectXShaderCompiler GitHub releases; a tiny `build.rs` copy step keeps
  `target/debug` populated).
- **Precompile offline:** a `build.rs` that shells out to `dxc.exe` per entry in the book's
  shader table, then `include_bytes!("shader.dxil")`. Cargo makes this clean (rerun-if-changed
  on the HLSL), but you lose runtime iteration.

**PATH trap — pin DXC to the project.** If the Vulkan SDK is installed, its `dxc.exe` (and
`dxcompiler.dll`) sit on `PATH` and will shadow Microsoft's — silently, and PATH order can
shift out from under you. Never invoke bare `dxc` and never rely on PATH DLL search:

- Runtime path: Windows' DLL search order checks the **exe's directory before PATH**, so a
  `dxcompiler.dll`/`dxil.dll` copied next to your exe wins over the Vulkan SDK's. That
  `build.rs` copy step is your defense, not just a convenience.
- Offline path: have `build.rs` invoke the vendored copy by **absolute path**
  (`tools/dxc/dxc.exe` in-repo), never `dxc` from PATH.
- Keep the binaries out of git: vendor them under e.g. `tools/dxc/` and `.gitignore` the
  `*.dll`/`*.exe` (they're large); restore via `nuget install` or a small fetch script noted
  in the README. Same treatment for the Agility SDK's `D3D12Core.dll` if you use it (ch 4).

Either way, every permutation is a `-D` define (`ALPHA_TEST`, `SKINNED`, `DRAW_INSTANCED`,
`IS_SHADOW_PASS`) and all targets are `*_6_6`.

---

## Part I — Mathematical Prerequisites (ch 1–3)

**Runs anywhere** — no GPU, no Windows needed; glam is fully cross-platform. Port the
`C1_XMVECTOR`/`C2_XMMATRIX` console demos as Rust binaries or `#[test]` functions asserting
expected values. Skip `XMVerifyCPUSupport`.

### DirectXMath → glam cheat sheet

Types: `XMVECTOR` → `Vec4` (SIMD-backed), `XMFLOAT2/3/4` → `Vec2`/`Vec3`/`Vec4` (same type for
storage *and* math — no load/store), `XMMATRIX`/`XMFLOAT4X4` → `Mat4` (ditto), quaternions →
`Quat`. `use glam::*;` plus the swizzle traits (`Vec3Swizzles`, `Vec4Swizzles`).

| DirectXMath (as used in book) | glam | Note |
|---|---|---|
| `XMVectorSet(x,y,z,w)` | `vec4(x, y, z, w)` | or `Vec4::new` |
| `XMVectorZero()` | `Vec4::ZERO` | |
| `XMVectorReplicate(s)` / `SplatOne` | `Vec4::splat(s)` / `Vec4::ONE` | |
| `XMVectorSplatX(v)` | `v.xxxx()` | swizzle trait |
| `XMVectorSwizzle<...>(v)` | `v.zyxw()` etc. | |
| `u + v`, `u - v`, `k * v` | same — native operators | |
| `XMVectorMultiplyAdd(a,b,c)` | `a * b + c` | |
| `XMVectorMin/Max/Abs` | `a.min(b)` / `a.max(b)` / `v.abs()` | |
| `XMVectorLerp/Saturate` | `a.lerp(b, t)` / `v.clamp(Vec4::ZERO, Vec4::ONE)` | |
| `XMVectorSqrt/Cos` | `v.sqrt()` / `v.cos()` | element-wise on `Vec4`; DXM's transcendentals are minimax polynomial approximations, so expect last-ulp diffs vs libm (e.g. cos(π/2)) |
| `XMVectorLog/Exp` | `v.log2()` / `v.exp2()` | **base 2** in DirectXMath despite the names — verified against the C1 demo |
| `XMVectorPow(u, p)` | per-lane `u.x.powf(p.x)`, … | glam's `powf` takes a scalar exponent |
| `XMVector3Dot(u,v)` | `u.dot(v)` | returns scalar (no splat dance) |
| `XMVector3Cross(u,v)` | `u.cross(v)` | |
| `XMVector3Length / LengthSq` | `v.length()` / `v.length_squared()` | |
| `XMVector3Normalize(v)` | `v.normalize()` | `normalize_or_zero` for the safe variant |
| `XMVector3Greater(u,v)` | `u.cmpgt(v).all()` | `BVec` compare + reduce |
| `XMVectorGetX(v)` | `v.x` | |
| `XMLoadFloat3` / `XMStoreFloat3` (etc.) | *(delete them)* | no load/store split |
| `XMMatrixIdentity()` | `Mat4::IDENTITY` | |
| `XMMatrixScaling(x,y,z)` | `Mat4::from_scale(vec3(x,y,z))` | |
| `XMMatrixTranslation(x,y,z)` | `Mat4::from_translation(vec3(x,y,z))` | |
| `XMMatrixRotationX/Y/Z(a)` | `Mat4::from_rotation_x/y/z(a)` | |
| `XMMatrixRotationAxis(ax, a)` | `Mat4::from_axis_angle(ax, a)` | axis must be normalized |
| `XMMatrixRotationRollPitchYaw(p,y,r)` | `Mat4::from_euler(EulerRot::YXZ, yaw, pitch, roll)` | or explicit `from_rotation_y(y) * from_rotation_x(p) * from_rotation_z(r)`; verify once against a book number |
| `A * B`, `XMMatrixMultiply(A,B)` | **`B * A`** | column-vector: concatenation order reverses — the key row of this table |
| `XMMatrixTranspose(M)` | `m.transpose()` | still needed before CB upload — same as the book |
| `XMMatrixInverse(&det, M)` | `m.inverse()` | det separately: `m.determinant()` |
| `XMMatrixDeterminant(M)` | `m.determinant()` | |
| `XMMatrixLookAtLH(eye,at,up)` | `Mat4::look_at_lh(eye, at, up)` | ✓ built in |
| `XMMatrixPerspectiveFovLH` | `Mat4::perspective_lh(fov_y, aspect, zn, zf)` | ✓ D3D `[0,1]` depth |
| `XMMatrixOrthographicOffCenterLH` | `Mat4::orthographic_lh(l, r, b, t, zn, zf)` | ✓ off-center capable (ch 20) |
| `XMVector3TransformCoord(v, M)` | `m.project_point3(v)` | exact match (does the w-divide); `m.transform_point3(v)` is the faster affine-only variant — fine for world/view matrices |
| `XMVector3TransformNormal(v, M)` | `m.transform_vector3(v)` | w=0, kills translation |
| `XMConvertToRadians(d)` | `d.to_radians()` | |
| `XM_PI`, `XM_PIDIV4`… | `std::f32::consts::PI`, `FRAC_PI_4` | |
| `XMQuaternionRotationAxis` | `Quat::from_axis_angle` | ch 22 |
| `XMQuaternionSlerp` | `a.slerp(b, t)` | ch 22 |
| `XMMatrixRotationQuaternion` | `Mat4::from_quat(q)` | ch 22; column-convention output — the uniform transpose-on-upload rule covers it |
| `XMMatrixAffineTransformation` | `Mat4::from_scale_rotation_translation(s, q, t)` | **no rotation-origin param** — compose `T * Mo * R * Mo⁻¹ * S` yourself where the book passes one (ch 22–23) |

**Known gaps** (all small; the book derives each formula, so implementing them *is* the
exercise):

- `XMMatrixReflect` / `XMMatrixShadow` (ch 11) — hand-roll into a small `math_util.rs`,
  remembering to build the *column-vector* (transposed) form
- rotation-about-a-point affine composition (ch 22–23, above)
- everything from `DirectXCollision` (ch 16–17) — hand-roll; crates like `parry3d` exist, but
  writing the ~4 tests the book needs is the point
- `XMCOLOR` (packed 32-bit BGRA) → pack a `u32` yourself

### Chapter notes

- **Ch 1 Vector Algebra** — vector rows above. Enjoy deleting every load/store call.
  **Ported:** `rust_port/demos/c1_xmvector` — as tests (`cargo test -p c1_xmvector`): a
  single `src/lib.rs` read top-to-bottom next to the chapter, with one `#[test]` per C++
  variant asserting values captured from the C++ demos' output.
  Exact values use `assert_eq!`; cout-rounded values use `common::testing::assert_close*`
  (std has no approximate float asserts; glam's `abs_diff_eq` underneath). Notable findings
  encoded in the tests: `XMVectorLog`/`Exp` are base-2, and DirectXMath's polynomial
  `XMVectorCos` differs from libm in the last ulps on the π/2 lane.
- **Ch 2 Matrix Algebra** — matrix rows. Remember: glam's element values are the transpose of
  the book's printed matrices — write your `assert`s against transformed *points*, not raw
  elements, or transpose the expectations.
- **Ch 3 Transformations** — where the convention flip must click. Take the book's `S*R*T`
  example, write it as `T * R * S` in glam, and verify the composite transforms the book's test
  points to the book's answers. Once this test passes you've internalized the whole convention
  section.

---

## Appendix A — Introduction to Windows Programming *(do between ch 3 and ch 4)*

**Depends on:** the `windows` crate's Win32 UI features only. No D3D, no glam.

**Port notes:**

- Full surface available: `WNDCLASSEXW`, `RegisterClassExW`, `CreateWindowExW`, `ShowWindow`,
  `GetMessageW`/`PeekMessageW`, `TranslateMessage`, `DispatchMessageW`, `DefWindowProcW`,
  `WM_*` constants.
- Wide strings: `w!("MainWnd")` gives you a `PCWSTR` from a literal at compile time; `HSTRING`
  for runtime strings.
- The `WndProc`: `extern "system" fn wnd_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM)
  -> LRESULT` — a free function, which raises Rust's classic question: *how does it reach your
  app state?* The standard answer: pass `&mut App` via `CreateWindowExW`'s `lpparam`, stash it
  with `SetWindowLongPtrW(hwnd, GWLP_USERDATA, ptr)` in `WM_CREATE`/`WM_NCCREATE`, and recover
  it at the top of `wnd_proc`. Write this once, carefully (it's `unsafe` and easy to get subtly
  wrong before the pointer is set); it serves every demo in the book. Resist the urge to reach
  for `static mut`.
- The book's appendix uses `GetMessage` (blocking); ch 4 switches to `PeekMessage` (game loop).
  Do both.
- (winit exists and is fine, but raw Win32 is the book's Appendix A material — port it; that's
  the exercise.)

---

## Part II — Direct3D Foundations

### Ch 4 — Direct3D Initialization  ⟵ *the big front-load*

**Port first (becomes your permanent shared layer):**

- `GameTimer` — `std::time::Instant` makes this trivial (or `QueryPerformanceCounter`, bound,
  if you want to match the book's arithmetic exactly).
- `DescriptorUtil` — RTV/DSV heap wrappers now, CBV/SRV/UAV at ch 9. Handle math is
  `heap_start.ptr + index * increment_size`.
- The `D3DApp` equivalent — a struct with `init`/`run`; per-chapter demos share it via a trait
  (`fn update(&mut self, dt)`, `fn draw(&mut self)`) or by copying the loop. No virtual base
  class needed; a trait object or plain generics both work.

**Agility SDK — probably optional for you:** on Windows 11 the inbox D3D12 runtime already
supports SM 6.6 (the book's baseline), so you can likely skip Agility entirely. If you do want
it (or are on Windows 10):

```rust
#[no_mangle]
pub static D3D12SDKVersion: u32 = 614;
#[no_mangle]
pub static D3D12SDKPath: [u8; 9] = *b".\\D3D12\\\0";
```

…in the *binary* crate root, ship `D3D12Core.dll` in `.\D3D12\`, and verify the exports land in
the exe's export table (`dumpbin /exports`) — this is the fact to test, not assume.

**Lifetime traps concentrated in this chapter** (the ComPtr list, post-translation):

1. **`OnResize` / `GetBuffer`.** Set every back-buffer `Option` to `None` (and the depth
   buffer) before `ResizeBuffers`, or it fails with `E_INVALIDARG` / "buffer still referenced".
   Each subsequent `GetBuffer` hands you a fresh owned pointer. Audit for stray clones — this
   is the one place COM's refcount and Rust's ownership visibly disagree.
2. **`FlushCommandQueue` before dropping anything the GPU might still read** (resize,
   shutdown). Signal fence → `SetEventOnCompletion` → `WaitForSingleObject`. Port it exactly.
   On shutdown, an explicit flush in `Drop` (or a `shutdown()` you call deliberately) — field
   drop order alone is not a GPU sync.
3. **`.As()` upgrades** = `.cast::<T>()?` — the old interface drops naturally; nothing to
   remember here, which is the point.
4. **Adapter enumeration** — enumerate freely; unkept adapters drop themselves.
5. **Shutdown order** — flush queue first; Rust drops fields in declaration order, so either
   order your struct fields children-before-device or use explicit `Option::take()` teardown.
   Keep a debug `ReportLiveObjects` (via `DXGIGetDebugInterface1`) to catch stragglers.

**imgui:** the honest weak spot of the Rust stack — but a *narrow* one. First, scope: every
demo in the book (all 33, ch 4 through 27) has an ImGui overlay, but the entire widget
vocabulary across the whole book is **eight calls** — `Begin`/`End`, `Text`, `Checkbox`,
`CollapsingHeader`, `SliderFloat`/`SliderFloat3`/`SliderInt` — plus `GetIO` (FPS +
`WantCaptureMouse` gating in the mouse handlers) and the `Render`/`GetDrawData` frame wiring.
It's a stats-and-tweakables overlay, not a UI framework dependency.

The `imgui` crate (imgui-rs) maps those calls ~1:1 (`ui.text`, `ui.slider`, `ui.checkbox`),
but there is no first-party Win32+DX12 backend; community renderers exist with varying
freshness (check the current state of `imgui-dx12-renderer` and friends). The reliable
fallback: port the C++ `imgui_impl_win32.cpp`/`imgui_impl_dx12.cpp` backends yourself against
imgui-rs's draw-data API — an evening or two, and after ch 6 you'll have every D3D12 skill it
needs. Wire it like the book: backend WndProc handler first in `wnd_proc`,
init/new-frame/render around the draw.

(egui is not an escape hatch here: it has no first-party D3D12 backend either — its native
paths are wgpu/glow, and embedding egui-wgpu would drag a second graphics stack alongside your
raw D3D12. Community D3D12 renderers for egui are no more established than imgui's. Given the
book's eight-widget surface, imgui-rs + a small hand-ported backend is the path of least
resistance *and* keeps per-demo UI code matching the book's listings.)

**Verify:** cornflower-blue window, FPS in title bar, repeated resize works (trap #1), debug
layer silent.

#### Side quest: debug-layer output to stderr

Same motivation as ever (the debug layer speaks `OutputDebugString`; lightweight editors hear
nothing) — and in Rust it's nearly free, because **`ID3D12InfoQueue1` and
`RegisterMessageCallback` are already bound**:

- `device.cast::<ID3D12InfoQueue1>()?`, register an `extern "system"` callback, print
  severity/ID/description to stderr. Vulkan-validation-layer experience achieved. (The callback
  is a plain fn — no closure captures; pass context through the `pcontext` pointer if needed.)
- `SetMuteDebugOutput(true)` to stop the duplicate debugger-channel output;
  `SetBreakOnSeverity` for ERROR/CORRUPTION when a debugger is attached.
- DXGI's separate info queue (leak reports at exit) is also bound (`IDXGIInfoQueue` via
  `DXGIGetDebugInterface1`) — poll it at shutdown so leak reports land in stderr too.

**DRED** (`ID3D12DeviceRemovedExtendedData` — breadcrumbs + page faults on device removal) is
bound as well; enabling it is a few lines and worth doing before the compute chapters.
DirectX Dump Files remain preview-only (preview Agility SDK + preview driver + preview PIX) —
park until retail (~Fall 2026).

### Ch 5 — The Rendering Pipeline

Theory, no demo. Two porting hooks: this chapter derives the perspective matrix —
`Mat4::perspective_lh` already implements it, so instead of typing it in, *check glam's source
against the book's derivation* (they match, transposed) — and it explains the data you'll lay
out in `shared_types.rs` at ch 6.

### Ch 6 — Drawing in Direct3D  *(Box, BoxGrid)*

**Port first:**

- The **per-frame upload arena** (see GPU memory in the conventions) becomes load-bearing
  here: the book's demos call `mLinearAllocator->AllocateConstant(objectConstants)` per render
  item per frame and bind the returned GPU virtual address directly. Your arena's
  `alloc_constant` is that call. `Map` the arena buffer once, hold the raw pointer, bump-write
  with bytemuck, never unmap; `unsafe` inside a safe wrapper.
- `MeshGeometry`/`SubmeshGeometry` (from `MeshUtil.h`) — buffer views struct; stash submesh
  bounds as plain `Vec3` min/max for now (functional at ch 16).
- **Buffer-upload helper** (replaces DirectXTK12 `CreateStaticBuffer`): default-heap resource +
  upload-heap staging + `CopyBufferRegion` + barrier. **Keep the staging buffer alive until the
  copy's fence completes** — return it to the caller or push it into your fence-keyed
  retirement list; letting it drop at end of scope is the #2 lifetime bug after the resize trap,
  and in Rust it happens *by default* if you're not deliberate.
- The dxc-based `compile_shader` (per the Shaders convention) + the DLL-copy `build.rs` step.
- Root signature + PSO + input layout. Semantic names in `D3D12_INPUT_ELEMENT_DESC` are
  `PCSTR`s — use `s!("POSITION")` for compile-time null-terminated literals. Vertex structs:
  `#[repr(C)] #[derive(Pod, Zeroable, ...)]`, uploaded via `bytemuck::cast_slice`.

**Watch out:**

- First contact with CB packing and transpose-on-upload. A sheared or garbled box = wrong
  packing, missing transpose, or concatenation order not reversed (the glam bullet you skimmed
  — go reread Matrices). Verify the CB bytes once against a hand-computed matrix and trust it
  afterward.
- `Camera` first appears (simple form); port what's needed, full version at ch 15.

### Ch 7 — Drawing Part II  *(Shapes, Waves)*

**New this chapter:**

- The **FrameResource** pattern (per-frame allocator + upload buffers + fence value) — the
  book's core CPU/GPU parallelism idiom; internalize it here. In Rust it's a plain
  `Vec<FrameResource>` ring; ownership of the per-frame upload buffers falls out naturally.
- `MeshGen` (procedural box/grid/sphere/cylinder) — pure math; ports cleanly.
- Render-item lists — `Vec<RenderItem>`. The book's raw-pointer links between render items and
  geometry become indices (`usize` into your geometry/material vecs) — fight the urge to model
  it with references and lifetimes; indices are the idiomatic move and match the book's spirit.
- Waves CPU sim: `parallel_for` → `rayon` `par_iter_mut` is a genuine 1:1; or serial first.

**Watch out:** fence bookkeeping — wait only when the frame-resource ring wraps. Off-by-one =
flicker or hangs.

### Ch 8 — Lighting  *(LitShapes, LitWaves)*

**New this chapter:** `Light`/`MaterialData` in `shared_types.rs` — the float3-next-to-scalar
packing minefield at its worst; normals in `MeshGen`. Nothing new externally.

### Ch 9 — Texturing  *(Crate, TexturedShapes, TexWaves)*

**Port first:**

- **DDS loading** — the `ddsfile` crate parses the container (magic, `DDS_HEADER`, DX10
  header, per-mip data slices) for all the formats the book's ~60 textures use (BC1/3/5/7 +
  uncompressed). You write a thin mapping layer: `ddsfile` format enum → `DXGI_FORMAT`, plus
  per-mip pitch math. Small glue, not a parser.
- **Texture upload helper** (replaces `ResourceUploadBatch`): `GetCopyableFootprints` → copy
  into upload buffer respecting the **256-byte-aligned row pitch** (row by row, not one copy) →
  `CopyTextureRegion` per subresource → barrier. DDS mips are pre-baked; no mip generation
  anywhere in the book. Most fiddly helper in the port; budget an evening.
- `TextureLib`/`MaterialLib` — `HashMap<String, ID3D12Resource>`; load only what the chapter
  needs.
- CBV/SRV/UAV heap in `DescriptorUtil`; static samplers array.

**Watch out:** the book's shaders index `ResourceDescriptorHeap[]` (SM 6.6 dynamic resources) —
the shader-visible heap layout is the contract; keep indices identical to the book's or textures
silently swap.

### Ch 10 — Blending  *(BlendDemo)*

**New this chapter:** blend/alpha-test PSO variants — config, not code.

### Ch 11 — Stenciling  *(Stenciling)*

**New this chapter:**

- Depth/stencil PSO states.
- Hand-roll `matrix_reflect(plane)` / `matrix_shadow(plane, light)` into `math_util.rs` — the
  chapter derives both. Build the column-vector (transposed) forms, and verify by reflecting a
  known point, not by comparing elements to the book's printed matrix.

### Ch 12 — The Geometry Shader  *(BillboardsGS)*

**New this chapter:** GS stage in the PSO; a texture2DArray DDS — `ddsfile` handles the DX10
array header; your ch 9 upload helper must loop `array_size * mip_levels` subresources. Extend
it now if you cut that corner.

### Ch 13 — The Compute Shader  *(VecAddCS, Blur, WavesCS)*

**New this chapter:**

- UAVs + compute PSOs/root signatures.
- `VecAddCS`: readback heap + `Map` after fence (the book's one GPU→CPU copy) —
  `bytemuck::cast_slice` on the mapped bytes, inside the obvious `unsafe`.
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
Pure glam. Reminder from Matrices: the book assembles the view matrix from basis-vector *rows*;
you assemble columns (`Mat4::from_cols`) or transpose once at the end. Portable-laptop chapter.

### Ch 16 — Instancing and Frustum Culling

**Port first:**

- The book centralizes shaders/PSOs here (`ShaderLib`/`PsoLib`) — natural `HashMap`s (or a
  small enum-indexed array if you prefer compile-time names).
- **`collision.rs`**: `BoundingBox` (center/extents), `BoundingFrustum` from the projection
  matrix, box-vs-frustum test. Book explains the plane math; `DirectXCollision.h` is the
  reference if stuck.

**New this chapter:** structured-buffer instance data (SRV — no 256-byte/packing rules).

**Watch out:** frustum is extracted in view space, transformed to local space with
`(world * view).inverse()` — mind the reversed multiply — wrong space = flickering culling.
And frustum-plane extraction formulas are convention-sensitive: derive them for glam's
column-vector matrices (the book's row-based extraction, transposed).

### Ch 17 — Picking

**New this chapter:** ray/AABB and ray/triangle (Möller–Trumbore) tests into `collision.rs`.
Picking ray: screen → NDC → view → local, all `inverse()` + `transform_point3`/
`transform_vector3`.

### Ch 18 — Cube Mapping  *(C18C19_CubeAndNormalMapping, DynamicCubeMap)*

**New this chapter:**

- Cubemap DDS (6 array slices × mips — the ch 12 array path covers it; `ddsfile` flags
  cubemaps) + TextureCube SRV.
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
- Light frustum: `Mat4::orthographic_lh` — already in glam, off-center and all. No hand-rolling.

**Watch out:** shadow map state ping-pongs `DEPTH_WRITE` ↔ `PIXEL_SHADER_RESOURCE` every frame.

### Ch 21 — Ambient Occlusion  *(Ssao)*

**New this chapter:** normal/depth prepass targets, random-vector texture from CPU memory (your
ch 9 upload helper, from a byte slice), offset vectors CB, bilateral blur ping-pong. Most
render-target plumbing so far; nothing new in dependencies.

### Ch 22 — Quaternions  *(QuatDemo)*

**New this chapter:**

- `Quat` + `Quat::from_axis_angle` / `slerp` / `Mat4::from_quat` (transpose-on-upload rule
  covers the convention, as everywhere).
- `Mat4::from_scale_rotation_translation` covers the common case; where the book passes a
  rotation *origin* to `XMMatrixAffineTransformation`, compose the origin conjugation yourself.
- Keyframe animation helper — lerp/slerp between keys.

### Ch 23 — Character Animation  *(SkinnedMesh)*

**New this chapter:**

- `.m3d` parser + `SkinnedData`: the format is plain text with labeled sections —
  `split_whitespace` + `parse::<f32>()`; a pleasant evening. (Or a `nom` excuse, if you want
  one.)
- Skinned vertex adds `bone_weights: [f32; 3]` + `bone_indices: [u8; 4]` (4th weight =
  `1 - sum`; input layout slot is `R8G8B8A8_UINT`).
- Bone palette CB + the `SKINNED` shader define.

### Ch 24 — Terrain Rendering  *(Terrain)*

**New this chapter:** `.raw` heightmap = `std::fs::read` + `bytemuck::cast_slice::<u8, u16>`
(~5 lines; mind endianness never matters here, it's x86). Blend maps are more DDS. Reuses
ch 14 tessellation + `collision.rs` patch culling.

### Ch 25 — Particle Systems  *(ParticlesCS)*

**New this chapter:** structured-buffer particle pools; emit/update/post-update CS entries;
blend PSOs from ch 10; `Random.h` → `fastrand` (or `rand`).

**Watch out:** UAV barriers between the three dispatches.

### Ch 26 — Amplification & Mesh Shaders  *(ParticlesMS, TerrainMS)*

**New this chapter:**

- `ID3D12GraphicsCommandList6::DispatchMesh` (bound), `ms_6_6`/`as_6_6` targets,
  `CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS7)`.

**Watch out — the PSO changes shape:** mesh-shader PSOs go through
`ID3D12Device2::CreatePipelineState` with a **pipeline state stream** — packed,
alignment-sensitive `{subobject-type tag, payload}` records. The bindings define the enum/desc
types but there's no `CD3DX12_PIPELINE_STATE_STREAM` equivalent — build the stream struct
yourself with `#[repr(C)]`, explicit padding, and `align(8)` guarantees checked by
`static_assert`-style `const` blocks. Fiddliest struct-layout task in the port.

### Ch 27 — Ray Tracing  *(IntroRayTracing, HybridRayTracing)*

**New this chapter:**

- DXR, all bound: `device.cast::<ID3D12Device5>()?`, `CreateStateObject`, BLAS/TLAS builds,
  shader binding table, `DispatchRays`.
- `lib_6_6` target (DXR shaders are libraries — no `-E`; one more shader-table variant).
- The `Prepass` module (hybrid G-buffer) first appears.

**Watch out:**

1. SBT alignment — records 32-byte aligned, table start 64-byte aligned; use named constants.
2. Scratch + result AS buffers live until the build's fence — the fence-keyed retirement list
   from ch 6 earns its keep here.
3. UAV barrier between BLAS and TLAS builds.

---

## Appendices B–D

- **B (HLSL reference)** — your HLSL is unchanged from the book's.
- **C (Analytic geometry)** — pairs with `collision.rs`.
- **D (Selected solutions)** — doing the exercises in Rust is where the port pays off.

## Hand-rolled code inventory

| Piece | First needed | Size | Replaces |
|---|---|---|---|
| ~~error helper~~ | — | zero | `ThrowIfFailed` → `Result` + `?` (free) |
| InfoQueue1 → stderr callback + DRED enable | ch 4 | tiny | VS output window (bindings pre-exist) |
| `GameTimer`, `DescriptorUtil`, app loop + `wnd_proc`/`GWLP_USERDATA` plumbing | ch 4 | medium | book's Common |
| ImGui Win32+DX12 backend (if no live crate fits) | ch 4 | medium | `imgui_impl_win32/dx12.cpp` |
| Per-frame upload arena (`alloc_constant`, fence-retired) + `calc_cb_size` | ch 4–6 | small | DirectXTK12 `GraphicsMemory` + book's `UploadBuffer` |
| Static-buffer upload helper + fence-keyed retirement list | ch 6 | small | DirectXTK12 `CreateStaticBuffer` |
| `shared_types.rs` (grow per chapter; bytemuck Pod) | ch 6 | small | `SharedTypes.h` |
| dxc `compile_shader` + shader table + DLL-copy `build.rs` | ch 6 | small | `d3dUtil::CompileShader` + `ShaderLib` (bindings pre-exist) |
| DDS → DXGI glue over `ddsfile` | ch 9 | small | DirectXTK12 `DDSTextureLoader` |
| Texture upload helper (mips → arrays → cubes → from-memory) | ch 9 (12, 18, 21) | medium | DirectXTK12 `ResourceUploadBatch` |
| `matrix_reflect`/`matrix_shadow` | ch 11 | tiny | DirectXMath |
| `collision.rs` (AABB, frustum, ray tests) | ch 16–17 | small | DirectXCollision |
| rotation-origin affine compose | ch 22 | tiny | `XMMatrixAffineTransformation` |
| `.m3d` parser + `SkinnedData` | ch 23 | medium | book's Common |
| `.raw` heightmap reader | ch 24 | tiny | book code |
| Pipeline-state-stream struct | ch 26 | small-fiddly | `CD3DX12_PIPELINE_STATE_STREAM` |

## What Rust gives you, and what it costs — the honest closing paragraph

The wins are structural: COM lifetime management essentially vanishes (smart-pointer interfaces
make the book's ComPtr chapter a no-op, leaving only the resize trap and GPU-fence lifetimes as
real work), error handling collapses into `?`, the DXC runtime-compile flow and every D3D12
feature through DXR/mesh shaders are already bound, DDS parsing comes from a crate, and glam
uniquely ships the book's exact left-handed `[0,1]`-depth projection builders so no
view/projection code gets hand-rolled at all. The costs are equally clear: glam's column-vector
convention means every matrix concatenation in the book is written *reversed* in your code (one
mental flip, applied ~200 times), `unsafe` blocks blanket all rendering code (honest, but
visually loud), the WndProc-to-app-state plumbing is a genuinely awkward corner of Win32 Rust,
and the ImGui DX12 backend is the one dependency you may end up porting yourself. Nothing on
that list blocks more than an evening except internalizing the convention flip — and ch 3 is
designed to be exactly that exercise.
