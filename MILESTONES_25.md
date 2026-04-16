# MILESTONES 25 (Scanner and External-Scanner Compatibility Onboarding)

This milestone follows [MILESTONES_24.md](./MILESTONES_24.md).

Milestone 24 closed out the broader compatibility-polish pass around the proven parser-only boundary. The next promoted step is to onboard scanner and external-scanner coverage deliberately, without diluting the current parser-only baseline or overstating runtime parity.

It is not a runtime-parity milestone. It is not a broad target-expansion milestone. It is not a CLI productization milestone.

## Goal

- onboard the first scanner and external-scanner compatibility targets
- define a narrow staged scanner compatibility boundary that the repo can defend
- extend checked-in compatibility artifacts so scanner-specific blockers are explicit
- keep the existing parser-only boundary stable while scanner evidence is added incrementally

## Starting Point

- [x] 5 intended first-wave parser-only targets pass within the proven boundary
- [x] `parse_table_conflict_json` remains frozen as an intentional ambiguity/control fixture
- [x] `hidden_external_fields_json` already exists as the first staged external-scanner fixture
- [x] checked-in compatibility artifacts under `compat_targets/` are the source of truth
- [x] scanner and external-scanner compatibility onboarding is the recommended next promoted milestone after M24

## Scope

In scope:

- first scanner and external-scanner target onboarding
- explicit classification of scanner-specific compatibility blockers
- compatibility artifact/reporting extensions needed for scanner coverage
- small targeted parser/scanner fixes with direct compatibility payoff
- milestone/doc updates that precisely describe the staged scanner boundary

Out of scope:

- full runtime behavioral parity claims
- broad real-repo target expansion beyond a narrow initial scanner wave
- large parser refactors without a concrete scanner-compatibility payoff
- broad CLI surfacing of compatibility reports
- optimization work that is not tied to scanner compatibility evidence

## Exit Criteria

- [ ] at least one scanner or external-scanner target is onboarded into the checked-in shortlist
- [ ] scanner-specific blockers are reported explicitly rather than folded into generic deferred buckets
- [ ] the repo can state a narrow staged scanner compatibility boundary without overstating runtime parity
- [ ] the checked-in compatibility artifacts and docs agree on what scanner coverage exists and what remains deferred

## PR-Sized Slices

### PR 1

Goal:

- define the initial scanner/external-scanner target wave and artifact vocabulary

Checklist:

- [x] choose a narrow initial scanner target set
- [x] decide which targets are intended first-wave, deferred, or out of scope
- [x] extend shortlist metadata if scanner-specific provenance or expectations need to be captured
- [x] regenerate checked-in shortlist artifacts if their shape changes
- [x] keep `zig build test` passing

Acceptance:

- [x] the repo has an explicit first scanner/external-scanner onboarding set with clear status and rationale

### PR 2

Goal:

- teach the compatibility harness and reports to classify scanner-specific blockers cleanly

Checklist:

- [x] add or refine mismatch categories for scanner/external-scanner failures
- [x] update harness/reporting code so scanner blockers are machine-readable in checked-in artifacts
- [x] add tests that lock the intended scanner classification behavior in place
- [x] regenerate checked-in compatibility artifacts
- [x] keep `zig build test` passing

Acceptance:

- [x] scanner-specific deferred cases are explicit in artifacts and no longer read like generic parser-only gaps

### PR 3

Goal:

- land one targeted compatibility improvement against the first scanner wave

Checklist:

- [ ] choose one narrowly scoped scanner-compatibility improvement
  - promote one onboarded scanner target
  - narrow one concrete scanner blocker
  - improve one scanner-boundary artifact/report enough to sharpen the milestone claim
- [ ] implement the change
- [ ] regenerate checked-in artifacts if needed
- [ ] update milestone/docs to match the new scanner boundary
- [ ] keep `zig build test` passing

Acceptance:

- [ ] the milestone ends with a stronger staged scanner compatibility claim than it started with

## Progress Checklist

- [x] PR 1 completed
- [x] PR 2 completed
- [ ] PR 3 completed
- [ ] M25 ready for closeout

## Non-Goals

- do not claim scanner/runtime equivalence from compile-smoke or artifact generation alone
- do not destabilize the proven parser-only boundary while onboarding scanner targets
- do not turn the milestone into a broad compatibility catch-all
- do not treat every external-scanner failure as a parser bug by default
