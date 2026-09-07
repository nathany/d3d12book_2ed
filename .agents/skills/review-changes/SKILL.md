---
name: review-changes
description: Review local branches, commits, pull-request diffs, or uncommitted changes in the d3d12book_2ed repository. Use for coverage-driven correctness review of the Odin reference port against the book's C++ implementation, including Direct3D 12 lifetimes, failure paths, parser arithmetic, validation results, and learning-oriented behavioral parity.
---

# Review Changes

Perform a read-only, single-agent code review. Do not edit the implementation or delegate work to
subagents. Search aggressively and report conservatively: generate candidates throughout every
applicable review pass, then filter them only after coverage is complete.

## Establish scope

1. Read the applicable `AGENTS.md` instructions.
2. Use the base branch, commit, or working-tree scope named by the user. If the user asks for a
   branch review without naming a base, use its merge base with `main`.
3. Inspect the complete diff, changed-file list, and diff statistics before assessing individual
   lines. Review added files in full rather than treating them as isolated hunks.
4. Let the requested scope control attribution, not inspection. Read unchanged callers, callees,
   shared helpers, and C++ counterparts whenever they establish behavior or impact.
5. Partition a large review into sequential units: shared infrastructure, DDS, and each changed
   chapter or demo. Keep one reviewer, but finish each unit instead of making one undifferentiated
   pass over the entire branch.
6. Maintain an internal coverage ledger for every unit: changed files, C++ counterpart, applicable
   semantic passes, candidates found, and final disposition. Do not finalize until every applicable
   pass is marked complete.

## Run semantic passes

Complete these passes for every applicable review unit. Do not stop after finding the first issues.

### 1. Reference-parity pass

Find and read the corresponding C++ implementation. Enumerate and compare:

- member defaults and numeric constants at both declarations and call sites;
- update, draw, input-message, and command-submission ordering;
- geometry, materials, render layers, shaders, and descriptor setup;
- every root-signature, PSO, blend, rasterizer, and depth/stencil mutation; and
- ownership, retirement, and cleanup behavior.

Compare complete initialized state, not only fields explicitly assigned in Odin; a missing
assignment can be the regression. Accept divergence only when required by Odin or Direct3D 12, or
explicitly documented with a sound teaching reason.

### 2. Failure-path pass

Enumerate fallible COM, DXGI, DXC, Win32, allocation, and file operations. For each one, trace the
status and every output through success, failure, cleanup, and later use. Check that failed calls or
nil outputs cannot be dereferenced, released, waited on, indexed, or passed onward.

### 3. GPU-lifetime pass

Trace transient resources and upload data through allocation, command recording, submission, fence
signaling, completion, and reuse. Verify queue order, resource states, descriptor lifetime, and all
paths that retire or recycle storage.

### 4. Untrusted-data pass

Trace file-derived dimensions, counts, formats, offsets, and mip/subresource values through
validation, multiplication and addition, allocation, indexing, and narrowing. Require checked wide
arithmetic before allocation or conversion and verify API limits and malformed-input behavior.

### 5. Cross-file and teaching pass

Inspect all affected call sites of changed shared helpers. Check comments and guide text against the
reference implementation, and flag changes that hide an important concept from a learner even when
the demo still renders.

Confirm material Odin semantics in the installed Odin source instead of assuming C/C++ behavior.
Honor documented deliberate deviations and known-benign diagnostics in `AGENTS.md`.

## Run deterministic validation

Run validation after the semantic inventory so passing checks do not substitute for review coverage.

1. Inspect the root Justfile and run the narrowest relevant recipes from the repository root.
2. Use `just check <example>` for changed runnable examples and `just check-test <package>` for
   changed test-only packages. Use `just test <package>` when tests exist.
3. Use `just validate` when the review covers the full Odin port and the cost is appropriate.
4. Build or run the affected package with ASan only when memory safety is relevant. Treat a passing
   sanitizer or tracking-allocator run as evidence for executed paths, not proof for all paths.
5. Report unavailable prerequisites and validation failures separately. Do not repeat a compiler
   diagnostic as an inline semantic finding.

## Validate each candidate finding

Revisit every ledger candidate and record an internal disposition: report it, or reject it for a
specific reason. Do not silently drop a candidate noticed during inspection. Keep a finding only
when all of these are true:

- The requested diff introduced it.
- A concrete input, runtime path, or reference mismatch demonstrates the impact.
- The affected lines are identifiable and the proposed remedy is practical.
- Existing validation does not already present the same failure more clearly.
- It is not a generic style preference, speculative hardening request, or trivial nitpick.

Merge candidates only when they share the same cause, affected behavior, location, and remedy. Keep
separate issues when their proof or fix belongs at different lines. Use severity to express actual
impact, not confidence.

## Report

Lead with actionable findings in priority order. Attach line-specific findings to the shortest useful
changed-line range using the review UI's code-comment format. For a missing assignment, attach the
finding to the nearest changed descriptor construction or initialization line. Briefly identify
relevant validation failures or gaps after the findings. If there are no actionable findings, say so
directly.
