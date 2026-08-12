# AGENTS.md

Working notes for coding agents in this repo. Reader-facing porting insight belongs in
`Frank Luna ODIN_PORTING_GUIDE.md` — that guide is written for a human working through the
book, so keep tooling, verification mechanics, and workflow here instead.

## What this repo is

Frank Luna's *Introduction to 3D Game Programming with DirectX 12* (2nd ed.) C++ demos, plus
hand-written ports that the user reads while learning DX12.

| Branch           | Port                   | Guide                              |
| ---------------- | ---------------------- | ---------------------------------- |
| `odin` (current) | `odin_port/`           | `Frank Luna ODIN_PORTING_GUIDE.md` |
| `rust`           | `rust_port/`           | `Frank Luna RUST_PORTING_GUIDE.md` |
| `main`           | upstream C++ only      | —                                  |

The ports are **reference implementations**: the user implements each demo themselves as an
exercise, then reads ours to check their work. That's why the code quotes the C++ original so
heavily — it's teaching material, not just working code.

Conventions differ per port *deliberately* (the Odin port keeps the book's row-vector matrix
convention; the Rust port reverses products for glam). Never carry a decision from one branch
to the other, and don't edit the other port's guide unasked.

## Working rhythm

- One chapter, or one demo, per go-ahead. Don't start the next chapter unprompted.
- Behavior parity with the C++ first. Quote the C++ original in a comment above anything
  non-obvious: `// C++: mCurrFrameResource->Fence = ++mCurrentFence;`
