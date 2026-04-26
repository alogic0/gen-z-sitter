# MILESTONES 32 (Broader Compatibility Polish)

This milestone follows [MILESTONES_31.md](./MILESTONES_31.md).

Milestone 31 widened the real external evidence boundary to include two passing real external parser-only snapshots and two passing sampled real external scanner snapshots. Milestone 32 focuses on polishing that stronger boundary so the current compatibility claim is clearer, tighter, and more defensible.

It is not a runtime-parity milestone. It is not a broad onboarding milestone. It is not a generic parser or scanner rewrite milestone.

## Goal

- tighten compatibility language across docs and checked-in artifacts
- reduce any remaining coarse classifications where a sharper distinction improves the evidence story
- clarify the relationship between staged proof, real external proof, frozen controls, and sampled scanner proof
- optionally add one small evidence-quality improvement only if it materially improves the current claim

## Starting Point

- [x] 2 real external parser-only snapshots now pass within the current checked-in boundary
- [x] 2 real external scanner snapshots now pass within sampled proof layers with scope-limited claims
- [x] 1 parser-only control fixture remains frozen explicitly rather than being counted as a normal pass
- [x] the current coverage decision now recommends broader compatibility polish

## Scope

In scope:

- tightening wording and machine-readable summaries around the current compatibility boundary
- refining one remaining coarse compatibility classification or inventory surface if needed
- improving evidence quality with one small, high-signal adjustment only if it changes the claim meaningfully
- closing the milestone from checked-in evidence rather than roadmap intent

Out of scope:

- claiming `scanner.c` runtime equivalence
- corpus parsing or runtime-parity claims
- broad onboarding of additional grammar families as the main goal
- large parser or scanner refactors without direct compatibility-proof payoff

## Exit Criteria

- [x] checked-in docs and artifacts describe the current boundary without stale counts or mixed proof-layer language
- [x] at least one coarse remaining classification or reporting surface is tightened, or the milestone records that no further split is justified
- [x] the final boundary language distinguishes sampled real scanner proof from full runtime parity consistently across the repo
- [x] the milestone ends with a cleaner closeout story than M31 started with
- [x] the next-step recommendation is updated from the final checked-in state

## PR-Sized Slices

### PR 1: Tighten Boundary Language

- [x] audit the current compatibility wording across milestone docs, top-level docs, and checked-in artifacts
- [x] remove stale counts or ambiguous boundary phrasing
- [x] make the current proof layers read consistently in all major surfaces

### PR 2: Refine One Reporting Surface

- [x] identify one remaining coarse classification or inventory summary that still hides a useful distinction
- [x] tighten that reporting surface with the smallest change that improves the evidence story
- [x] regenerate the checked-in artifacts to reflect the refined classification or summary

### PR 3: Add One Small Evidence-Quality Improvement Or Explicitly Decline It

- [x] evaluate whether one small additional evidence-quality change materially improves the current claim
- [x] if yes, implement it without widening the milestone into a new onboarding wave
- [x] if no, record that decision explicitly so the closeout is intentional

### PR 4: Closeout

- [x] update coverage decision and milestone notes from the final checked-in evidence
- [x] tighten `README.md`, `compatibility-matrix.md`, and `compat_targets/README.md`
- [x] mark the final boundary and remaining limitations explicitly

## Progress

- [x] PR 1 completed
- [x] PR 2 completed
- [x] PR 3 completed
- [x] PR 4 completed
- [x] M32 ready for closeout

## Non-Goals

- do not turn M32 into another broad onboarding milestone
- do not present sampled real scanner proof as runtime parity
- do not regress the current passing staged or real external targets while polishing the reporting surface
- do not add new complexity unless it materially improves the compatibility claim

## Initial Focus

- keep the current real external boundary stable:
  - `tree_sitter_ziggy_json`
  - `tree_sitter_ziggy_schema_json`
  - `tree_sitter_haskell_json`
  - `tree_sitter_bash_json`
- keep the frozen parser-only control fixture explicit:
  - `parse_table_conflict_json`
- prefer improvements that make the proof layers and limitations easier to read from artifacts alone

## Closeout Target

- M32 should end with a cleaner and more internally consistent compatibility story than M31
- the outcome should say clearly:
  - what is staged proof
  - what is real external proof
  - what remains a frozen control fixture
  - what is sampled scanner proof rather than runtime parity

## Closeout

- M32 now ends with:
  - clearer proof-layer language across `README.md`, `compatibility-matrix.md`, and `compat_targets/README.md`
  - a machine-readable distinction between the two promoted real external scanner proof scopes:
    - `sampled_external_sequence`
    - `sampled_expansion_path`
  - an unchanged promoted real-external boundary:
    - parser-only snapshots:
      - `tree_sitter_ziggy_json`
      - `tree_sitter_ziggy_schema_json`
    - sampled real external scanner snapshots:
      - `tree_sitter_haskell_json`
      - `tree_sitter_bash_json`
    - frozen parser-only control fixture:
      - `parse_table_conflict_json`
- no additional onboarding was needed for this milestone because the evidence-quality and reporting improvements were enough to make the current boundary cleaner and more explicit
- the checked-in next-step recommendation remains `broader_compatibility_polish`, now backed by the tightened reporting surfaces rather than only by milestone intent
