# rust_port

Rust reference implementation of the demos from Luna's *Introduction to 3D Game Programming
with DirectX 12* (2nd ed.). Chapter-by-chapter porting notes live in
[`../Frank Luna RUST_PORTING_GUIDE.md`](../Frank%20Luna%20RUST_PORTING_GUIDE.md) — read its
"Repository layout & port conventions" section first.

## Layout

- `common/` — the book's `Common/` layer as a library crate.
- `demos/c<chapter>_<name>/` — one binary crate per book demo.
- Assets (`Models/`, `Textures/`, `Shaders/`) are the book's own, referenced in place at the
  repo root via `common::asset_path` — nothing is copied.

## Running

```
cargo test -p c1_xmvector    # chapters 1–3 are math-only, ported as tests that assert
                             # values captured from the C++ demos' output — everything in
                             # one src/lib.rs, read top-to-bottom next to the book chapter
                             # (one #[test] per C++ variant; helpers in common::testing)
cargo run -p c4_init_d3d     # D3D demos (chapter 4 on) are binaries
```

`cargo run` works from anywhere: asset paths are resolved by walking up from the executable's
location to the repo root, not from the working directory.

## One-time setup (needed from chapter 4 on)

The D3D demos compile shaders at runtime with DXC and can optionally use the Agility SDK.
Those binaries are **not** committed (they're large); restore them with:

```
./setup.ps1
```

which runs `nuget install` (latest, `-ExcludeVersion` for stable paths) into `tools/`
(gitignored). Each demo's `build.rs` copies the needed DLLs next to the built exe — the exe
directory wins Windows' DLL search order, so a stray `dxcompiler.dll` on `PATH` (e.g. the
Vulkan SDK's) can never be picked up. Builds fail with a pointer to this README if `tools/`
is missing; they never download anything themselves.

The chapter 1–3 math demos need none of this — pure glam, runs anywhere.
