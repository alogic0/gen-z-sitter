# MILESTONES 30 (Stateful Real External Scanner Modeling)

This milestone follows [MILESTONES_29.md](./MILESTONES_29.md).

Milestone 29 closed the structural real external scanner story. Milestone 30 starts the next layer: sampled stateful real external scanner modeling for a real external grammar, without overstating that as full scanner runtime parity.

It is not a runtime-parity milestone. It is not a broad external-scanner onboarding milestone. It is not a generic scanner rewrite milestone.

## Goal

- extend the sampled scanner-boundary model beyond the current single-token staged matcher
- support one honest stateful or multi-token sampled path for a real external scanner grammar
- attempt to promote `tree_sitter_haskell_json` from structural-only proof into sampled real external scanner proof
- keep staged scanner fixtures and real external scanner evidence clearly separated

## Starting Point

- [x] real external scanner evidence is now reported separately from staged scanner fixtures
- [x] `tree_sitter_haskell_json` is onboarded with provenance and checked-in artifacts
- [x] `tree_sitter_haskell_json` now proves load, prepare, and structural first-boundary extraction
- [x] the current deferred point is explicit: broader sampled stateful multi-token external-scanner modeling is still outside the current harness

## Scope

In scope:

- narrow expansion of sampled scanner-boundary modeling for real external targets
- a targeted stateful or multi-token external-token matcher path driven by one real grammar
- updated classification, artifact, and doc language for the richer scanner-boundary story
- promotion or explicit freeze of the Haskell target based on the new sampled boundary

Out of scope:

- claiming `scanner.c` runtime equivalence
- corpus parsing or runtime-parity claims
- broad onboarding of many new external scanner grammars
- unrelated parser/scanner refactors without direct real-evidence payoff

## Exit Criteria

- [x] the harness can represent a richer sampled scanner-boundary path than the current staged single-token matcher
- [x] `tree_sitter_haskell_json` is either promoted into sampled real external scanner proof or deferred with a narrower explicit rationale than in M29
- [x] checked-in artifacts distinguish structural real scanner proof from sampled real scanner proof
- [x] the milestone ends with a clearer real external scanner modeling boundary than it started with

## PR-Sized Slices

### PR 1

Goal:

- add the minimum model surface needed for sampled multi-token real external scanner checks

Checklist:

- [x] identify the smallest real scanner behavior expansion needed by the Haskell sample path
- [x] extend the sampled scanner-boundary model to represent more than the current single-token staged matcher
- [x] keep the staged scanner fixtures green under the broader model
- [x] keep `zig build test` passing

Acceptance:

- [x] the harness can represent the next honest sampled scanner step without claiming full scanner runtime behavior

### PR 2

Goal:

- implement one concrete sampled real external scanner path

Checklist:

- [x] wire the richer sampled model into the Haskell compatibility path
- [x] add or refine targeted tests around the new sampled scanner path
- [x] regenerate checked-in artifacts
- [x] keep `zig build test` passing

Acceptance:

- [x] the checked-in artifacts show a more specific sampled real external scanner state than the structural-only M29 baseline

### PR 3

Goal:

- decide the Haskell target outcome under the richer sampled model

Checklist:

- [x] promote `tree_sitter_haskell_json` if the sampled path is compatibility-safe
- [ ] or freeze it with a narrower explicit rationale if the next blocker remains outside milestone scope
- [x] update milestone/docs to match
- [x] keep `zig build test` passing

Acceptance:

- [x] the Haskell target no longer sits at the vague “broader modeling needed” boundary it inherited from M29

### PR 4

Goal:

- close out the milestone decision cleanly

Checklist:

- [x] update milestone progress and closeout language
- [x] update any affected compatibility docs
- [x] keep the next-step recommendation explicit

Acceptance:

- [x] the milestone closes without confusing sampled real external scanner proof with full runtime scanner support

## Progress Checklist

- [x] PR 1 completed
- [x] PR 2 completed
- [x] PR 3 completed
- [x] PR 4 completed
- [x] M30 ready for closeout

## Non-Goals

- do not present sampled scanner-boundary proof as scanner runtime parity
- do not broaden the milestone into general external-scanner onboarding without a concrete payoff
- do not regress the staged scanner fixtures while chasing a real external target
- do not hide a remaining Haskell limitation behind generic “unsupported scanner” wording

## Initial Candidate

- `tree_sitter_haskell_json` was the concrete M30 target
- the milestone outcome is:
  - structural first-boundary extraction remains the lower proof layer inherited from M29
  - M30 adds a richer sampled scanner-boundary model for layout-token families and lightweight lexical fallback
  - that richer sampled model is now enough to promote the Haskell snapshot into sampled real external scanner proof

## PR 1 Outcome

- the sampled scanner-boundary harness now supports a richer layout-token family than the old single `indent` matcher
- the new sampled surface covers:
  - layout-start tokens in the `_cmd_layout_start*` family
  - `_cond_layout_semicolon`
  - `_cond_layout_end`, including EOF closeout
- this is still a sampled model, not runtime scanner equivalence:
  - the new test uses a small synthetic layout grammar to validate the model shape
  - PR 2 then wires that richer sampled model into the real Haskell target without claiming scanner.c runtime equivalence

## PR 2 Outcome

- the harness now has a `sampled_external_only` scanner-boundary mode for real external scanner targets
- that mode samples:
  - layout-token families
  - lightweight lexical fallback for the concrete external sample path
  - valid-vs-invalid progress without requiring full parse-state construction
- `tree_sitter_haskell_json` now passes within that sampled real external scanner boundary

## Closeout

- M30 now ends with:
  - a richer sampled scanner-boundary model than the old single-token staged matcher
  - one passing real external scanner snapshot under a sampled external-sequence proof layer
  - explicit machine-readable distinction between:
    - structural real scanner proof
    - sampled real scanner proof
    - full runtime scanner parity, which is still out of scope
- the next recommended milestone is broader compatibility polish, not another immediate Haskell-specific rescue step
