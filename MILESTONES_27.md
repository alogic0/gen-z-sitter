# MILESTONES 27 (Broader Compatibility Polish)

This milestone follows [MILESTONES_26.md](./MILESTONES_26.md).

Milestone 26 widened the staged scanner boundary to two grammar families and closed with a stable promoted compatibility surface. The next step is not another target-onboarding wave by default. It is to make that staged boundary clearer, more defensible, and easier to evaluate across the repo without overstating runtime parity.

It is not a runtime-parity milestone. It is not a large scanner-expansion milestone. It is not a generic parser-refactor milestone.

## Goal

- tighten compatibility reporting and boundary language across the repo
- make the current staged boundary easier to evaluate by family and proof layer
- reduce coarse compatibility reporting where finer distinctions materially improve credibility
- keep the existing parser-only and staged scanner baselines stable while the compatibility claim gets clearer

## Starting Point

- [x] 5 intended first-wave parser-only targets pass within the proven boundary
- [x] 4 intended scanner-wave targets pass within the staged scanner boundary across 2 grammar families
- [x] `parse_table_conflict_json` remains the only deferred control fixture
- [x] checked-in compatibility artifacts under `compat_targets/` are the source of truth
- [x] `coverage_decision.json` recommends broader compatibility polish as the next promoted milestone

## Scope

In scope:

- artifact/report improvements that make the current boundary more legible
- machine-readable coverage refinements that clarify family representation and proof layers
- doc tightening needed to keep the staged compatibility claim precise
- narrowly scoped compatibility fixes only if they sharpen the current claim directly

Out of scope:

- claiming full runtime or corpus parity
- broad target-list expansion without a clear reporting or compatibility payoff
- broad CLI surfacing of compatibility artifacts
- major parser or scanner refactors without immediate compatibility value
- restarting another scanner-onboarding wave as the default theme

## Exit Criteria

- [x] checked-in compatibility artifacts expose coverage by grammar family rather than only flat target totals
- [ ] the repo docs describe the current proof layers and family coverage consistently
- [ ] at least one remaining coarse compatibility distinction is tightened or explicitly frozen with rationale
- [ ] the staged compatibility claim is clearer at milestone closeout than it was at the start

## PR-Sized Slices

### PR 1

Goal:

- add family-level coverage reporting to the checked-in compatibility artifacts

Checklist:

- [x] add explicit target-family metadata to the compatibility target model
- [x] propagate target family through the machine-readable shortlist and run-report surfaces
- [x] add family-level coverage output to the inventory and report artifacts
- [x] regenerate checked-in compatibility artifacts
- [x] keep `zig build test` passing

Acceptance:

- [x] the checked-in artifacts make it obvious which grammar families are represented and how each family is currently classified

### PR 2

Goal:

- tighten repo documentation around proof layers and family coverage

Checklist:

- [x] update the artifact guide to explain family-level coverage output
- [x] update top-level docs to distinguish proof layers from family representation
- [x] align milestone and compatibility docs with the refined artifact language
- [x] keep `zig build test` passing

Acceptance:

- [x] a reader can tell which parser-only and scanner families are represented without inferring that only from per-target lists

### PR 3

Goal:

- narrow one remaining coarse compatibility distinction or freeze it explicitly

Checklist:

- [ ] choose one coarse remaining distinction
  - a proof-layer ambiguity
  - a family-coverage ambiguity
  - a still-blurry deferred/control distinction
- [ ] implement or document the narrower classification
- [ ] regenerate checked-in artifacts if needed
- [ ] update milestone/docs to match
- [ ] keep `zig build test` passing

Acceptance:

- [ ] the milestone ends with a more defensible staged compatibility claim than it started with

## Progress Checklist

- [x] PR 1 completed
- [x] PR 2 completed
- [ ] PR 3 completed
- [ ] M27 ready for closeout

## Non-Goals

- do not claim runtime equivalence from staged boundary checks alone
- do not weaken the already-proven parser-only or staged scanner baselines
- do not use broader compatibility polish as a bucket for arbitrary roadmap cleanup
- do not hide family representation behind flat target-count reporting
