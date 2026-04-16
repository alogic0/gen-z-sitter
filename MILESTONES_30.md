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

- [ ] the harness can represent a richer sampled scanner-boundary path than the current staged single-token matcher
- [ ] `tree_sitter_haskell_json` is either promoted into sampled real external scanner proof or deferred with a narrower explicit rationale than in M29
- [ ] checked-in artifacts distinguish structural real scanner proof from sampled real scanner proof
- [ ] the milestone ends with a clearer real external scanner modeling boundary than it started with

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

- [ ] wire the richer sampled model into the Haskell compatibility path
- [ ] add or refine targeted tests around the new sampled scanner path
- [ ] regenerate checked-in artifacts
- [ ] keep `zig build test` passing

Acceptance:

- [ ] the checked-in artifacts show a more specific sampled real external scanner state than the structural-only M29 baseline

### PR 3

Goal:

- decide the Haskell target outcome under the richer sampled model

Checklist:

- [ ] promote `tree_sitter_haskell_json` if the sampled path is compatibility-safe
- [ ] or freeze it with a narrower explicit rationale if the next blocker remains outside milestone scope
- [ ] update milestone/docs to match
- [ ] keep `zig build test` passing

Acceptance:

- [ ] the Haskell target no longer sits at the vague “broader modeling needed” boundary it inherited from M29

### PR 4

Goal:

- close out the milestone decision cleanly

Checklist:

- [ ] update milestone progress and closeout language
- [ ] update any affected compatibility docs
- [ ] keep the next-step recommendation explicit

Acceptance:

- [ ] the milestone closes without confusing sampled real external scanner proof with full runtime scanner support

## Progress Checklist

- [x] PR 1 completed
- [ ] PR 2 completed
- [ ] PR 3 completed
- [ ] PR 4 completed
- [ ] M30 ready for closeout

## Non-Goals

- do not present sampled scanner-boundary proof as scanner runtime parity
- do not broaden the milestone into general external-scanner onboarding without a concrete payoff
- do not regress the staged scanner fixtures while chasing a real external target
- do not hide a remaining Haskell limitation behind generic “unsupported scanner” wording

## Initial Candidate

- `tree_sitter_haskell_json` is the concrete M30 target
- the current honest next step is:
  - keep structural first-boundary extraction as the proven baseline
  - add a richer sampled scanner-boundary model for the concrete layout-sensitive sample path
  - either promote that sampled path or narrow the remaining blocker explicitly

## PR 1 Outcome

- the sampled scanner-boundary harness now supports a richer layout-token family than the old single `indent` matcher
- the new sampled surface covers:
  - layout-start tokens in the `_cmd_layout_start*` family
  - `_cond_layout_semicolon`
  - `_cond_layout_end`, including EOF closeout
- this is still a sampled model, not runtime scanner equivalence:
  - the new test uses a small synthetic layout grammar to validate the model shape
  - the real Haskell target remains structural-only until PR 2 wires an honest sampled path into that external grammar
