# MILESTONES 24 (Broader Compatibility Polish)

This milestone follows [MILESTONES_23.md](./MILESTONES_23.md).

Milestone 23 expanded the proven parser-only boundary to five passing first-wave targets, promoted the external Ziggy snapshots, and froze `parse_table_conflict_json` as an intentional ambiguity/control fixture. The next step is not another parser-only onboarding wave. It is to tighten compatibility claims, reporting, and artifact quality around that broader proven boundary.

It is not a scanner milestone. It is not a runtime-parity milestone. It is not an optimization-first milestone.

## Goal

- make the current compatibility boundary clearer, more stable, and easier to defend
- improve compatibility reporting around proven targets, deferred control cases, and out-of-scope targets
- add only targeted evidence that broadens confidence without reopening milestone scope recklessly

## Starting Point

- [x] 5 intended first-wave parser-only targets pass within the proven boundary
- [x] `tree_sitter_ziggy_json` is promoted into the proven boundary
- [x] `tree_sitter_ziggy_schema_json` is promoted into the proven boundary
- [x] `parse_table_conflict_json` is frozen as an intentional ambiguity/control fixture
- [x] `hidden_external_fields_json` remains explicitly out of scope for parser-only work
- [x] checked-in compatibility artifacts under `compat_targets/` are the source of truth

## Scope

In scope:

- compatibility artifact/reporting polish
- sharper distinction between proven, deferred-control, and out-of-scope targets
- small targeted additions that improve confidence in the current compatibility claim
- milestone/doc cleanup so the repo states its current boundary precisely

Out of scope:

- scanner or external-scanner support
- runtime behavioral parity claims
- broad CLI productization
- large parser refactors without a concrete compatibility payoff
- aggressive target-list expansion

## Exit Criteria

- [ ] the checked-in compatibility artifacts clearly distinguish:
  - proven parser-only targets
  - intentional deferred control fixtures
  - out-of-scope scanner targets
- [ ] milestone/docs no longer imply another parser-only onboarding wave is the default next step
- [ ] at least one targeted compatibility-polish improvement lands beyond milestone wording alone
- [ ] the repo ends with a clear recommendation for the next promoted milestone after M24

## PR-Sized Slices

### PR 1

Goal:

- tighten the artifact and report surfaces around the now-proven parser-only boundary

Checklist:

- [x] review `compat_targets/` artifacts for duplicated or unclear boundary language
- [x] improve wording or structure where proven, deferred-control, and out-of-scope cases are still too implicit
- [x] update golden artifacts if the rendered report shape changes
- [x] keep `zig build test` passing

Acceptance:

- [x] the checked-in artifacts communicate the current boundary without relying on milestone context

### PR 2

Goal:

- improve the treatment of intentional blocked/control fixtures so they are explicit and stable

Checklist:

- [x] review whether `parse_table_conflict_json` should have a more explicit control-fixture/report bucket
- [x] add or refine tests that lock the intended frozen-control behavior in place
- [x] update reports/artifacts if a clearer classification surface is added
- [x] keep `zig build test` passing

Acceptance:

- [x] the frozen control case is represented as a deliberate boundary, not a vague deferred failure

### PR 3

Goal:

- add one small, high-signal compatibility confidence improvement without broadening scope

Checklist:

- [ ] choose one narrowly scoped improvement:
  - add a carefully selected non-scanner target
  - strengthen compatibility reporting for proven targets
  - tighten a remaining compatibility-matrix or README ambiguity
- [ ] implement the change
- [ ] regenerate checked-in artifacts if needed
- [ ] keep `zig build test` passing

Acceptance:

- [ ] the milestone ends with a stronger compatibility claim than it started with

## Progress Checklist

- [x] PR 1 completed
- [x] PR 2 completed
- [ ] PR 3 completed
- [ ] M24 ready for closeout

## Non-Goals

- do not treat scanner limitations as regressions in this milestone
- do not reopen broad parser-only repo onboarding as the main track
- do not claim runtime parity from compile-smoke and structural compatibility
- do not turn this milestone into a generic cleanup bucket
