# MILESTONES 34 (Second-Wave Parser-Only Repo Coverage)

This milestone follows [MILESTONES_33.md](./MILESTONES_33.md).

Milestone 33 widened real external evidence and left `tree_sitter_c_json` at an explicit deferred parser boundary. Milestone 34 is about turning that deferred state into a sharper, measurable parser-only proof ladder.

It is not a scanner milestone. It is not a runtime-parity milestone. It is not a broad onboarding milestone.

## Goal

- narrow the deferred parser-boundary surface on `tree_sitter_c_json`
- make the next parser-only proof layer explicit and measurable
- either promote `tree_sitter_c_json` further or keep it explicitly bounded with a tighter rationale
- keep the existing passing staged and real external scanner boundaries stable

## Starting Point

- [x] `tree_sitter_c_json` is onboarded with checked-in provenance
- [x] `tree_sitter_c_json` currently passes `load` and `prepare`
- [x] `tree_sitter_c_json` is explicitly classified as `deferred_for_parser_boundary`
- [x] the current checked-in coverage decision points to `second_wave_parser_only_repo_coverage`

## Scope

In scope:

- profiling the current deferred parser-boundary target precisely
- adding a narrower parser-only proof layer between `prepare_only` and a full promoted pass
- promoting or explicitly rebounding `tree_sitter_c_json` based on that measured surface
- tightening machine-readable parser-boundary artifacts where needed

Out of scope:

- scanner-runtime work
- broad target-count expansion
- CLI productization
- large refactors without direct parser-boundary payoff

## Exit Criteria

- [x] the current deferred parser-boundary target has a dedicated machine-readable profile
- [ ] the next parser-only proof layer after `prepare` is explicit in code and artifacts
- [ ] `tree_sitter_c_json` is either promoted beyond `prepare_only` or remains deferred with a tighter named boundary
- [ ] the checked-in coverage decision and docs reflect the final M34 boundary accurately

## PR-Sized Slices

### PR 1: Profile The Deferred Parser Boundary

- [x] add a dedicated parser-boundary profile artifact for deferred parser-only targets
- [x] record the current proven step ladder and raw grammar-shape metrics for `tree_sitter_c_json`
- [x] keep the profile deterministic and checked in

### PR 2: Add The Next Narrow Parser-Only Proof Layer

- [ ] define one proof layer between `prepare_only` and full promotion
- [ ] thread that mode through the harness and artifacts
- [ ] keep the existing passing targets stable

### PR 3: Promote Or Rebound tree_sitter_c_json

- [ ] either promote `tree_sitter_c_json` beyond the current deferred boundary or keep it deferred with a tighter named rationale
- [ ] regenerate the checked-in artifacts from the resulting state
- [ ] keep clean `zig run update_compat_artifacts.zig` and `zig build test` runs

### PR 4: Closeout

- [ ] update coverage decision and milestone notes from the final checked-in evidence
- [ ] tighten `README.md`, `compatibility-matrix.md`, and `compat_targets/README.md`
- [ ] mark the final M34 parser-only boundary and remaining limitations explicitly

## Progress

- [x] PR 1 completed
- [ ] PR 2 completed
- [ ] PR 3 completed
- [ ] PR 4 completed
- [ ] M34 ready for closeout

## Current Focus

- `tree_sitter_c_json`
  - current proven steps:
    - `load`
    - `prepare`
  - current deferred starting step:
    - `serialize`
  - current deferred classification:
    - `deferred_for_parser_boundary`
  - current mismatch category:
    - `parser_external_boundary_gap`
  - current raw grammar-shape profile:
    - `rule_count = 182`
    - `conflict_count = 17`
    - `extra_count = 2`
    - `supertype_count = 7`
    - `word_token = identifier`
