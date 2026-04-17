# MILESTONES 38 (Routine Parser Boundary Follow-Up)

This milestone follows [MILESTONES_37.md](./MILESTONES_37.md).

Milestone 37 closed by making the standalone coarse parser proof for `tree_sitter_c_json` visible in the main compatibility surfaces. The next useful step is not broader polish again. It is a narrow follow-up on whether that standalone proof can justify any credible movement toward the routine shortlist boundary.

It is not a scanner milestone. It is not a broad onboarding milestone. It is not a runtime-parity milestone.

## Goal

- revisit `tree_sitter_c_json` with a narrow routine-boundary promotion hypothesis
- determine whether any part of the current standalone coarse `serialize_only` proof can be translated into a stable routine compatibility claim
- either promote the routine parser boundary one step or keep the current split with a tighter explicit rationale
- keep the current promoted parser-only and scanner boundaries stable

## Starting Point

- [x] `tree_sitter_c_json` started as the only deferred parser-wave target
- [x] the routine shortlist initially kept `tree_sitter_c_json` at `prepare_only`
- [x] `tree_sitter_c_json` now carries `standalone_parser_proof_scope = coarse_serialize_only` in the main compatibility artifacts
- [x] the standalone coarse `serialize_only` probe passes with `serialized_state_count = 2336`
- [x] the current coverage decision still recommends parser-only follow-up work rather than broader scanner expansion

## Scope

In scope:

- evaluating one narrow routine-boundary promotion hypothesis for `tree_sitter_c_json`
- tightening parser-boundary reporting if the standalone/routine split remains unchanged
- preserving clean `zig run update_compat_artifacts.zig` and `zig build test` runs
- keeping the current promoted parser-only and scanner evidence sets unchanged unless a very small adjustment is justified directly by this work

Out of scope:

- broad new parser-wave onboarding
- scanner or runtime feature expansion
- runtime parity claims
- large parse-table refactors without direct payoff on the deferred C target

## Exit Criteria

- [x] the next routine-boundary promotion hypothesis for `tree_sitter_c_json` is explicit and measured
- [x] `tree_sitter_c_json` is either promoted one routine step further or kept deferred with a tighter rationale than M37
- [x] the checked-in compatibility artifacts reflect the final routine-versus-standalone parser-proof split accurately
- [x] the milestone closes with clean `zig run update_compat_artifacts.zig` and `zig build test`

## PR-Sized Slices

### PR 1: Define The Routine-Boundary Hypothesis

- [x] define one narrow routine-boundary promotion hypothesis for `tree_sitter_c_json`
- [x] measure it against the existing shortlist/probe split
- [x] keep the current routine refresh path stable unless the hypothesis proves cheap enough

### PR 2: Implement Or Bound The Hypothesis

- [x] implement the narrower routine-boundary step if it is credible
- [x] otherwise, make the blocking reason more explicit in code and artifacts
- [x] avoid broadening the parser-wave set

### PR 3: Promote Or Tighten The Deferred Split

- [x] either promote `tree_sitter_c_json` one routine step beyond `prepare_only` or keep it deferred with a tighter explicit routine-boundary rationale
- [x] regenerate all affected checked-in artifacts
- [x] keep standalone coarse proof and routine proof clearly distinguished

### PR 4: Closeout

- [x] update milestone notes, coverage decision, and repo docs from the final checked-in evidence
- [x] mark the final M38 parser-boundary state explicitly
- [x] keep the next-step recommendation narrow and honest

## Progress

- [x] PR 1 completed
- [x] PR 2 completed
- [x] PR 3 completed
- [x] PR 4 completed
- [x] M38 ready for closeout

## Current Focus

- stable routine shortlist proof:
  - 6 intended first-wave parser-only targets pass
  - 6 intended scanner-wave targets pass
- stable standalone proof:
  - `tree_sitter_c_json` has a passing standalone coarse `serialize_only` proof
  - that proof is still visible in the main compatibility surfaces even after the routine promotion
- current M38 question:
  - is there a smaller routine-boundary step between `prepare_only` and a broader parser-surface claim that can stay cheap, honest, and stable in the routine shortlist?
- current PR 1 outcome:
  - `parser_boundary_hypothesis.json` now makes the routine-boundary answer explicit:
    - `routine_boundary_hypothesis = no_safe_routine_step_yet`
    - `routine_refresh_candidate_mode = null`
    - `measured_standalone_serialized_state_count = 2336`
  - current measured conclusion:
    - the standalone coarse `serialize_only` proof remains useful evidence
    - it still does not identify a routine-safe next parser-boundary step for the shortlist
- current PR 2 outcome:
  - the deferred C blocker is now described more narrowly in code and artifacts
  - current routine blocker:
    - `mismatch_category = routine_serialize_proof_boundary`
  - current meaning:
    - the real remaining blocker is not a vague parser proof gap
    - it is specifically the lack of a routine-safe lookahead-sensitive serialize step, while only the standalone coarse serialize probe passes
- current PR 3 outcome:
  - `tree_sitter_c_json` is now promoted one routine step further:
    - routine shortlist now proves `load`, `prepare`, coarse `serialize_only`, parser-table emission, C-table emission, parser.c emission, compatibility validation, and compile-smoke
  - current meaning:
    - the routine shortlist no longer stops at serialize or any emitted-surface step for this target
    - the target is fully promoted into the routine parser-only boundary

## Closeout

M38 closed by fully promoting `tree_sitter_c_json` into the routine first-wave parser-only boundary.

- final routine C result:
  - `load` passes
  - `prepare` passes
  - routine coarse `serialize_only` passes
  - `emit_parser_tables` passes
  - `emit_c_tables` passes
  - `emit_parser_c` passes
  - `compat_check` passes
  - `compile_smoke` passes
- final classification:
  - `tree_sitter_c_json` is now `passed_within_current_boundary`
  - it is no longer a deferred parser-wave target
- resulting parser-only boundary:
  - 6 intended first-wave parser-only targets now pass in the routine shortlist
  - the only remaining deferred parser-only target is the intentional frozen control fixture `parse_table_conflict_json`
- standalone probe outcome:
  - the coarse standalone `serialize_only` proof remains checked in as narrower supporting evidence
  - it is no longer the primary boundary for `tree_sitter_c_json`
- next-step recommendation:
  - the checked-in coverage decision now returns to `broader_compatibility_polish`
  - the repo no longer has an active deferred parser-wave singleton
