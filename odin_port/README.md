# odin_port

Odin reference implementation of the demos from Luna's *Introduction to 3D Game Programming
with DirectX 12* (2nd ed.). Chapter-by-chapter porting notes live in
[`../Frank Luna ODIN_PORTING_GUIDE.md`](../Frank%20Luna%20ODIN_PORTING_GUIDE.md).

## Layout

Directories mirror the book's `Demos/` folders (one Odin package per demo); files within a
package mirror the demo's `.cpp` files. Shared code lives in its own packages: `common`
(the book's `Common/` — app framework, timer, descriptor/upload helpers), `d3d_math`,
[`dds`](dds/README.md) (a standalone DDS parser tested without a graphics device;
see its README for the supported-format matrix and how it's validated
against DirectXTK12), `test_util`, and the vendored `libs/imgui`.

## Running

Verified on 2026-09-06 with **Odin `dev-2026-09-nightly:a2fb372`** and **just 1.58.0**
on Windows x64. Check `odin version` and `just --version` when changing toolchains.

Use the repository's root Justfile from Git Bash so windowed demos find their shaders and runtime
DLLs without additional path handling:

```bash
just --list                       # show the available workflows
just examples                     # list every runnable demo
just test C1_XMVECTOR             # chapters 1–3 are math-only tests
just test dds                     # synthetic and repository DDS parser tests
just test-upload                  # DDS/skull loading-boundary tests, no graphics device required
just run APPENDIX_A
just run C7_Waves                 # debug layer, stderr validation, COM leak report,
                                  # and Odin tracking allocator (common/mem_track.odin)
just check C7_Waves               # release and debug type checks
just build-asan C13_VecAddCS      # sanitizer build goes to the session temp directory
just validate                     # all Windows type checks, math/DDS and loading-boundary tests
just test-gpu                     # additional opt-in D3D12 upload-lifetime regression
```

**Run the windowed demos from the repo root** — shaders load by relative path
(`Shaders/BasicColor.hlsl`), matching the C++ demos' convention. `just run` enables `-debug`;
use `just run-release <example>` when the instrumentation is not wanted.

`just test-gpu` additionally requires a D3D12-capable Windows device and the Windows
Graphics Tools debug layer. It runs without a window or shader compilation, exercises the
allocator with deliberately delayed GPU work, and checks the data read back by the GPU.
It is separate from `just validate` so ordinary math/parser validation does not require a GPU.

### DXC runtime DLLs (one-time, ch 6+)

Demos with shaders compile HLSL at startup through `vendor:directx/dxc`, which links
against `dxcompiler.dll` (plus `dxil.dll` for signing). Copy both from the Odin vendor
folder into the repo root (= the exe's directory, which wins the DLL search — deliberately
pinning this version over any `dxcompiler.dll` on PATH, e.g. the Vulkan SDK's):

```bash
repo_root="$(git rev-parse --show-toplevel)"
cp "$HOME/tools/odin/vendor/directx/dxc/dxcompiler.dll" "$repo_root/"
cp "$HOME/tools/odin/vendor/directx/dxc/dxil.dll" "$repo_root/"
```

Both are gitignored. The vendored version is 1.6.2112 — old but SM 6.6-capable, verified
against the ch 6 shaders. (Fallback if it ever misbehaves: the newer
`External\dxc\bin\x64` DLLs, restored by the C++ demos' NuGet step.) Debug builds also
write shader PDBs to `HLSL PDB/` (gitignored via `*.pdb`) for PIX.

## ImGui (vendored in `libs/imgui`)

The overlay UI (ch 4 on) uses [Capati/odin-imgui](https://github.com/Capati/odin-imgui)
with **Dear ImGui 1.92.8-docking** and the **win32 + dx12** backends. The Odin bindings
are already tracked; only `imgui_windows_x64.lib` is gitignored and needs restoring.
Keep the bindings and native library on matching versions: replacing one independently
can change the C ABI even when Odin still compiles.

### Restore the library for the current bindings

Prerequisites: Git, Python available as **`python3`** with `venv` and `pip`,
[Premake 5](https://premake.github.io), and Visual Studio 2022 or its Build Tools with
MSVC and a Windows SDK. The clean restore below was tested with Python **3.14.6**,
Premake **5.0.0-beta8**, and MSBuild **17.14.51**. These are tested versions, not claimed
minimum requirements. Make `premake5` and `msbuild` available in your build shell;
an absolute path to either executable works too.

1. From this repository in Git Bash, save its path, then clone into a **new directory
   outside the repository**. Replace the example destination with your preferred location:

   ```bash
   repo_root="$(git rev-parse --show-toplevel)"
   git clone https://github.com/Capati/odin-imgui.git ../odin-imgui-restore
   cd ../odin-imgui-restore
   git checkout 6987747b1c78f984ac529e2d0cc1f59fd60c50ac
   ```

2. Use that revision's corrected build script, explicitly requesting the versions matching
   **this project's existing bindings**:

   ```bash
   python3 --version
   premake5 --backends=win32,dx12 --imgui-version=v1.92.8-docking --dear-bindings-version=DearBindings_v0.21_ImGui_v1.92.8-docking vs2022
   msbuild build/make/windows/ImGui.vcxproj -p:Configuration=Release -p:Platform=x64
   ```

   This produces `imgui_windows_x64.lib` in the checkout root. Use a fresh dependency
   directory: Premake skips already-cloned dependencies, so changing version arguments
   does **not** switch an existing `build/deps` checkout to those versions.

3. Restore **only the library**, retaining the tracked Odin bindings and backend layout:

   ```bash
   cp imgui_windows_x64.lib "$repo_root/odin_port/libs/imgui/"
   cd "$repo_root"
   just run C4_Init_Direct3D
   ```

   Confirm that the Options panel renders and responds, resizing works, and Escape exits.
   The existing `impl_enabled.odin` enables only Win32 and DX12; both are compiled into
   the library by the command above.

### What changed upstream

As checked on 2026-09-06, the pinned
[upstream build script](https://github.com/Capati/odin-imgui/blob/6987747b1c78f984ac529e2d0cc1f59fd60c50ac/premake5.lua)
patches Win32 declarations by pattern. It patched two declarations and built successfully
in a clean restore, eliminating the old manual line-number workaround for MSVC C2159.
The build emitted a `/MD` to `/MT` override warning; a temporary-directory build also
emitted MSB8029. Neither prevented the build or the runtime smoke tests.

That checkout defaults to **1.92.9b-docking**, and its latest generator change corrects
some `char` mappings to `u8`. The restore above deliberately overrides the native-library
versions. **Do not copy its newer `imgui.odin` or backends into this project as part of a
restore.** A bindings upgrade remains separate work: update bindings, backend declarations,
enabled flags and library together, preserve the license/layout and LF endings, then verify
the overlays and controls again. The newer binding set has not been validated in this port.

`imgui.ini` (window layout state Dear ImGui writes to the working directory at runtime)
is gitignored.

## Matrix conventions

The port keeps the book's row-vector convention and row-major storage. See the
[porting guide's matrix explanation](../Frank%20Luna%20ODIN_PORTING_GUIDE.md) before
mixing in library matrix builders or changing upload transposes.
