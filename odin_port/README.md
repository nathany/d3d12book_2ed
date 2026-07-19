# odin_port

Odin reference implementation of the demos from Luna's *Introduction to 3D Game Programming
with DirectX 12* (2nd ed.). Chapter-by-chapter porting notes live in
[`../Frank Luna ODIN_PORTING_GUIDE.md`](../Frank%20Luna%20ODIN_PORTING_GUIDE.md).

## Layout

Directories mirror the book's `Demos/` folders (one Odin package per demo); files within a
package mirror the demo's `.cpp` files. Shared code lives in its own packages
(`d3d_math`, `test_util`, later a `common` equivalent).

## Running

```
odin test odin_port/C1_XMVECTOR       # chapters 1–3 are math-only, ported as tests that
odin test odin_port/C2_XMMATRIX       # assert values captured from the C++ demos' output
odin test odin_port/C3_TRANSFORMATIONS

odin run odin_port/APPENDIX_A
odin run odin_port/C4_Init_Direct3D -debug    # -debug turns on the D3D12 debug layer,
odin run odin_port/C6_Box -debug              # stderr validation log, and leak report
odin run odin_port/C6_BoxGrid -debug
odin run odin_port/C7_Shapes -debug
```

**Run the windowed demos from the repo root** — shaders load by relative path
(`Shaders/BasicColor.hlsl`), matching the C++ demos' convention.

### DXC runtime DLLs (one-time, ch 6+)

Demos with shaders compile HLSL at startup through `vendor:directx/dxc`, which links
against `dxcompiler.dll` (plus `dxil.dll` for signing). Copy both from the Odin vendor
folder into the repo root (= the exe's directory, which wins the DLL search — deliberately
pinning this version over any `dxcompiler.dll` on PATH, e.g. the Vulkan SDK's):

```
copy %USERPROFILE%\tools\odin\vendor\directx\dxc\dxcompiler.dll .
copy %USERPROFILE%\tools\odin\vendor\directx\dxc\dxil.dll .
```

Both are gitignored. The vendored version is 1.6.2112 — old but SM 6.6-capable, verified
against the ch 6 shaders. (Fallback if it ever misbehaves: the newer
`External\dxc\bin\x64` DLLs, restored by the C++ demos' NuGet step.) Debug builds also
write shader PDBs to `HLSL PDB/` (gitignored via `*.pdb`) for PIX.

## ImGui (vendored in `libs/imgui`)

The overlay UI (ch 4 on) uses [Capati/odin-imgui](https://github.com/Capati/odin-imgui)
(Dear ImGui 1.92.8-docking) with the **win32 + dx12** backends — the same pair the book's
C++ uses. The bindings are vendored here as plain copies for now (we may revisit
submodules later); the static library is **gitignored** (large binary), so after a fresh
clone it must be rebuilt and copied in:

1. **Prerequisites:** Git, Python 3.3+ (used by dear_bindings), premake5
   (<https://premake.github.io> — put the exe on PATH or note where it lives), and the
   VS 2022 Build Tools (MSVC + Windows SDK).
2. Clone `Capati/odin-imgui` somewhere *outside* this repo.
3. In that checkout, generate and build (backends are baked into the lib at this step —
   `win32,dx12`, nothing else):

   ```
   premake5 --backends=win32,dx12 vs2022
   msbuild build\make\windows\ImGui.vcxproj -p:Configuration=Release -p:Platform=x64
   ```

   This produces `imgui_windows_x64.lib` in the checkout root.

   *Known issue (2026-07):* with Dear ImGui 1.92.8, the premake script's win32-backend
   patch targets stale hardcoded line numbers (705–706; the declarations moved to
   729–730), causing `error C2159` in `imgui_impl_win32.cpp`. Our checkout's
   `premake5.lua` was fixed to patch by pattern instead — worth PRing upstream.

4. Copy into `odin_port/libs/imgui`, **preserving the layout** (the backend packages
   import the root package by relative path, and the `.lib` is foreign-imported from the
   package root): `imgui.odin`, `impl_enabled.odin` (verify win32/dx12 are `true` in it),
   `LICENSE`, `imgui_windows_x64.lib`, `backends/win32/`, `backends/dx12/`.
5. Convert the generated `impl_enabled.odin` to **LF** — premake writes CRLF and this
   repo intentionally uses LF line endings.

`imgui.ini` (window layout state Dear ImGui writes to the working directory at runtime)
is gitignored.

## The convention decision (differs from `rust_port/`!)

This port keeps **the book's row-vector convention**, via
`Mat4 :: #row_major matrix[4, 4]f32` in `d3d_math` — byte-identical to `XMFLOAT4X4`. As a
result, matrix literals are typed exactly as the book prints them, concatenation reads
left-to-right exactly as the book writes it (`S * R * T`), points transform as `v * M`, and
the transpose-before-CB-upload line survives unchanged. Contrast with `rust_port/`, where
glam's column-vector convention reverses every matrix product. The view/projection/rotation
*builders* are hand-rolled in `d3d_math` from the book's printed forms — `core:math/linalg`'s
builders are GL-flavored column-vector and must not be mixed in (its convention-agnostic
operations — `dot`, `cross`, `normalize`, `inverse`, `transpose`, element-wise math — are
used freely).
