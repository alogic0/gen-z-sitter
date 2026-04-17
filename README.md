# Zig Tree-sitter Generator Rewrite

This repository is a Zig rewrite of the Tree-sitter generator pipeline. The goal is to reproduce the practical behavior of `tree-sitter generate` while keeping the existing ecosystem contract: load `grammar.json` or `grammar.js`, compute the same core grammar artifacts, and eventually emit parser output that remains compatible with the current C runtime expectations.

The codebase is past the early planning-only stage. It contains a working compiler-style pipeline, tests, and a CLI for loading grammars, inspecting prepared IR, and generating `node-types.json`. It also contains a large set of milestone and architecture documents that track the broader rewrite plan.

## Current Status

What is implemented in the current code:

- grammar loading from `grammar.json`
- `grammar.js` loading through a `node` subprocess path
- validation, normalization, and lowering into prepared grammar IR
- lexer/scanner pipeline modules
- parse-table construction, resolution, serialization, and emitter layers
- `node-types.json` generation
- ABI/compatibility-oriented parser emission modules
- emitted-surface optimization and JSON summary reporting for parser tables and parser output
- unit and golden-test coverage across the pipeline

What this means in practice:

- the repository builds and tests as a Zig project
- the CLI can load grammars, expose debug views, write `node-types.json`, and report parser-emission summary stats
- the top-level `generate` path is currently most concrete for validation, debug dumps, `node-types.json`, and `--json-summary`
- the parser-emission and compatibility layers are exercised mainly through lower-level tests, compile-smoke checks, structural compatibility checks, and the behavioral harness
- the repo now also carries a versioned parser-only shortlist and a checked-in shortlist boundary artifact under `compat_targets/`
- the repo now also carries a checked-in full shortlist run report under `compat_targets/`
- the repo now also carries a checked-in mismatch inventory and coverage decision under `compat_targets/`
- the repo now also carries a dedicated checked-in external-repo inventory under `compat_targets/`
- the repo now also carries a dedicated checked-in real external scanner inventory under `compat_targets/`
- the repo is still an in-progress rewrite rather than a drop-in replacement for upstream Tree-sitter

What is still not a first-class top-level product surface:

- emitted `parser.c`
- emitted `grammar.json`
- compatibility reports and real-repo compatibility runs
- full runtime/ABI parity claims against upstream Tree-sitter

## Next Goals

The immediate next goals are:

- keep the now-proven parser-only and multi-family staged scanner boundaries explicit and defensible in checked-in compatibility artifacts
- treat `parse_table_conflict_json` as an intentional frozen control fixture rather than a live promotion gap
- broaden compatibility evidence without overstating runtime parity now that a second scanner family is promoted
- keep parser-output optimization measurable while deeper parse-table compression/minimization remains future work

## Quick Start

Requirements:

- Zig 0.15.x
- `node` available on `PATH` if you want to load `grammar.js`

Common commands:

```bash
zig build
zig build test
zig build run -- help
zig build run -- generate path/to/grammar.json
zig build run -- generate --debug-prepared path/to/grammar.json
zig build run -- generate --debug-node-types path/to/grammar.json
zig build run -- generate --output out path/to/grammar.json
zig build run -- generate --json-summary path/to/grammar.json
```

Expected current behavior:

- `generate <grammar-path>` validates and loads the grammar, then prints a short summary
- `generate --debug-prepared` prints the prepared grammar IR
- `generate --debug-node-types` prints generated `node-types.json`
- `generate --output <dir>` writes `node-types.json` into the target directory
- `generate --json-summary` prints emitted-surface and optimization statistics for the current parser-emission pipeline

## CLI

The executable is `zig-tree-sit`.

Usage:

```text
zig-tree-sit help
zig-tree-sit generate [options] <grammar-path>
```

Supported generate options:

- `--output <dir>`
- `--abi <version>`
- `--no-parser`
- `--json-summary`
- `--debug-prepared`
- `--debug-node-types`
- `--report-states-for-rule <rule>`
- `--js-runtime <runtime>`
- `--no-optimize-merge-states`

Not every flag currently maps to a fully surfaced end-user feature. The most directly exercised user-facing paths today are grammar loading, preparation, debug dumps, `node-types.json` output, and `--json-summary`. Some options exist to preserve the eventual generator contract or to drive lower-level emitter and compatibility paths that are more heavily exercised in tests than in the top-level CLI.

Current staged compatibility boundary:

- proof layers are currently staged, not all equivalent:
  - curated fixture proof:
    - lower-level emitter, golden, compile-smoke, structural-compatibility, and behavioral-harness tests
  - parser-only shortlist proof:
    - versioned checked-in artifacts under `compat_targets/`
  - staged scanner-boundary proof:
    - the promoted scanner-wave entries in the same checked-in compatibility artifacts
