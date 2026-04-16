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
- the repo is still an in-progress rewrite rather than a drop-in replacement for upstream Tree-sitter

What is still not a first-class top-level product surface:

- emitted `parser.c`
- emitted `grammar.json`
- compatibility reports and real-repo compatibility runs
- full runtime/ABI parity claims against upstream Tree-sitter

## Next Goals

The immediate next goals are:

- promote the newly onboarded real external parser-only snapshots by shrinking their current parser-only gaps
- continue expanding beyond curated local fixtures into parser-only compatibility coverage against additional real grammars/repos
- keep parser-output optimization measurable while deeper parse-table compression/minimization remains future work
- continue tightening the staged compatibility boundary before claiming broader runtime parity

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

- curated fixture proof currently comes from lower-level emitter, golden, compile-smoke, structural-compatibility, and behavioral-harness tests
- parser-only shortlist proof currently comes from the versioned checked-in artifacts under `compat_targets/`:
  - `compat_targets/shortlist.json`
  - `compat_targets/shortlist_inventory.json`
  - `compat_targets/shortlist_report.json`
- `compat_targets/README.md` describes how the shortlist, inventory, mismatch, and coverage-decision artifacts relate to the current staged boundary
- the currently proven first-wave parser-only boundary is still the staged 3-target set:
  - `parse_table_tiny_json`
  - `behavioral_config_json`
  - `repeat_choice_seq_js`
- the shortlist now also includes two real external parser-only snapshots as deferred later-wave targets:
  - `tree_sitter_ziggy_json`
  - `tree_sitter_ziggy_schema_json`
- the top-level `generate` command does not yet expose emitted `parser.c`, emitted `grammar.json`, or compatibility reports as first-class outputs
- the current supported behavioral subset is still staged:
  - `behavioral_config` and `hidden_external_fields` now have compatibility-safe valid-path checks
  - `repeat_choice_seq` still preserves deterministic JSON/JS parity and progress, but it remains on the staged `unresolved_decision` boundary for its valid path
- scanner/external-scanner repo proof is still explicitly deferred beyond the current parser-only boundary
- broader real-grammar coverage is the next planned step, beginning with promotion of the deferred external parser-only snapshots before broader scanner/runtime parity work

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
5. [MILESTONES_20.md](./MILESTONES_20.md) for the current staged compatibility boundary
6. [MILESTONES_21.md](./MILESTONES_21.md) for current optimization/parity follow-on work
7. [MILESTONES_22.md](./MILESTONES_22.md) for the next parser-only real-repo compatibility goal
8. the milestone checklist for the subsystem you care about
