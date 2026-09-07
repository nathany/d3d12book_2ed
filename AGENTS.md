# AGENTS.md

Working notes for coding agents in this repo. Reader-facing porting insight belongs in
`Frank Luna ODIN_PORTING_GUIDE.md` — that guide is written for a human working through the
book, so keep tooling, verification mechanics, and workflow here instead.

Documentation boundaries:

- `Frank Luna ODIN_PORTING_GUIDE.md`: concepts, C++/Odin mappings, chapter dependencies,
  deliberate adaptations, and what the learner should observe. Keep explanations useful to
  someone implementing their own version; link to the issue ledger for unresolved defects.
- `odin_port/README.md`: human-facing setup and run instructions, including dependency restore.
- `AGENTS.md`: agent scope, implementation/review policy, commands, probes, and detector setup.
- `KNOWN_ISSUES.md`: validated defects, evidence, priority, proposed remedies and acceptance
  criteria. A proposed fix is not an implemented fix; record verification dates and limits.

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
- Prefer fixes in this order: restore reference behavior; make necessary Odin adaptations;
  add focused boundary validation. Keep broader refactoring separate. Preserve the per-demo
  organization, row-vector convention, native arrays and explicit resource ownership.
- A documentation-only go-ahead does not authorize implementation changes. Keep proposed code
  work in `KNOWN_ISSUES.md` until the user approves that work.
- Finish a demo by verifying it end-to-end (below), then updating the guide, `odin_port/README.md`
  if the run steps changed, and relevant entries in `KNOWN_ISSUES.md`. These tracked documents
  are the durable project record; do not invent an unspecified external "memory" destination.

## Code Review Rules

- Review with one agent. Do not delegate to subagents unless the user explicitly asks for it.
- The requested scope determines which regressions may be reported, not which code may be inspected.
  Read surrounding code, callers, callees, shared helpers, and corresponding C++ sources as needed.
  For a diff review, report only issues introduced by the requested changes. For an explicitly
  requested fresh audit, existing defects within the requested scope may also be reported.
  Distinguish port regressions, weaknesses inherited from C++/DirectXTK12, and optional teaching
  cleanup. Require a concrete failing scenario and practical remedy; prefer no finding over a
  speculative guard, style preference, or low-value nit.

### Behavioral parity

- Treat the Odin code as a learning-oriented reference port. For every new or materially changed
  demo, compare the C++ member defaults and call-site constants, update/draw and input ordering,
  geometry and material setup, and every PSO and root-signature mutation. Missing assignments count
  as differences. The safe path is to match the book or document a necessary teaching or
  language-specific deviation beside the code.
- Preserve the book's resource lifetime model where Odin and Direct3D 12 permit it. Do not infer C++
  behavior from familiarity when the matching source is available.
- Trace changed values through their actual consumers, including shaders, before assigning
  impact. The Chapter 14 light strengths differ from C++, but both tessellation pixel shaders
  return constant white: matching those unused values is parity cleanup, not a shading fix.
- Keep attribution current when copying demos. C++ comments should name the matching source
  and explain the current code, not retain another chapter's defaults or obsolete scaffolding.

### Fallible APIs and GPU lifetime

- Trace every fallible COM, DXGI, DXC, and Win32 call through its status, output values, and cleanup.
  The safe path is to validate success and required non-nil outputs before dereferencing, releasing,
  waiting on, or otherwise consuming them.
- Distinguish a method's HRESULT from a status returned through an output parameter (DXC
  `Compile` versus `GetStatus`). Honor each API's output contract, including optional outputs.
- Windowed demos retain the existing fail-fast policy (`report_error` then nonzero exit).
  Reusable parsers return errors to their callers. Fix failure handling at the relevant boundary;
  do not introduce a general recovery framework or require normal-shutdown leak silence after
  an intentional fatal process exit.
- Trace transient GPU data from allocation through command recording, submission, fence signaling,
  completion, and reuse. A fence that permits reuse must be ordered after the submission that
  consumes the data. Also verify resource-state transitions and descriptor lifetimes.

### Untrusted input arithmetic

- Validate file-derived dimensions and counts before allocation. Perform size products, sums, and
  subresource calculations with checked, sufficiently wide arithmetic before indexing or narrowing;
  reject values outside the API's legal limits.
- Widen operands before multiplication; widening an already wrapped result does not help.
  Keep format validity, arithmetic and allocation bounds in `dds`, and D3D12 resource limits
  in the upload layer before narrowing or resource creation. Cover malformed inputs with focused
  parser tests; valid bundled assets alone cannot establish rejection behavior.

### Validation and reporting

- Confirm material Odin behavior from the installed compiler source. Use the Justfile for
  deterministic checks, but treat passing checks, sanitizer builds, and tracking-allocator runs as
  evidence only for the configurations and paths that ran. Report check failures separately and do
  not duplicate compiler diagnostics as semantic findings.