- parser-only shortlist proof currently comes from the versioned checked-in artifacts under `compat_targets/`:
- real external snapshot proof is also exposed separately under `compat_targets/`:
  - `compat_targets/external_repo_inventory.json`
  - this keeps the promoted real external parser-only evidence visible without mixing it into staged fixture-only summaries
  - it now records the current mixed real-evidence state explicitly: 2 passing external parser-only snapshots, 1 deferred external parser-only snapshot, and 2 passing sampled real external scanner snapshots
- real external scanner proof is now exposed separately under `compat_targets/`:
  - `compat_targets/external_scanner_repo_inventory.json`
  - it now records two passing real external scanner targets: `tree_sitter_haskell_json` and `tree_sitter_bash_json`
  - it now also records machine-readable `proof_scope` values so the narrower sampled scanner claims are visible without relying only on prose notes
  - the Haskell target currently passes within a sampled external-sequence boundary, not full scanner.c runtime equivalence
  - the Bash target now passes a narrow sampled expansion path built around `_bare_dollar` and `variable_name`, not broader heredoc handling or full scanner.c runtime equivalence
  - the currently checked-out `tree-sitter-c` and `tree-sitter-zig` repos still do not change that scanner story, because their available snapshots have `externals: []` and no scanner implementation files
- parser-only shortlist proof currently comes from the versioned checked-in artifacts under `compat_targets/`:
  - `compat_targets/shortlist.json`
  - `compat_targets/shortlist_inventory.json`
  - `compat_targets/shortlist_report.json`
- `compat_targets/README.md` describes how the shortlist, inventory, mismatch, and coverage-decision artifacts relate to the current staged boundary
- `compat_targets/README.md` also describes how `external_repo_inventory.json` and `external_scanner_repo_inventory.json` separate real external evidence from the staged fixture-driven shortlist surfaces
- the shortlist inventory and full report now expose family-level coverage so the current staged boundary is readable by grammar family, not only by flat target counts
- the currently represented parser-only families are:
  - `parse_table_tiny`
  - `behavioral_config`
  - `repeat_choice_seq`
  - `ziggy`
  - `ziggy_schema`
  - `c`
  - `parse_table_conflict`
- the currently proven first-wave parser-only boundary is a 5-target set across 5 passing parser-only families:
  - `parse_table_tiny_json`
  - `behavioral_config_json`
  - `repeat_choice_seq_js`
  - `tree_sitter_ziggy_json`
  - `tree_sitter_ziggy_schema_json`
- the shortlist now carries one intentionally deferred parser-only control fixture:
  - `parse_table_conflict_json`
  - it remains blocked on purpose as a known ambiguity boundary without precedence annotations
  - the checked-in reports now classify it explicitly as a `frozen_control_fixture` rather than counting it as a normal staged pass
- the real external parser-only evidence also now includes one explicitly deferred larger parser-only target:
  - `tree_sitter_c_json`
  - it currently proves `load` and `prepare`
  - it is intentionally classified as `deferred_for_parser_boundary` with `parser_proof_boundary` rather than being overstated as a promoted full-pipeline pass
  - the current stable shortlist does not yet claim emitted parser surfaces, compatibility checks, or compile-smoke for that grammar
- the currently represented scanner/external-scanner families are:
  - `hidden_external_fields`
  - `mixed_semantics`
  - `haskell`
  - `bash`
- the shortlist now also carries a promoted multi-family scanner wave with explicit family-level coverage in the checked-in artifacts:
  - `hidden_external_fields_json`
  - `hidden_external_fields_js`
  - `mixed_semantics_json`
  - `mixed_semantics_js`
  - `tree_sitter_haskell_json`
  - `tree_sitter_bash_json`
  - together they currently prove load, prepare, and one of:
    - staged compatibility-safe valid-path behavior with weaker invalid-path progress
    - sampled real external scanner proof for the real external Haskell and Bash snapshots
  - `mixed_semantics` specifically keeps extras elsewhere in the grammar while proving a narrower first-boundary path that does not depend on them
- the top-level `generate` command does not yet expose emitted `parser.c`, emitted `grammar.json`, or compatibility reports as first-class outputs
- routine compatibility artifacts are now indexed machine-readably in `compat_targets/artifact_manifest.json`
  - routine refreshes come from `update_compat_artifacts.zig`
  - heavier deferred parser-boundary probing remains separate in `update_parser_boundary_probe.zig`
- the current coverage decision also now makes the deferred parser-wave singleton explicit:
  - `tree_sitter_c_json` is the only active deferred parser-wave target
  - the current low-risk boundary decision is to keep that singleton unchanged unless a narrower promotion hypothesis appears
