# MILESTONES 26 (Second-Wave Scanner and External-Scanner Coverage)

This milestone follows [MILESTONES_25.md](./MILESTONES_25.md).

Milestone 25 proved the first staged scanner boundary with `hidden_external_fields` in JSON and JS form. The next promoted step is to broaden scanner and external-scanner evidence beyond that single family while keeping the proven parser-only and first-wave scanner baselines stable.

It is not a runtime-parity milestone. It is not a broad target-explosion milestone. It is not a generic parser-refactor milestone.

## Goal

- onboard a second wave of scanner and external-scanner targets
- classify scanner-specific blocker types using real additional targets
- promote at least one new scanner target when the staged boundary is sufficient
- keep the existing parser-only and first-wave scanner boundaries stable while scanner evidence broadens

## Starting Point

- [x] 5 intended first-wave parser-only targets pass within the proven boundary
- [x] 2 intended scanner-wave targets pass within the first staged external-scanner boundary:
  - `hidden_external_fields_json`
  - `hidden_external_fields_js`
- [x] `parse_table_conflict_json` remains the only deferred control fixture
- [x] checked-in compatibility artifacts under `compat_targets/` are the source of truth
- [x] second-wave scanner and external-scanner coverage is the next promoted milestone after M25

## Scope

In scope:

- 1 to 3 additional scanner or external-scanner targets
- scanner-specific blocker classification using real additional targets
- small parser/scanner fixes with direct compatibility payoff
- compatibility artifact and doc updates required for the new scanner wave
- explicit decisions about which new scanner targets are promoted, deferred, or frozen

Out of scope:

- claiming full runtime or corpus parity
- broad target-list expansion without a clear scanner-compatibility reason
- large parser refactors without a concrete scanner payoff
- broad CLI surfacing of compatibility artifacts
- non-scanner roadmap cleanup that does not improve compatibility evidence

## Exit Criteria

- [x] at least one additional scanner or external-scanner grammar family is represented in the checked-in shortlist
- [x] scanner blocker categories are informed by real second-wave targets rather than only the first staged fixture
- [x] at least one second-wave scanner target is either promoted or explicitly frozen with a clear rationale
- [x] the checked-in artifacts and docs describe the widened scanner boundary without overstating runtime parity

## PR-Sized Slices

### PR 1

Goal:

- choose and onboard the second-wave scanner target set

Checklist:

- [x] select 1 to 3 additional scanner or external-scanner targets
- [x] decide which are intended wave targets, deferred targets, or explicit control cases
- [x] add checked-in target metadata and any required staged input fixtures
- [x] regenerate checked-in shortlist artifacts if their shape or contents change
- [x] keep `zig build test` passing

Acceptance:

- [x] the shortlist covers more than one scanner grammar family with explicit target status and rationale

### PR 2

Goal:

- classify the real second-wave scanner blockers precisely

Checklist:

- [x] identify the concrete blocker types exposed by the new scanner targets
- [x] refine compatibility mismatch/report buckets if the current model is too coarse
- [x] add or update tests that lock the intended scanner-blocker classifications in place
- [x] regenerate checked-in compatibility artifacts
- [x] keep `zig build test` passing

Acceptance:

- [x] second-wave scanner blockers appear in artifacts as concrete categories rather than one generic deferred bucket

### PR 3

Goal:

- land one targeted scanner-compatibility improvement from the second wave

Checklist:

- [x] choose one narrowly scoped improvement
  - promote one new scanner target
  - narrow one concrete second-wave blocker
  - freeze one target with explicit control-rationale if promotion is not justified
- [x] implement the change
- [x] regenerate checked-in artifacts if needed
- [x] update milestone/docs to match the new scanner boundary
- [x] keep `zig build test` passing

Acceptance:

- [x] the milestone ends with a stronger multi-family scanner compatibility claim than it started with

## Closeout State

- 5 intended first-wave parser-only targets still pass within the proven staged boundary
- 4 intended scanner-wave targets now pass within the staged scanner boundary across 2 grammar families:
  - `hidden_external_fields_json`
  - `hidden_external_fields_js`
  - `mixed_semantics_json`
  - `mixed_semantics_js`
- `parse_table_conflict_json` remains the only deferred control fixture
- the checked-in compatibility artifacts now record a multi-family staged scanner boundary and recommend `broader_compatibility_polish` as the next promoted milestone

## Progress Checklist

- [x] PR 1 completed
- [x] PR 2 completed
- [x] PR 3 completed
- [x] M26 ready for closeout

## Non-Goals

- do not claim scanner/runtime equivalence from staged boundary checks alone
- do not weaken the already-proven parser-only or first-wave scanner baselines
- do not turn second-wave scanner work into a generic compatibility catch-all
- do not hide unresolved scanner blockers behind generic parser-gap language
