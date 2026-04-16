# MILESTONES 23 (Second-Wave Parser-Only Repo Coverage)

This milestone follows [MILESTONES_22.md](./MILESTONES_22.md).

Milestone 22 built the parser-only compatibility harness, checked-in artifacts, and the first proven staged boundary. It also onboarded the first real external parser-only grammar snapshots and made their current failures explicit.

This milestone exists to turn those deferred real external targets into concrete outcomes:

- promoted into the proven parser-only boundary
- left deferred with a narrower, better-classified parser-only gap
- or explicitly re-scoped if they turn out not to belong in parser-only coverage after all

It is not a scanner milestone. It is not a runtime-parity milestone. It is not an optimization milestone.

## Goal

- promote deferred external parser-only targets into the proven compatibility boundary where feasible
- shrink concrete parser-only gaps exposed by real external grammars
- keep the existing `src/compat/` harness and checked-in artifact model as the source of truth
- grow the proven boundary beyond the original staged 3-target first wave

## Current Starting Point

What is already true before this milestone starts:

- the current proven first-wave parser-only boundary still consists of 3 staged targets:
  - `parse_table_tiny_json`
  - `behavioral_config_json`
  - `repeat_choice_seq_js`
- the shortlist and derived artifacts are checked in under `compat_targets/`
- the shortlist now includes 2 real external parser-only snapshots:
  - `tree_sitter_ziggy_json`
  - `tree_sitter_ziggy_schema_json`
- those external targets now pass within the parser-only boundary after the word-token lowering and repeat-auxiliary shift/reduce fixes
- the remaining deferred parser-only target is the staged control case:
  - `parse_table_conflict_json`
    - intentionally remains blocked as a control fixture for a non-repeat shift/reduce ambiguity with no precedence annotations

## Scope Rules

In scope:

- parser-only gap fixing for deferred real external targets
- lowering, parse-table, emitter, compat-check, and compile-smoke changes needed to promote those targets
- tightening mismatch classification when a target remains deferred
- updating checked-in compatibility artifacts after each promoted/finalized target state

Out of scope:

- external-scanner coverage
- scanner/runtime parity milestones
- broad CLI surface expansion
- parse-table compression/minimization as the primary goal
- adding many more external targets before the current deferred ones are understood

## Candidate Queue

Primary targets for this milestone:

- `tree_sitter_ziggy_json`
  - current status: promoted into the proven boundary
  - outcome: emits within the current parser-only boundary after the repeat-auxiliary shift preference fix

- `tree_sitter_ziggy_schema_json`
  - current status: promoted into the proven boundary
  - outcome: emits within the current parser-only boundary after the word-token lowering and repeat-auxiliary fixes

Secondary target:

- `parse_table_conflict_json`
  - current status: deferred staged target
  - role in this milestone: remaining parser-only control case after the external Ziggy promotions landed
  - intended outcome: freeze explicitly as an intentional ambiguity/control fixture unless a later milestone broadens conflict-resolution policy on purpose

## Exit Criteria

- at least one deferred real external parser-only target is resolved to one of:
  - promoted into the proven boundary
  - kept deferred with a materially narrower classification and rationale
  - explicitly re-scoped out of parser-only promotion work
- the checked-in artifacts under `compat_targets/` reflect the resolved state
- the current proven parser-only boundary is either expanded or the remaining blocker is sharply classified enough to justify the next follow-on step
- the milestone ends with a decision on whether a third-wave parser-only milestone is needed, or whether scanner/runtime work should become the next promoted direction

## PR-Sized Slices

### PR 1

Goal:

- narrow the `tree_sitter_ziggy_schema_json` word-token-related parser-only gap

Scope:

- inspect how `word` tokens from external grammar snapshots are lowered and serialized
- decide whether this is:
  - a real unsupported parser-only rule shape
  - a missing normalization/lowering path
  - a serializer-side assumption that is too narrow
- add or refine mismatch classification if the existing bucket is too coarse

Current progress:

