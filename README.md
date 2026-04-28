# Zig Tree-sitter Generator Rewrite

This repository is a Zig rewrite of the [Tree-sitter](https://github.com/tree-sitter/tree-sitter) generator pipeline. The goal is to reproduce the practical behavior of `tree-sitter generate` while keeping the existing ecosystem contract: load `grammar.json` or `grammar.js`, compute the same core grammar artifacts, and emit parser output that remains compatible with the current C runtime expectations.

The codebase is past the early planning-only stage. It contains a working compiler-style pipeline, parser table and parser C emitters, compatibility fixtures, runtime-link proofs, tests, and a CLI for loading grammars, inspecting prepared IR, and generating `node-types.json`.

## Current Status

What is implemented in the current code:

- grammar loading from `grammar.json`
- `grammar.js` loading through a `node` subprocess path
- validation, normalization, and lowering into prepared grammar IR
- lexer/scanner pipeline modules
- parse-table construction, resolution, serialization, and emitter layers
- `node-types.json` generation
- ABI/compatibility-oriented parser C emission
- serialized runtime parse-action, large/small parse-table, symbol metadata, field, alias, supertype, reserved-word, lex-mode, lexer, keyword-lexer, and external-scanner surfaces
- parser C compatibility helpers, large-lexer compile pragmas, and compact large character-set emission
- emitted-surface optimization and JSON summary reporting for parser tables and parser output
- unit and golden-test coverage across the pipeline

What this means in practice:

- the repository builds and tests as a Zig project
- the CLI can load grammars, expose debug views, write `node-types.json`, write opt-in `parser.c`, and report parser-emission summary stats
- the top-level `generate` path is currently most concrete for validation, debug dumps, `node-types.json`, opt-in `parser.c`, and `--json-summary`
- the parser-emission and compatibility layers are exercised mainly through lower-level tests, compile-smoke checks, structural compatibility checks, and the behavioral harness
- the repo now also carries a versioned parser-only shortlist and a checked-in shortlist boundary artifact under `compat_targets/`
- the repo now also carries a checked-in full shortlist run report under `compat_targets/`
- the repo now also carries a checked-in mismatch inventory and coverage decision under `compat_targets/`
- the repo now also carries a dedicated checked-in external-repo inventory under `compat_targets/`
- the repo now also carries a dedicated checked-in real external scanner inventory under `compat_targets/`
- the repo is still an in-progress rewrite rather than a drop-in replacement for upstream Tree-sitter

What is still not a first-class top-level CLI product surface:

- emitted `grammar.json`
- compatibility reports and real-repo compatibility runs
- full runtime/ABI parity claims against upstream Tree-sitter

## Next Goals

The immediate next goals are:

- keep the fast local test split bounded and predictable
- keep the now-proven parser-only and multi-family staged scanner boundaries explicit and defensible in checked-in compatibility artifacts
- treat `parse_table_conflict_json` as an intentional frozen control fixture rather than a live promotion gap
- broaden compatibility evidence without overstating runtime parity now that a second scanner family is promoted
- reduce parse-table construction memory and time for the remaining heavy real grammars

## Quick Start

Requirements:

- Zig 0.16.x
- `node` available on `PATH` if you want to load `grammar.js`

Common commands:

```bash
zig build
zig build test
zig build test-pipeline
zig build run -- help
zig build run -- generate path/to/grammar.json
zig build run -- generate --debug-prepared path/to/grammar.json
zig build run -- generate --debug-node-types path/to/grammar.json
zig build run -- generate --output out path/to/grammar.json
zig build run -- generate --output out --emit-parser-c path/to/grammar.json
zig build run -- generate --json-summary path/to/grammar.json
zig build run -- generate --json-summary --minimize path/to/grammar.json
zig build run -- generate --output out --emit-parser-c --glr-loop path/to/grammar.json
zig build run -- generate --js-runtime node path/to/grammar.js
```

Bounded test commands:

```bash
zig build test
zig build test-build-config
zig build test-cli-generate
zig build test-pipeline
zig build test-link-runtime
zig build test-compat-heavy
zig build run-minimize-report
```

`test`, `test-build-config`, `test-cli-generate`, and `test-pipeline` are fast local gates. `test-compat-heavy` is intentionally separate because it exercises larger compatibility targets and can take substantially longer.
`run-minimize-report` is a bounded diagnostic command. It prints parse-table minimization counts for the staged safe compatibility targets and lists larger or JS-loader targets that are intentionally skipped from fast minimization probes.

Expected current behavior:

- `generate <grammar-path>` validates and loads the grammar, then prints a short summary
- `generate --debug-prepared` prints the prepared grammar IR
- `generate --debug-node-types` prints generated `node-types.json`
- `generate --output <dir>` writes `node-types.json` into the target directory
- `generate --output <dir> --emit-parser-c` also writes `parser.c`
- `generate --output <dir> --emit-parser-c --glr-loop` writes parser C with the experimental generated GLR loop enabled
- `generate --json-summary` prints emitted-surface and optimization statistics for the current parser-emission pipeline
- `generate --json-summary --minimize` includes minimized parse-table counts in the summary path
- `generate --js-runtime <runtime> path/to/grammar.js` chooses the runtime command used to load `grammar.js`
- `zig build run-minimize-report` prints a deterministic JSON report for the bounded parse-table minimization probe

## CLI

The executable is `gen-z-sitter`.

Usage:

```text
gen-z-sitter help
gen-z-sitter generate [options] <grammar-path>
```

Supported generate options:

- `--output <dir>`
- `--abi <version>`
- `--no-parser`
- `--emit-parser-c`
- `--glr-loop`
- `--json-summary`
- `--debug-prepared`
- `--debug-node-types`
- `--report-states-for-rule <rule>`
- `--js-runtime <runtime>`
- `--no-optimize-merge-states`
- `--minimize`
- `--strict-expected-conflicts`

`--abi` currently accepts only ABI 15. `--js-runtime` defaults to `node`.

Not every flag currently maps to a fully surfaced end-user feature. The most directly exercised user-facing paths today are grammar loading, preparation, debug dumps, `node-types.json`, opt-in `parser.c`, and `--json-summary`. Some options exist to preserve the eventual generator contract or to drive lower-level emitter and compatibility paths that are more heavily exercised in tests than in the top-level CLI.

Current staged compatibility boundary:

- Proof layers are staged, not all equivalent:
  - curated fixture proof: lower-level emitter, golden, compile-smoke, structural-compatibility, runtime-link, and behavioral tests
  - parser-only shortlist proof: versioned checked-in artifacts under `compat_targets/`
  - staged scanner-boundary proof: promoted scanner-wave entries in the checked-in compatibility artifacts
  - real external scanner proof: focused Haskell and Bash runtime-link fixtures, not corpus-level runtime equivalence
- The main machine-readable compatibility surfaces are:
  - `compat_targets/shortlist.json`
  - `compat_targets/shortlist_inventory.json`
  - `compat_targets/shortlist_report.json`
  - `compat_targets/external_repo_inventory.json`
  - `compat_targets/external_scanner_repo_inventory.json`
  - `compat_targets/artifact_manifest.json`
- The current parser-only boundary includes staged fixtures plus promoted real C and Zig JSON coverage. `parse_table_conflict_json` remains an intentional frozen control fixture for an ambiguity that requires precedence/conflict annotations.
- The current scanner boundary includes staged scanner fixtures and focused real external scanner runtime-link proofs for `tree_sitter_haskell_json` and `tree_sitter_bash_json`. These are link-and-run proofs against scanner.c, not corpus-level runtime parity.
- Routine compatibility artifacts are refreshed by `zig run update_compat_artifacts.zig`. Heavier parser-boundary probing is kept separate in `zig run update_parser_boundary_probe.zig`.
- The top-level `generate` command now exposes opt-in emitted `parser.c`, but emitted `grammar.json` and compatibility reports are not first-class outputs yet.

The current heavy compatibility path is bounded and separated from the fast default tests. It is useful before broader compatibility changes, but it is not required for every small local edit.

## Known Limits

- `parser.c` output is available with `--emit-parser-c`, but the project still does not claim full upstream `tree-sitter generate` parity.
- External scanner grammars have focused runtime-link proofs for promoted targets, not broad corpus-level runtime equivalence.
- The generated GLR loop is experimental and opt-in with `--glr-loop`.
- Generated tree output exists for focused generated-runtime proofs, but the CLI does not yet expose a stable public tree API.
- Large real grammars stay behind bounded compatibility and profiling commands. Do not run broad compatibility probes without explicit timeouts.
- Emitted `grammar.json` and compatibility reports are still produced through internal artifacts and update scripts, not a stable `generate` output.

## Artifact Updates

Use bounded commands when refreshing generated or compatibility artifacts:

```bash
zig build test
zig build test-pipeline
zig run update_compat_artifacts.zig
zig run update_parser_boundary_probe.zig
```

`update_compat_artifacts.zig` refreshes the routine checked-in compatibility surfaces. `update_parser_boundary_probe.zig` is the heavier parser-boundary probe and should be run separately when parser-boundary evidence changes.

## Repository Layout

```text
docs/
  plans/                   roadmap and rewrite plans
  milestones/              historical milestone checklists and closeouts
  audits/                  gap audits and compatibility matrix
  architecture/            architecture notes
src/
  main.zig                 process entry point
  *_test_entry.zig         Zig test entry points kept in src for module-boundary reasons
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
compat_targets/            checked-in compatibility fixtures and reports
tools/                     small local debugging utilities
update_compat_artifacts.zig
update_parser_boundary_probe.zig
                           root-level update scripts kept runnable with `zig run`
```

## Key Documents

Start here:

- [MASTER_PLAN.md](./docs/plans/MASTER_PLAN.md): primary roadmap and project framing
- [zig-generator-architecture.md](./docs/architecture/zig-generator-architecture.md): architecture notes
- [compatibility-matrix.md](./docs/audits/compatibility-matrix.md): compatibility targets and gaps
- [test-strategy.md](./docs/plans/test-strategy.md): testing approach
- [GAPS_260425.md](./docs/audits/GAPS_260425.md): current known implementation gaps

Implementation history and milestone tracking:

- [MILESTONE_1_IMPLEMENTATION_CHECKLIST.md](./docs/milestones/MILESTONE_1_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_2_IMPLEMENTATION_CHECKLIST.md](./docs/milestones/MILESTONE_2_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_3_IMPLEMENTATION_CHECKLIST.md](./docs/milestones/MILESTONE_3_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_4_IMPLEMENTATION_CHECKLIST.md](./docs/milestones/MILESTONE_4_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_5_IMPLEMENTATION_CHECKLIST.md](./docs/milestones/MILESTONE_5_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_6_IMPLEMENTATION_CHECKLIST.md](./docs/milestones/MILESTONE_6_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_7_IMPLEMENTATION_CHECKLIST.md](./docs/milestones/MILESTONE_7_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_8_IMPLEMENTATION_CHECKLIST.md](./docs/milestones/MILESTONE_8_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_9_IMPLEMENTATION_CHECKLIST.md](./docs/milestones/MILESTONE_9_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_10_IMPLEMENTATION_CHECKLIST.md](./docs/milestones/MILESTONE_10_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_11_IMPLEMENTATION_CHECKLIST.md](./docs/milestones/MILESTONE_11_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_12_IMPLEMENTATION_CHECKLIST.md](./docs/milestones/MILESTONE_12_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_13_IMPLEMENTATION_CHECKLIST.md](./docs/milestones/MILESTONE_13_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_15_IMPLEMENTATION_CHECKLIST.md](./docs/milestones/MILESTONE_15_IMPLEMENTATION_CHECKLIST.md)

Focused supporting notes:

- [MASTER_PLAN_2.md](./docs/plans/MASTER_PLAN_2.md)
- [MILESTONES_16.md](./docs/milestones/MILESTONES_16.md)
- [MILESTONES_17.md](./docs/milestones/MILESTONES_17.md)
- [MILESTONES_18.md](./docs/milestones/MILESTONES_18.md)
- [MILESTONES_19.md](./docs/milestones/MILESTONES_19.md)
- [MILESTONES_20.md](./docs/milestones/MILESTONES_20.md)
- [MILESTONES_21.md](./docs/milestones/MILESTONES_21.md)
- [MILESTONES_22.md](./docs/milestones/MILESTONES_22.md)
- [prepared-grammar-ir.md](./docs/plans/prepared-grammar-ir.md)
- [parse-table-algorithm-plan.md](./docs/plans/parse-table-algorithm-plan.md)
- [milestone-0-task-list.md](./docs/milestones/milestone-0-task-list.md)

## Recommended Reading Order

1. [MASTER_PLAN.md](./docs/plans/MASTER_PLAN.md)
2. [zig-generator-architecture.md](./docs/architecture/zig-generator-architecture.md)
3. [compatibility-matrix.md](./docs/audits/compatibility-matrix.md)
4. [test-strategy.md](./docs/plans/test-strategy.md)
5. [MILESTONES_23.md](./docs/milestones/MILESTONES_23.md) for the expanded parser-only proven boundary
6. [MILESTONES_26.md](./docs/milestones/MILESTONES_26.md) for the current second-wave scanner boundary and closeout state
7. [MILESTONES_24.md](./docs/milestones/MILESTONES_24.md) for broader compatibility polish background
8. [MILESTONES_21.md](./docs/milestones/MILESTONES_21.md) for current optimization/parity follow-on work
9. the milestone checklist for the subsystem you care about