- Code derived from **DirectXTK12** (as opposed to the book's own `Common/`) needs a
  provenance header naming the source and its MIT license. Book-derived code doesn't.
- Deliberate deviations from the C++ get a header comment saying so and why — e.g.
  `C7_Waves/waves.odin` is serial where the book uses PPL `parallel_for`.
- Finish a demo by verifying it end-to-end (below), then updating the guide, `odin_port/README.md`
  if the run steps changed, and memory.

## Code Review Rules

- Review with one agent. Do not delegate to subagents unless the user explicitly asks for it.
- The requested scope determines which regressions may be reported, not which code may be inspected.
  Read surrounding code, callers, callees, shared helpers, and corresponding C++ sources as needed.
  Report only issues introduced by the requested changes, with a concrete failing scenario and a
  practical remedy. Prefer no finding over a speculative guard, style preference, or low-value nit.

### Behavioral parity

- Treat the Odin code as a learning-oriented reference port. For every new or materially changed
  demo, compare the C++ member defaults and call-site constants, update/draw and input ordering,
  geometry and material setup, and every PSO and root-signature mutation. Missing assignments count
  as differences. The safe path is to match the book or document a necessary teaching or
  language-specific deviation beside the code.
- Preserve the book's resource lifetime model where Odin and Direct3D 12 permit it. Do not infer C++
  behavior from familiarity when the matching source is available.

### Fallible APIs and GPU lifetime

- Trace every fallible COM, DXGI, DXC, and Win32 call through its status, output values, and cleanup.
  The safe path is to validate success and required non-nil outputs before dereferencing, releasing,
  waiting on, or otherwise consuming them.
- Trace transient GPU data from allocation through command recording, submission, fence signaling,
  completion, and reuse. A fence that permits reuse must be ordered after the submission that
  consumes the data. Also verify resource-state transitions and descriptor lifetimes.

### Untrusted input arithmetic

- Validate file-derived dimensions and counts before allocation. Perform size products, sums, and
  subresource calculations with checked, sufficiently wide arithmetic before indexing or narrowing;
  reject values outside the API's legal limits.

### Validation and reporting

- Confirm material Odin behavior from the installed compiler source. Use the Justfile for
  deterministic checks, but treat passing checks, sanitizer builds, and tracking-allocator runs as
  evidence only for the configurations and paths that ran. Report check failures separately and do
  not duplicate compiler diagnostics as semantic findings.
- Do not report documented deliberate deviations or known-benign diagnostics as defects. Known
  review traps include:

    - Chapter 1 intentionally models its teaching vectors with three lanes and ignores `w`.
    - Assignment through a zero-value Odin map lazily initializes its backing store with the current
      context allocator; confirm the installed runtime before claiming the map must be made first.
    - The book also leaves the waves render item's `vertex_count` unset, and the port does not consume
      that field. Treat it as a finding only if a changed path starts relying on it.
    - The known D3D12 `id 1328` warning described below matches the reference behavior.
- Keep findings concise and prioritized. Attach feedback to the shortest useful changed-line range;
  if there are no actionable findings, say so directly.

## Build and run

Windowed demos run **from the repo root** — shaders resolve by relative path
(`Shaders/BasicColor.hlsl`) and the pinned DXC DLLs live there, matching the C++ demos'
convention.

```bash
just run C7_Waves          # -debug gates ODIN_DEBUG: D3D12 debug layer,
                           # InfoQueue1 -> stderr, COM leak report, and the
                           # Odin tracking allocator
just test C2_XMMATRIX      # ch 1-3 are math-only, ported as tests
just test dds              # DDS parser tests (integration half needs repo root)
just check C7_Waves        # release and debug type checks
just build-asan C7_Waves   # sanitizer build in the session temp directory
```

Run `just --list` for the complete set of recipes. The root Justfile uses Bash and keeps shader,
model, texture, and DLL lookup relative to the repository root.

`core:testing` here has **no `log`/`logf`/`errorf`** — use `testing.expectf(t, false, ...)`
to fail with a message, and `core:log`'s `log.info`/`log.warnf` for test output.

**`odin_port/dds` must stay graphics-API-free** — it imports only `core:mem` so it builds
for Linux/macOS/FreeBSD (`odin build odin_port/dds -target:linux_amd64 -build-mode:obj`).
Never import `vendor:directx/*` there: dxgi link-depends on `system:dxgi.lib` and friends.
The one exception is `format_dxgi_test.odin`, gated with `#+build windows`.

`dxcompiler.dll` and `dxil.dll` are copied to the repo root (gitignored) to pin vendor DXC
1.6.2112 ahead of the Vulkan SDK's copy on PATH — never invoke a bare `dxc`. Copy steps are in
`odin_port/README.md`.

**Known-benign stderr:** one `id 1328` warning per `create_static_buffer` call
(`CreateCommittedResource: Ignoring InitialState D3D12_RESOURCE_STATE_COPY_DEST`) — 2–5 per
run depending on the demo's static-buffer count (ch 6–9 range). DDS texture uploads add none
(textures really are created in COPY_DEST). DirectXTK12 does the same thing and the C++ demos
emit them too, invisibly — ours are only visible because InfoQueue1 pipes to stderr. Don't
"fix" them.

## Verifying a demo

Every windowed demo gets the same five checks before it counts as done: the render matches the
C++ framing, a resize storm survives, Escape exits 0, the debug layer is silent, and both leak
reports (COM and Odin) are silent. The verification notes below came from PowerShell plus P/Invoke;
keep new repeatable commands in the root Justfile and prefer Git Bash-compatible helpers.

- **Escape arrives on `WM_KEYUP`** (0x0101), not `WM_KEYDOWN` — that's where the book's
  `MsgProc` handles `VK_ESCAPE`. A posted KEYDOWN is silently ignored and the demo never exits.
- **`odin run` spawns the demo as a child process**, so `$p.MainWindowHandle` on the odin
  process is 0. Find the window by process name (the exe is named after the package directory).
- **Make the probe thread per-monitor DPI aware** (`SetThreadDpiAwarenessContext(-4)`). At 150%
  scale an unaware process gets DPI-virtualized `GetWindowRect` coordinates, so `CopyFromScreen`
  crops the window — a centered box looks off-center and you go hunting a rendering bug that was
  never there. `PrintWindow` with `PW_RENDERFULLCONTENT` additionally captures overlapped windows.
- **ImGui clicks need a real cursor** (`SetCursorPos` + `mouse_event`, saving and restoring the
  user's position), because the win32 backend re-reads `GetCursorPos` every focused frame and
  overwrites posted mouse positions. Call `SetForegroundWindow` first, or the click lands in
  whatever window has focus.
- **`CW_USEDEFAULT` cascades window positions** per boot session, so never hardcode the origin:
  read `GetWindowRect`, then map `physical = origin + 1.5 × window-relative-virtual` at 150%.
- **PowerShell 5.1 needs `$null = $p.Handle`** cached before the process exits, or `$p.ExitCode`
  comes back empty.
- **Animation needs two captures** a second or so apart, compared — a single frame proves
  nothing about a simulation.
- **Prove a new detector fires before trusting its silence.** The tracking allocator was
  confirmed by planting a 123-byte leak and seeing it reported with the right source location,
  then removing it. A silent report from an unproven detector means nothing.

## Repo conventions

- Prefer Git Bash for terminal commands. Do not add PowerShell scripts unless the user asks for
  them; expose repeatable Odin build, test, and validation workflows as recipes in the root
  Justfile.
- **LF line endings everywhere, intentionally, even on Windows.** Convert vendored or generated
  files that arrive as CRLF. Check with `file` (it names CRLF explicitly) — *not* with
  `grep -c $'\r'`, because MSYS tools translate on read and report CRLF for pure-LF files.
- **No binaries in git:** DLLs, EXEs, LIBs, and `*.pdb` are gitignored, restored via documented
  copy/build steps in `odin_port/README.md`. Shader PDBs land in `HLSL PDB/`.
- Fatal errors report through **both** channels: stderr for consoles and CI, plus a
  `MessageBoxW` for someone running the windowed demo. Centralized in `report_error`.
- Temp files go in the session scratchpad, never the repo.

## Odin toolchain notes

- Installed compiler is **dev-2026-08-nightly:902106f**. Odin releases monthly, so stdlib details
  drift.
- A full Odin source checkout lives at `C:\Users\nathany\src\github.com\odin-lang\Odin` —
  **check it rather than guessing** at stdlib behavior. That's how the temp allocator's
  `.Free_All` support and the tracking allocator's bad-free panic were confirmed.
- `core:os` is the former `core:os2` — procs return an `Error` (test `!= nil`), not a bool. The
  old bool API is `core:os/old`.
- `defer` runs at end of **scope**, not end of function.
- Unused package-level procs are fine; unused *locals* and unreachable code are compile errors.
