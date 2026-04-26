# MILESTONES 41 (Real External Parser Boundary Follow-Up)

This milestone follows [MILESTONES_40.md](./MILESTONES_40.md).

Milestone 40 was the upstream-shape item-set refactor. Its job was to bring the parse-table builder closer to the tree-sitter algorithm so that future compatibility work would rest on the right parser-generator shape. That work is now in place, the suite is green, and the next useful step is to spend that structural work on the main goal of the project: a stronger, more defensible real-grammar compatibility boundary.

That means the next milestone should not be another parser-core cleanup pass. It should be a narrow real external compatibility milestone centered on the one remaining real parser-only target with direct payoff:

- `tree_sitter_ziggy_schema_json`

This milestone is about either promoting that target into the current parser-only boundary or proving, with a tighter explicit reason, that it still sits outside the current staged surface.

It is not a runtime-parity milestone. It is not a scanner-expansion milestone. It is not a broad parser-wave milestone. It is not a generic parser-core cleanup milestone.

## Goal

- reproduce the current parser-boundary blocker for `tree_sitter_ziggy_schema_json`
- compare that blocker directly against upstream tree-sitter for the same grammar
- either promote `tree_sitter_ziggy_schema_json` into the current parser-only boundary or leave it deferred with a sharper explicit rationale
- keep the already-promoted parser-only and scanner boundaries stable while doing so

## Starting Point

- [x] the M40 upstream-shape item-set refactor is in place
- [x] `zig build test` passes after the refactor
- [x] targeted Haskell stress validation still passes under the current staged scanner boundary
- [x] `tree_sitter_c_json` is already `passed_within_current_boundary`
- [x] `tree_sitter_ziggy_json` is already `passed_within_current_boundary`
- [x] `tree_sitter_ziggy_schema_json` is still `deferred_for_parser_boundary`
- [x] `repeat_choice_seq_js` is still `deferred_for_parser_boundary`, but it is not the primary target of this milestone
- [x] `parse_table_conflict_json` remains an intentional frozen parser-only control fixture

## Scope

In scope:

- isolating the exact first blocked stage for `tree_sitter_ziggy_schema_json`
- capturing the concrete failure detail instead of treating it as a generic deferred parser surface
- comparing the same grammar and boundary against upstream tree-sitter
- landing the smallest parser/emitter/compat fix that has a direct promotion payoff for this target
- refreshing checked-in compatibility artifacts and milestone/docs after the final decision

Out of scope:

- broad parser-wave onboarding
- scanner/runtime parity claims
- more structural parse-table refactoring unless the `tree_sitter_ziggy_schema_json` blocker proves that it is strictly necessary
- turning `parse_table_conflict_json` into a promotion target
- making `repeat_choice_seq_js` a co-equal milestone-driving target

## Exit Criteria

- [ ] the current `tree_sitter_ziggy_schema_json` blocker is reproduced as one concrete parser-boundary failure
- [ ] that failure is compared directly against upstream tree-sitter for the same grammar
- [ ] `tree_sitter_ziggy_schema_json` is either:
  - promoted into the current parser-only boundary
  - or kept deferred with a tighter named rationale than its current generic parser-boundary wording
- [ ] checked-in compatibility artifacts reflect the final state accurately
- [ ] the milestone closes with clean `zig run update_compat_artifacts.zig` and `zig build test`

## PR-Sized Slices

### PR 1: Reproduce And Compare The Real Blocker

- [ ] isolate `tree_sitter_ziggy_schema_json` in the compat harness
- [ ] capture the exact first blocked stage and failure detail
- [ ] run or inspect upstream tree-sitter on the same grammar and compare the equivalent boundary directly
- [ ] classify the mismatch as one of:
  - local parser bug
  - local emitter bug
  - compatibility-harness boundary mismatch
  - or a real unsupported staged-boundary case

Success signal:

- the next step is chosen from a direct upstream comparison, not from local guesswork

### PR 2: Fix Or Sharpen The Boundary

- [ ] if the blocker is a local parser/emitter/compat issue, land the smallest change that moves `tree_sitter_ziggy_schema_json` across the blocked boundary
- [ ] if the blocker is a real current-boundary limitation, keep the target deferred but make that limit explicit and narrow
- [ ] add or tighten a targeted regression test only where it locks the real blocker or the real fix in place

Success signal:

- `tree_sitter_ziggy_schema_json` either passes within the current boundary or has a precise deferred reason that the repo can defend

### PR 3: Refresh The Compatibility Contract

- [ ] regenerate affected checked-in compatibility artifacts
- [ ] update milestone/docs to match the final evidence
- [ ] keep the current promoted parser-only and scanner boundaries stable

Success signal:

- the checked-in contract matches the final measured state without overstating the result

## Progress

- [ ] PR 1 completed
- [ ] PR 2 completed
- [ ] PR 3 completed
- [ ] M41 ready for closeout

## Current Focus

- current stable promoted parser-only boundary:
  - `parse_table_tiny_json`
  - `behavioral_config_json`
  - `tree_sitter_ziggy_json`
  - `tree_sitter_c_json`
- current stable promoted real scanner evidence:
  - `tree_sitter_haskell_json`
  - `tree_sitter_bash_json`
- current real parser-only target with direct external payoff:
  - `tree_sitter_ziggy_schema_json`
- current frozen parser-only control fixture:
  - `parse_table_conflict_json`

## Follow-On Decision

This milestone should not be driven by `repeat_choice_seq_js`, but it should leave the next step clearer than it found it.

At closeout:

- if `tree_sitter_ziggy_schema_json` is promoted, decide whether `repeat_choice_seq_js` is worth a separate narrow follow-up milestone
- if `tree_sitter_ziggy_schema_json` remains deferred, decide whether that same blocker pattern makes `repeat_choice_seq_js` lower priority than broader compatibility work

The important rule is:

- do not let `repeat_choice_seq_js` displace the real external compatibility payoff target for this milestone
