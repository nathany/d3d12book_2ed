---
name: review-changes
description: Review local branches, commits, pull-request diffs, or uncommitted changes in the d3d12book_2ed repository. Use for correctness-focused review of the Odin reference port against the book's C++ implementation, including Direct3D 12 lifetimes, error paths, parser arithmetic, validation results, and learning-oriented behavioral parity.
---

# Review Changes

Perform a read-only, single-agent code review. Do not edit the implementation or delegate work to
subagents.

## Establish scope

1. Read the applicable `AGENTS.md` instructions.
2. Use the base branch, commit, or working-tree scope named by the user. If the user asks for a
   branch review without naming a base, use its merge base with `main`.
3. Inspect the complete diff and changed-file list before assessing individual lines.
4. Separate pre-existing problems from regressions introduced by the requested diff.

## Run deterministic validation

1. Inspect the root Justfile and run the narrowest relevant recipes from the repository root.
2. Use `just check <example>` for changed runnable examples and `just check-test <package>` for
   changed test-only packages. Use `just test <package>` when tests exist.
3. Use `just validate` when the review covers the full Odin port and the cost is appropriate.
4. Build or run the affected package with ASan only when memory safety is relevant. Treat a passing
   sanitizer or tracking-allocator run as evidence for executed paths, not proof for all paths.
5. Report unavailable prerequisites and validation failures separately. Do not repeat a compiler
   diagnostic as an inline semantic finding.

## Review the implementation

For each changed Odin demo, find and read the corresponding C++ implementation. Compare constants,
defaults, frame/update/draw ordering, input messages, geometry and material setup, root signatures,
PSOs, and resource ownership. Accept divergence only when it is necessary for Odin or DirectX 12,
or explicitly documented with a sound teaching reason.

Check especially for:

- command-list submission, fences, resource retirement, and upload lifetimes;
- resource states, descriptor use, and D3D12/DXGI/DXC failure handling;
- nil values and failed calls used before validation;
- file-derived dimensions and counts, overflow, narrowing, and malformed-input behavior;
- comments or guide text that misstate the reference implementation;
- changes that hide an important concept from a learner even if the demo still renders.

Confirm material Odin semantics in the installed Odin source instead of assuming C/C++ behavior.
Honor documented deliberate deviations and known-benign diagnostics in `AGENTS.md`.

## Validate each candidate finding

Keep a finding only when all of these are true:

- The requested diff introduced it.
- A concrete input, runtime path, or reference mismatch demonstrates the impact.
- The affected lines are identifiable and the proposed remedy is practical.
- Existing validation does not already present the same failure more clearly.
- It is not a generic style preference, speculative hardening request, or trivial nitpick.

Deduplicate findings that share a cause. Use severity to express actual impact, not confidence.

## Report

Lead with actionable findings in priority order. Attach line-specific findings to the shortest useful
changed-line range using the review UI's code-comment format. Briefly identify relevant validation
failures or gaps after the findings. If there are no actionable findings, say so directly.