- the current narrower promotion hypothesis for that target is now also machine-readable in `compat_targets/parser_boundary_hypothesis.json`
  - the routine shortlist remains at `prepare_only`
  - the next named proof step remains `serialize_only`
  - that next step is currently scoped to standalone probe tooling rather than the routine refresh path
  - the current standalone probe result in `compat_targets/parser_boundary_probe.json` now shows that a coarse `serialize_only` parser proof passes for `tree_sitter_c_json`
  - that standalone proof uses lookahead-insensitive closure expansion and currently serializes `2336` states with `blocked = false`
  - it is still intentionally narrower than a full lookahead-sensitive parser proof and does not yet promote the routine shortlist boundary
  - `compat_targets/parser_boundary_hypothesis.json` and `compat_targets/coverage_decision.json` now also encode that standalone coarse proof machine-readably while keeping the routine shortlist boundary at `prepare_only`
- the current supported behavioral subset is still staged:
  - `behavioral_config` and `hidden_external_fields` now have compatibility-safe valid-path checks
  - `hidden_external_fields` also proves that the invalid path makes less progress than the valid path through the first staged scanner boundary
  - `repeat_choice_seq` still preserves deterministic JSON/JS parity and progress, but it now rejects on the staged blocked path as `missing_action` rather than advancing into a promoted parser-only pass
- scanner/external-scanner proof is staged as a narrow promoted multi-family wave rather than left entirely out of the shortlist
- real external scanner evidence is now no longer empty, and it now includes two passing sampled real external scanner snapshots
- that real external scanner boundary is now explicit:
  - structural first-boundary extraction remains the lower proof layer
  - sampled external-sequence proof now passes for `tree_sitter_haskell_json`
  - sampled expansion-path proof now passes for `tree_sitter_bash_json`
  - the Bash proof is intentionally narrower than Haskell’s and does not yet claim sampled heredoc behavior
  - full runtime scanner equivalence is still out of scope
- the key distinction is:
  - staged scanner proof lives in the shortlist artifacts and covers promoted in-repo scanner families
  - real external scanner proof lives in `external_scanner_repo_inventory.json` and covers the promoted Haskell and Bash snapshots
- the current checked-in coverage decision now points to second-wave parser-only repo coverage so the larger deferred `tree_sitter_c_json` snapshot can either be promoted or remain explicitly bounded

## Repository Layout

```text
src/
  main.zig                 process entry point
  cli/                     argument parsing and command dispatch
  grammar/                 loading, validation, normalization, preparation
  ir/                      core grammar and symbol IR
  lexer/                   lexer pipeline and serialization
  scanner/                 external scanner pipeline and serialization
  parse_table/             item/state/action building and serialization
  parser_emit/             parser.c-oriented emission and compatibility helpers
  node_types/              node-types computation and JSON rendering
  support/                 generic helpers
  tests/                   fixtures and golden helpers
  behavioral/              behavioral harness support
```

## Key Documents

Start here:

- [MASTER_PLAN.md](./MASTER_PLAN.md): primary roadmap and project framing
- [zig-generator-architecture.md](./zig-generator-architecture.md): architecture notes
- [compatibility-matrix.md](./compatibility-matrix.md): compatibility targets and gaps
- [test-strategy.md](./test-strategy.md): testing approach

Implementation history and milestone tracking:

- [MILESTONE_1_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_1_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_2_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_2_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_3_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_3_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_4_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_4_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_5_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_5_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_6_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_6_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_7_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_7_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_8_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_8_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_9_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_9_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_10_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_10_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_11_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_11_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_12_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_12_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_13_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_13_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_15_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_15_IMPLEMENTATION_CHECKLIST.md)

Focused supporting notes:

- [MASTER_PLAN_2.md](./MASTER_PLAN_2.md)
- [MILESTONES_16.md](./MILESTONES_16.md)
- [MILESTONES_17.md](./MILESTONES_17.md)
- [MILESTONES_18.md](./MILESTONES_18.md)
- [MILESTONES_19.md](./MILESTONES_19.md)
- [MILESTONES_20.md](./MILESTONES_20.md)
- [MILESTONES_21.md](./MILESTONES_21.md)
- [MILESTONES_22.md](./MILESTONES_22.md)
- [prepared-grammar-ir.md](./prepared-grammar-ir.md)
- [parse-table-algorithm-plan.md](./parse-table-algorithm-plan.md)
- [milestone-0-task-list.md](./milestone-0-task-list.md)

## Recommended Reading Order

1. [MASTER_PLAN.md](./MASTER_PLAN.md)
2. [zig-generator-architecture.md](./zig-generator-architecture.md)
3. [compatibility-matrix.md](./compatibility-matrix.md)
4. [test-strategy.md](./test-strategy.md)
5. [MILESTONES_23.md](./MILESTONES_23.md) for the expanded parser-only proven boundary
6. [MILESTONES_26.md](./MILESTONES_26.md) for the current second-wave scanner boundary and closeout state
7. [MILESTONES_24.md](./MILESTONES_24.md) for broader compatibility polish background
8. [MILESTONES_21.md](./MILESTONES_21.md) for current optimization/parity follow-on work
9. the milestone checklist for the subsystem you care about