- Accept documented deliberate deviations when their stated guarantees hold. Documentation does
  not exempt an incorrect premise from review (for example, the allocator's former claim that a
  signal before submission protects that submission). Do not report known-benign diagnostics as defects.
  Known review traps include:

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
just test-upload           # DDS/skull loading-boundary tests; no graphics device required
just test-gpu              # opt-in GPU upload-retirement regression; requires D3D12 + debug layer
just check C7_Waves        # release and debug type checks
just build-asan C7_Waves   # sanitizer build in the session temp directory
```

Run `just --list` for the complete set of recipes. The root Justfile uses Bash and keeps shader,
model, texture, and DLL lookup relative to the repository root.

### Tool discovery in an agent shell

Check `type -a just`, `just --version`, and `odin version` in Git Bash before declaring a tool
missing. On 2026-09-06, `just 1.58.0` installed by WinGet resolved from
`$LOCALAPPDATA/Microsoft/WinGet/Packages/Casey.Just_Microsoft.Winget.Source_8wekyb3d8bbwe`.
Its directory was already in the agent's inherited PATH, but the sandbox could not execute it
and Bash misleadingly reported it missing (an absolute-path attempt reported "Is a directory").
The same Git Bash command outside the sandbox resolved it and passed `just validate`.

Treat that symptom as a possible access restriction, not proof of a missing installation or
stale PATH. Use the environment's approval mechanism when required; do not reinstall the tool
or rewrite PATH to bypass access restrictions. If validation must fall back to direct Odin
commands, identify that fallback accurately in the report.

`core:testing` here has **no `log`/`logf`/`errorf`** — use `testing.expectf(t, false, ...)`
to fail with a message, and `core:log`'s `log.info`/`log.warnf` for test output.

**`odin_port/dds` must stay graphics-API-free** so file-format validation can be tested without
a graphics device. Keep `vendor:directx/*` imports in the upload layer.
The one exception is `format_dxgi_test.odin`, gated with `#+build windows`.
Standard-library helpers, including `base:intrinsics` for checked arithmetic, are
allowed; preserve the package's lack of a graphics device, platform API and fatal-I/O policy.
Validation targets this Windows DX12 project; cross-platform DDS builds are not required.
`just validate` includes `test-upload`. DDS arithmetic regressions use `mem.panic_allocator`
to prove rejection before allocation; run DDS and upload tests with `-debug -sanitize:address`
when changing their memory/indexing paths. `dds.layout_size` validates metadata and bounds;
`subresource_count` only widens the product and must not substitute for that validation.

`dxcompiler.dll` and `dxil.dll` are copied to the repo root (gitignored) to pin vendor DXC
1.6.2112 ahead of the Vulkan SDK's copy on PATH — never invoke a bare `dxc`. Copy steps are in
`odin_port/README.md`.

**Known-benign stderr:** one `id 1328` warning per `create_static_buffer` call
(`CreateCommittedResource: Ignoring InitialState D3D12_RESOURCE_STATE_COPY_DEST`) — 2–5 per
run in chapters 6–9, up to seven in the tested later demos. The baseline counts are in
`KNOWN_ISSUES.md`. DDS texture uploads add none
(textures really are created in COPY_DEST). DirectXTK12 does the same thing and the C++ demos
emit them too, invisibly — ours are only visible because InfoQueue1 pipes to stderr. Don't
"fix" them.

## Verifying a demo

Every windowed demo gets the same five checks before it counts as done: the render and controls
match C++, a resize storm survives, Escape exits 0, the debug layer has no unexpected messages,
and both leak reports (COM and Odin) contain no unexpected live allocations. Apply the documented
`id 1328` exception above. Record that each detector was available and ran: an unavailable or
unregistered detector is a validation gap, not a clean result.

The verification notes below came from PowerShell plus P/Invoke;
keep new repeatable commands in the root Justfile and prefer Git Bash-compatible helpers.

- **Chapter 4+ Escape arrives on `WM_KEYUP`** (0x0101), not `WM_KEYDOWN` — that's where
  the book's `MsgProc` handles `VK_ESCAPE`. **Appendix A uses `WM_KEYDOWN`** (0x0100).
  Choose the event from the actual window procedure; the wrong event is silently ignored.
- **`odin run` spawns the demo as a child process**, so `$p.MainWindowHandle` on the odin
  process is 0. Find the window by process name (the exe is named after the package directory).
- **Make the probe thread per-monitor DPI aware** (`SetThreadDpiAwarenessContext(-4)`). At 150%
  scale an unaware process gets DPI-virtualized `GetWindowRect` coordinates, so `CopyFromScreen`
  crops the window — a centered box looks off-center and you go hunting a rendering bug that was
  never there. `PrintWindow` with `PW_RENDERFULLCONTENT` additionally captures overlapped windows.
- For an unobscured visual comparison, use direct screen capture without first calling
  `PrintWindow` and discarding its result. Investigate an incomplete snapshot with repeated
  direct captures of both baseline and changed executables before assigning a render regression.
- **ImGui clicks need a real cursor** (`SetCursorPos` + `mouse_event`, saving and restoring the
  user's position), because the win32 backend re-reads `GetCursorPos` every focused frame and
  overwrites posted mouse positions. Call `SetForegroundWindow` first, or the click lands in
  whatever window has focus.
- Verify the target HWND/process at the click location before sending input. Foreground requests
  can fail; another visible window invalidates a screen capture and can receive the click.
  Keep GUI runs sequential and restore `imgui.ini` and `results.txt` after probes. Compare
  scene regions, excluding FPS text, overlays, borders and the cursor, when checking animation.
- **`CW_USEDEFAULT` cascades window positions** per boot session, so never hardcode the origin:
  read `GetWindowRect`, then map `physical = origin + 1.5 × window-relative-virtual` at 150%.
- **PowerShell 5.1 needs `$null = $p.Handle`** cached before the process exits, or `$p.ExitCode`
  comes back empty.
- **Animation needs two captures** a second or so apart, compared — a single frame proves
  nothing about a simulation.
- **Prove a new detector fires before trusting its silence.** The tracking allocator was
  confirmed by planting a 123-byte leak and seeing it reported with the right source location,
  then removing it. A silent report from an unproven detector means nothing.

### Diagnostic plumbing and controlled probes

- `PFN_MESSAGE_CALLBACK` is `proc "c"` in the installed D3D12 bindings; WndProc is
  `proc "system"`. The D3D12 callback uses the driver thread's default context, while main-thread
  Win32/ImGui callbacks restore `app_context` captured after tracker installation.
- `DXGIGetDebugInterface1` is exported by `dxgi.dll`; resolve it with `GetModuleHandleW` and
  `GetProcAddress`. The older entry point without `1` lives in `dxgidebug.dll`.
  `report_live_objects` invokes `ReportLiveObjects`, then retrieves DXGI messages with the
  two-call size/fill pattern. Record unavailable interfaces or failed message retrieval as gaps.
- To test the message pipe, temporarily call `AddApplicationMessage`. This proves callback
  delivery, not resource-state validation. Do not leave a noisy startup self-test in the demo.
- A previous validator probe omitted the Chapter 4 `PRESENT -> RENDER_TARGET` barrier and
  observed ids 538 and 527. A previous COM probe deliberately leaked a fence and observed its
  live-object report. Such probes must be isolated, restored, and rechecked before completion;
  never infer correctness from the fact that the faulty demo still draws.
- `SetBreakOnSeverity` requires a CPU debugger; guard it with `IsDebuggerPresent`. A frame
  capture alone is not evidence that a CPU debugger is attached. GPU-based validation is off
  by default in the current code; report explicitly when a run enables it.
- DRED collection is enabled before device creation in debug builds. The port does not yet
  retrieve and print DRED data on device removal. Enabling collection is not a completed
  device-removal reporting path.
- Allocator lifetime fixes require deliberate GPU backlog and stable constant data until the
  consuming submission completes. A CPU allocator report or ordinary successful render cannot
  prove that fence ordering is correct.
- `just test-gpu` enables `GRAPHICS_MEMORY_GPU_TESTS` in `common/graphics_memory_test.odin`.
  It reads the 15 frame draw procedures' actual submit/commit order and replays each order with
  a GPU copy held behind a CPU-released queue fence. A pre-gate marker removes timing guesses;
  the test checks address reuse, readback bytes, and eventual reuse after completion. It also
  fails on unexpected debug warnings/errors and uses Odin's test allocation tracker.
  The source check intentionally recognizes the current straight-line procedure shape, not
  arbitrary Odin syntax. Update the manifest/model when adding or restructuring a consuming
  demo. It does not execute complete draw procedures or replace their visual/control checks.
  The GPU suite is separate from `just validate`; missing device/debug-layer support is a
  failure, not a skip. Fence waits have a five-second limit; a stalled queue terminates the
  test process rather than releasing resources still in use or hanging indefinitely.
- If Agility exports are added, verify them with `dumpbin /exports` and verify the loaded
  runtime location. The current port omits those exports based on its tested Windows setup.
- For ImGui dependency regeneration, see `odin_port/README.md` for the verified restore
  using upstream's corrected pattern patch for the former premake line-number problem.
  Its build defaults now target a newer binding set, so use the documented version overrides
  when restoring the existing library. Keep dependency-build details there, not in the guide.

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

- Last verified compiler (2026-09-06, local date): **dev-2026-09-nightly:a2fb372**. Run `odin version`
  for the current session; Odin releases monthly, so stdlib details drift. Check the matching
  installed library source and establish the revision of any separate source checkout used.
- A full Odin source checkout lives at `C:\Users\nathany\src\github.com\odin-lang\Odin` —
  **check it rather than guessing** at stdlib behavior. That's how the temp allocator's
  `.Free_All` support and the tracking allocator's bad-free panic were confirmed.
- `core:os` is the former `core:os2` — procs return an `Error` (test `!= nil`), not a bool. The
  old bool API is `core:os/old`.
- `defer` runs at end of **scope**, not end of function.
- Unused package-level procs are fine; unused *locals* and unreachable code are compile errors.
