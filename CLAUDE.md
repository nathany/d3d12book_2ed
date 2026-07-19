# CLAUDE.md

Working notes for Claude Code in this repo. Reader-facing porting insight belongs in
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

## Build and run

Windowed demos run **from the repo root** — shaders resolve by relative path
(`Shaders/BasicColor.hlsl`) and the pinned DXC DLLs live there, matching the C++ demos'
convention.

```
odin run odin_port/C7_Waves -debug    # -debug gates ODIN_DEBUG: D3D12 debug layer,
                                      # InfoQueue1 -> stderr, COM leak report, and the
                                      # Odin tracking allocator
odin test odin_port/C2_XMMATRIX       # ch 1-3 are math-only, ported as tests
odin build odin_port/C7_Waves -debug -out:<scratchpad>/check.exe   # compile check only
```

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
reports (COM and Odin) are silent. Automation is PowerShell plus P/Invoke — each trap below
cost real time to find.

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

- **LF line endings everywhere, intentionally, even on Windows.** Convert vendored or generated
  files that arrive as CRLF. Check with `file` (it names CRLF explicitly) — *not* with
  `grep -c $'\r'`, because MSYS tools translate on read and report CRLF for pure-LF files.
- **No binaries in git:** DLLs, EXEs, LIBs, and `*.pdb` are gitignored, restored via documented
  copy/build steps in `odin_port/README.md`. Shader PDBs land in `HLSL PDB/`.
- Fatal errors report through **both** channels: stderr for consoles and CI, plus a
  `MessageBoxW` for someone running the windowed demo. Centralized in `report_error`.
- Temp files go in the session scratchpad, never the repo.

## Odin toolchain notes

- Installed compiler is **dev-2026-07a** (a hotfix release, though `odin version` says nightly).
  Odin releases monthly, so stdlib details drift.
- A full Odin source checkout lives at `C:\Users\nathany\src\github.com\odin-lang\Odin` —
  **check it rather than guessing** at stdlib behavior. That's how the temp allocator's
  `.Free_All` support and the tracking allocator's bad-free panic were confirmed.
- `core:os` is the former `core:os2` — procs return an `Error` (test `!= nil`), not a bool. The
  old bool API is `core:os/old`.
- `defer` runs at end of **scope**, not end of function.
- Unused package-level procs are fine; unused *locals* and unreachable code are compile errors.
