# MILESTONES 28 (Real-Repo Compatibility Evidence)

This milestone follows [MILESTONES_27.md](./MILESTONES_27.md).

Milestone 27 made the current staged boundary legible by family and proof layer. The next step is to widen and sharpen real compatibility evidence without turning the claim into runtime or corpus parity.

It is not a runtime-parity milestone. It is not a broad target-explosion milestone. It is not a generic optimization milestone.

## Goal

- widen the machine-readable evidence around real external grammar snapshots
- onboard a small number of additional high-value real targets when they are locally available
- keep staged fixtures and real external evidence visibly distinct
- either promote one additional real target or freeze it explicitly with rationale

## Starting Point

- [x] 5 intended first-wave parser-only targets pass within the proven boundary
- [x] 4 intended scanner-wave targets pass within the staged scanner boundary across 2 scanner families
- [x] `parse_table_conflict_json` remains the only frozen control fixture
- [x] 2 real external parser-only snapshots are already represented:
  - `tree_sitter_ziggy_json`
  - `tree_sitter_ziggy_schema_json`
- [x] broader compatibility polish is complete enough that real-repo evidence is the next useful axis to sharpen

## Scope

In scope:

- machine-readable reporting that separates real external evidence from staged fixtures
- onboarding 1 to 3 additional real targets when local sources exist
- precise classification for any newly exposed real-target blocker
- doc updates required to keep real evidence and staged evidence distinct

Out of scope:

- claiming full runtime or corpus parity
- broad CLI surfacing of compatibility artifacts
- large target-list expansion without local source availability
- major parser or scanner refactors without a clear real-evidence payoff

## Exit Criteria

- [x] the checked-in artifacts expose current external-repo evidence separately from staged fixtures
- [x] at least one additional real external target is onboarded or explicitly deferred with rationale
- [x] real external evidence is described distinctly from staged fixture proof in the repo docs
- [x] the milestone ends with a clearer real-evidence story than it started with

## PR-Sized Slices

### PR 1

Goal:

- add a dedicated external-repo evidence artifact

Checklist:

- [x] add a compatibility report surface that filters the shortlist down to external repo snapshots
- [x] expose represented real families and aggregate pass counts in that artifact
- [x] regenerate checked-in compatibility artifacts
- [x] keep `zig build test` passing

Acceptance:

- [x] the repo has a machine-readable snapshot of real external evidence that is not mixed into staged-only summaries

### PR 2

Goal:

- onboard or explicitly classify the next real target slice

Checklist:

- [x] inspect available local real grammar sources
- [x] choose 1 to 3 high-value real targets or record why none are locally available yet
- [x] add target metadata and snapshots if a new local real target exists, or record the current local-source limitation explicitly
- [x] regenerate checked-in artifacts
- [x] keep `zig build test` passing

Acceptance:

- [x] the milestone either grows the real-target set or records an explicit local-source limitation instead of leaving the gap implicit

### PR 3

Goal:

- land one narrow real-evidence improvement

Checklist:

- [x] choose one concrete real-target improvement
  - promote one new real target
  - narrow one newly exposed blocker
  - freeze one real target with explicit rationale if promotion is not justified
- [x] implement or document the narrower outcome
- [x] regenerate checked-in artifacts if needed
- [x] update milestone/docs to match
- [x] keep `zig build test` passing

Acceptance:

- [x] the milestone ends with a stronger and more explicit real-repo evidence claim than it started with

## Progress Checklist

- [x] PR 1 completed
- [x] PR 2 completed
- [x] PR 3 completed
- [x] M28 ready for closeout

## Non-Goals

- do not present staged fixtures as interchangeable with real external evidence
- do not claim runtime equivalence from snapshot-level generator checks alone
- do not broaden the shortlist just to increase counts
- do not hide missing local real-target sources behind vague milestone language

## Current PR 2 Note

- the repo currently has 2 checked-in real external parser-only snapshots:
  - `tree_sitter_ziggy_json`
  - `tree_sitter_ziggy_schema_json`
- a local filesystem sweep did not find additional checked-out real grammar repos beyond those already snapshotted into `compat_targets/`
- PR 2 therefore records the present local-source limitation explicitly instead of pretending a larger real-target wave is available right now

## PR 3 Outcome

- `compat_targets/external_repo_inventory.json` now records:
  - explicit boundary coverage for the current real external evidence
  - current machine-readable limitations for that evidence
  - the recommended next real-evidence step
- the resulting real-evidence claim is now narrower and clearer:
  - the repo has 2 passing real external parser-only snapshots
  - that proof is still parser-only
  - no real external scanner-family evidence is represented yet
  - the current blocker is local source availability, not hidden artifact ambiguity