- tokenized composite word-token rules now lower successfully through `extract_tokens`
- `tree_sitter_ziggy_schema_json` now advances past the earlier `InvalidWordToken` failure and reaches the blocked parser-emission boundary

Acceptance:

- the target either advances past serialization or fails with a more precise classification and diagnostic

### PR 2

Goal:

- narrow the `tree_sitter_ziggy_json` blocked parser-emission boundary

Scope:

- inspect why the emitted parser surface remains blocked for this grammar
- determine whether the blocker is:
  - specifically reducible `shift_reduce` cases
  - grammar-precedence-related unresolved decisions
  - emitter-shape-related
- shrink the blocker or split it into a more precise deferred class

Acceptance:

- the target either emits within the current boundary or has a narrower promotion blocker than a generic blocked parser surface

Current progress:

- the deferred external targets were narrowed to repeat-auxiliary shift/reduce signatures and are now promoted into the proven boundary
- the checked-in `shortlist_shift_reduce_profile.json` artifact now correctly collapses to an empty deferred blocker set for the external Ziggy snapshots
- the remaining work in this slice is no longer external Ziggy promotion; it is deciding whether the staged `parse_table_conflict_json` control case should remain deferred or define the next parser-only follow-on

### PR 3

Goal:

- promote any newly passing external target into the proven boundary and refresh the milestone decision

Scope:

- move passing external targets from deferred later-wave to intended first-wave if justified
- regenerate:
  - `compat_targets/shortlist.json`
  - `compat_targets/shortlist_inventory.json`
  - `compat_targets/shortlist_report.json`
  - `compat_targets/shortlist_mismatch_inventory.json`
  - `compat_targets/coverage_decision.json`
- update milestone/docs only after the artifact state is real

Acceptance:

- the proven boundary and deferred queue are both explicit and internally consistent

Current progress:

- `tree_sitter_ziggy_json` and `tree_sitter_ziggy_schema_json` are now promoted into the intended first-wave parser-only run set
- the checked-in shortlist, report, inventory, mismatch, and coverage-decision artifacts now reflect that expanded proven boundary
- the remaining deferred parser-only queue is down to the staged `parse_table_conflict_json` control case

### PR 4

Goal:

- resolve or explicitly freeze `parse_table_conflict_json` as the last deferred parser-only control case in this milestone

Scope:

- inspect whether [compat_targets/parse_table_conflict/grammar.json](./compat_targets/parse_table_conflict/grammar.json) is intentionally ambiguous or still reducible within the current parser-only resolution model
- if it is intentionally ambiguous:
  - keep it deferred as an explicit control case
  - tighten milestone and artifact language so this is a deliberate remaining boundary, not an unclassified gap
- if it is reducible:
  - implement only the narrow resolution improvement needed for this grammar
  - regenerate the checked-in compatibility artifacts and update the closeout decision

Acceptance:

- `parse_table_conflict_json` is either:
  - promoted into the proven boundary
  - or kept deferred with an explicit rationale as an intentional conflict/control fixture
- `MILESTONES_23.md` and the checked-in `compat_targets/` artifacts end in a consistent closeout state

Current progress:

- `parse_table_conflict_json` is now treated explicitly as an intentionally ambiguous control fixture, not an unclassified leftover parser-only blocker
- the compatibility harness keeps it as a deferred blocked target with a locked shift/reduce signature on `expr`
- the milestone closeout path is now to finish artifact/doc regeneration around that frozen control case rather than chase another parser-only promotion

## Non-Goals

- do not treat scanner/external-scanner limitations as Milestone 23 regressions
- do not broaden the shortlist aggressively before the current deferred external targets are understood
- do not hide unresolved parser-only blockers behind a generic “still deferred” label
- do not claim runtime behavioral parity from compile-smoke and structural compatibility alone

## Expected Deliverables

- `MILESTONES_23.md` with concrete target queue and PR slices
- code changes that narrow or resolve the current deferred external parser-only gaps
- refreshed checked-in compatibility artifacts
- a closeout decision about whether parser-only repo coverage should continue into another wave
