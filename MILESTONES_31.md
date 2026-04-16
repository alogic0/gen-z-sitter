# MILESTONES 31 (Broader Real External Compatibility Evidence)

This milestone follows [MILESTONES_30.md](./MILESTONES_30.md).

Milestone 30 proved the first sampled real external scanner path with `tree_sitter_haskell_json`. Milestone 31 widens the real external evidence set without overstating that as runtime parity or corpus-level compatibility.

It is not a runtime-parity milestone. It is not a broad target-count milestone. It is not a generic parser or scanner rewrite milestone.

## Goal

- widen real external compatibility evidence beyond the current Ziggy and Haskell snapshots
- prefer new external targets that add a distinct proof shape rather than just increasing raw counts
- classify any new blocker shapes precisely in the checked-in artifacts
- promote at least one new real external target if feasible, or freeze it explicitly with rationale

## Starting Point

- [x] real external parser-only evidence exists and is reported separately from staged fixtures
- [x] sampled real external scanner evidence exists for `tree_sitter_haskell_json`
- [x] checked-in artifacts already distinguish staged proof from real external proof
- [x] the current recommended next step after M30 is broader real external compatibility evidence

## Scope

In scope:

- onboarding 1 to 3 additional real external grammar snapshots where they improve evidence quality
- preferring targets that add a new compatibility shape:
  - another real external scanner family
  - another real external parser-only family with materially different structure
  - possibly one grammar.js-heavy external target if it exercises a distinct loader path
- extending inventories, mismatch reporting, and coverage decisions only as needed for the new evidence
- either promoting or explicitly freezing each newly onboarded target with a clear rationale

Out of scope:

- claiming `scanner.c` runtime equivalence
- corpus parsing or runtime-parity claims
- broad CLI productization
- large parser or scanner refactors without direct evidence payoff

## Exit Criteria

- [x] at least one new real external target is added with provenance and explicit rationale
- [x] checked-in artifacts record any new real blocker shape precisely instead of folding it into a generic bucket
- [x] at least one newly added real external target is either promoted or explicitly frozen with a named rationale
- [x] the milestone ends with a clearer real external evidence boundary than M30
- [x] the next-step recommendation is updated from actual checked-in evidence rather than milestone intent

## PR-Sized Slices

### PR 1: Select And Snapshot The Next Real External Targets

- [x] choose 1 to 3 high-value external targets with explicit rationale
- [x] add snapshot metadata, provenance, and any minimal sample inputs they need
- [x] update `compat_targets/` artifacts so the new targets are visible immediately, even if deferred

### PR 2: Classify New Real Blocker Shapes

- [x] extend the compatibility model only where the new targets expose a genuinely new blocker shape
- [x] regenerate inventories and reports so the new blocker surface is machine-readable
- [x] update milestone notes to record the exact blocker classes now represented

### PR 3: Narrow One Real External Gap

- [x] choose one newly onboarded target for a narrow compatibility improvement
- [x] either promote that target or freeze it explicitly with a dedicated rationale
- [x] keep the already-proven real external boundary stable while narrowing the new gap

### PR 4: Closeout

- [x] update coverage decision and external inventory artifacts from the final evidence state
- [x] tighten `README.md`, `compatibility-matrix.md`, and `compat_targets/README.md`
- [x] mark the final real external boundary and remaining limitations explicitly

## Progress

- [x] PR 1 completed
- [x] PR 2 completed
- [x] PR 3 completed
- [x] PR 4 completed
- [x] M31 ready for closeout

## Non-Goals

- do not turn M31 into a large uncontrolled target sweep
- do not present sampled real external scanner proof as runtime parity
- do not regress the current staged or real external passing targets while widening evidence
- do not hide newly discovered limitations behind generic “unsupported grammar” wording

## Initial Candidate Queue

- `tree_sitter_c`
  - real external parser-only candidate available locally
  - useful if it exposes a materially different parser-table shape than current Ziggy coverage
- `tree_sitter_zig`
  - real external parser-only candidate available locally
  - useful if it broadens evidence without introducing scanner-specific scope
- one additional real external scanner family
  - preferred if a local snapshot becomes available during the milestone
  - should only be onboarded if it adds a genuinely new blocker or proof shape beyond Haskell

## Current Outcome

- `tree_sitter_bash_json` is now onboarded as a real external scanner-family target
- its current boundary is explicit:
  - `load` passes
  - `prepare` passes
  - structural first external-boundary extraction passes
  - a narrow sampled Bash expansion path now also passes
  - the promoted sampled claim is intentionally narrow: `_bare_dollar` plus `variable_name` on a simple expansion path
- this adds a second passing real external scanner family to the evidence set without claiming broader heredoc handling or full scanner runtime parity

## Closeout Target

- M31 should end with a broader and more defensible real external evidence set than M30
- the outcome should say clearly:
  - which real parser-only families are represented
  - which real scanner families are represented
  - which newly added targets pass
  - which newly added targets remain frozen or deferred, and why

## Closeout

- M31 now ends with:
  - 2 passing real external parser-only snapshots:
    - `tree_sitter_ziggy_json`
    - `tree_sitter_ziggy_schema_json`
  - 2 passing real external scanner snapshots:
    - `tree_sitter_haskell_json`
    - `tree_sitter_bash_json`
  - explicit family-level reporting for both parser-only and scanner/external-scanner real evidence
  - an unchanged frozen parser-only control fixture:
    - `parse_table_conflict_json`
- the resulting boundary is broader than M30 because it adds a second passing real external scanner family, while still keeping the scanner claim narrower than full runtime parity
- the checked-in next-step recommendation now returns to broader compatibility polish from actual evidence rather than milestone intent
