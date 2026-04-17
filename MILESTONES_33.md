# MILESTONES 33 (Real External Evidence Expansion)

This milestone follows [MILESTONES_32.md](./MILESTONES_32.md).

Milestone 32 polished the current compatibility boundary and made the real external proof scopes machine-readable. Milestone 33 widens that evidence set again, but only where a new target adds a distinct proof shape rather than just increasing raw counts.

It is not a runtime-parity milestone. It is not a broad target-count milestone. It is not a generic parser or scanner rewrite milestone.

## Goal

- widen the real external evidence set beyond the current Ziggy, Haskell, and Bash snapshots
- prefer new targets that add a distinct compatibility shape instead of duplicating the current proof surface
- classify any new blocker shape or proof scope explicitly in checked-in artifacts
- promote at least one newly added real external target if feasible, or freeze it explicitly with rationale

## Starting Point

- [x] 2 real external parser-only snapshots now pass within the current checked-in boundary
- [x] 2 real external scanner snapshots now pass within scope-limited sampled proof layers
- [x] real external scanner proof scopes are now machine-readable in the checked-in artifacts
- [x] the current coverage decision now recommends broader compatibility polish rather than emergency scanner onboarding

## Scope

In scope:

- onboarding 1 to 3 additional real external snapshots only where they improve evidence quality
- preferring targets that add a new proof shape:
  - another real external parser-only family with materially different structure
  - another real external scanner family with a different sampled boundary shape
  - a real `grammar.js`-heavy target if it improves loader-path evidence
- extending inventories and proof-scope reporting only where the new evidence requires it
- either promoting or explicitly freezing each newly added target with a clear rationale

Out of scope:

- claiming `scanner.c` runtime equivalence
- corpus parsing or runtime-parity claims
- broad target sweeps without evidence payoff
- large parser or scanner refactors without direct compatibility-proof value

## Exit Criteria

- [x] at least one new real external target is added with provenance and explicit rationale
- [x] checked-in artifacts record any new blocker shape or proof-scope distinction precisely instead of burying it in notes
- [x] at least one newly added target is either promoted or explicitly frozen with a named rationale
- [ ] the milestone ends with a broader real external evidence boundary than M32
- [x] the next-step recommendation is updated from the final checked-in evidence

## PR-Sized Slices

### PR 1: Select And Snapshot New Real External Targets

- [x] choose 1 to 3 high-value real external targets with explicit rationale
- [x] add snapshot metadata, provenance, and any minimal sample inputs they need
- [x] expose the new targets in the checked-in artifacts immediately, even if initially deferred

### PR 2: Classify New Proof Shapes Or Blockers

- [x] identify any genuinely new blocker shape or proof-scope distinction the new targets introduce
- [x] tighten the inventories or report surfaces only where the new evidence requires it
- [x] regenerate the checked-in artifacts to make the new distinction machine-readable

### PR 3: Promote Or Freeze One New Target

- [x] choose one newly onboarded target for a narrow compatibility improvement or an explicit freeze decision
- [x] either promote that target or freeze it with a named rationale
- [x] keep the current passing staged and real external boundary stable while doing so

### PR 4: Closeout

- [ ] update coverage decision and milestone notes from the final checked-in evidence
- [ ] tighten `README.md`, `compatibility-matrix.md`, and `compat_targets/README.md`
- [ ] mark the final widened boundary and remaining limitations explicitly

## Progress

- [x] PR 1 completed
- [x] PR 2 completed
- [x] PR 3 completed
- [ ] PR 4 completed
- [ ] M33 ready for closeout

## Non-Goals

- do not turn M33 into a broad uncontrolled onboarding wave
- do not present sampled real scanner proof as runtime parity
- do not regress the current passing staged or real external targets while widening evidence
- do not add new complexity unless it materially improves the compatibility claim

## Current M33 State

- `tree_sitter_c_json`
  - onboarded as the first M33 real external parser-only expansion target
  - provenance is checked in under `compat_targets/tree_sitter_c/grammar.json`
  - intentionally classified as a deferred parser-boundary target rather than a promoted pass
  - current claimed proof is:
    - `load`
    - `prepare`
  - current non-claimed proof is:
    - full emitted parser surfaces
    - `parser.c` compatibility check
    - compile-smoke
- the new explicit blocker shape is `parser_external_boundary_gap`
- the new explicit deferred status is `deferred_parser_wave` / `deferred_for_parser_boundary`
- the current checked-in coverage decision now points to `second_wave_parser_only_repo_coverage`

## Closeout Target

- M33 should end with a broader and still well-scoped real external evidence story than M32
- the outcome should say clearly:
  - which real external parser-only families are represented
  - which real external scanner families are represented
  - which new targets pass
  - which new targets remain frozen or deferred, and why
