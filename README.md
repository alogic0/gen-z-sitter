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
- unit and golden-test coverage across the pipeline

What this means in practice:

- the repository builds and tests as a Zig project
- the CLI can load grammars and expose debug views
- the top-level generate path is currently most concrete for validation and `node-types.json`
- the parser-emission work exists in the codebase, but this repo is still positioned as an in-progress rewrite rather than a drop-in replacement for upstream Tree-sitter

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
```

Expected current behavior:

- `generate <grammar-path>` validates and loads the grammar, then prints a short summary
- `generate --debug-prepared` prints the prepared grammar IR
- `generate --debug-node-types` prints generated `node-types.json`
- `generate --output <dir>` writes `node-types.json` into the target directory

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

Not every flag currently maps to a fully surfaced end-user feature. The parser and compatibility layers are present in the codebase, but the most directly exercised user-facing paths today are grammar loading, preparation, debug dumps, and `node-types.json` output.

Current staged compatibility boundary:

- parser/runtime compatibility work is exercised primarily through lower-level emitter, golden, compile-smoke, structural-compatibility, and behavioral-harness tests
- the top-level `generate` command does not yet expose emitted `parser.c`, emitted `grammar.json`, or compatibility reports as first-class outputs
- the current supported behavioral subset is still staged:
  - `behavioral_config` and `hidden_external_fields` now have compatibility-safe valid-path checks
  - `repeat_choice_seq` still preserves deterministic JSON/JS parity and progress, but it remains on the staged `unresolved_decision` boundary for its valid path

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
- [prepared-grammar-ir.md](./prepared-grammar-ir.md)
- [parse-table-algorithm-plan.md](./parse-table-algorithm-plan.md)
- [milestone-0-task-list.md](./milestone-0-task-list.md)

## Recommended Reading Order

1. [MASTER_PLAN.md](./MASTER_PLAN.md)
2. [zig-generator-architecture.md](./zig-generator-architecture.md)
3. [compatibility-matrix.md](./compatibility-matrix.md)
4. [test-strategy.md](./test-strategy.md)
5. the milestone checklist for the subsystem you care about
