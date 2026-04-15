# Master Plan: Zig Tree-sitter Generator Rewrite

## Purpose

This document consolidates the planning work for rewriting `tree-sitter generate` in Zig.

It replaces the need to read multiple separate planning documents in sequence. The supporting documents still exist, but this file is the primary plan.

## Goal

Reimplement `tree-sitter generate` in Zig while preserving the current Tree-sitter ecosystem contract:

- inputs remain `grammar.js` and `grammar.json`
- outputs remain `src/parser.c`, `src/grammar.json`, and `src/node-types.json`
- generated parsers remain compatible with the existing C runtime ABI
- invalid grammars fail in the same cases or close enough to avoid breakage
- generated parser behavior matches the current Rust generator

This is a compiler rewrite, not a source-to-source port.

## Non-Goals

- replacing the Tree-sitter C runtime
- changing the generated parser artifact from C to Zig
- redesigning the grammar DSL
- achieving full CLI parity before generator correctness
- embedding a JS engine in the first implementation

## Current Project State

The Zig project scaffold already exists in this directory and passes:

- `zig build`
- `zig build test`

Milestone 0 is effectively complete: build system, CLI skeleton, diagnostics, helper modules, and basic tests are wired.

## Top-Level Strategy

Build the Zig generator in explicit stages:

1. load source grammar
2. decode raw grammar
3. normalize and validate grammar
4. lower to prepared IR
5. build lexical structures
6. build parse tables
7. compute node-type metadata
8. render output artifacts
9. verify compatibility and equivalence

The rewrite should preserve external behavior first and optimize later.

## Architecture

### Module layout

```text
src/
  main.zig
  cli/
    args.zig
    command_generate.zig
  support/
    diag.zig
    fs.zig
    json.zig
    process.zig
    strings.zig
  grammar/
    loader.zig
    json_loader.zig
    js_loader.zig
    raw_grammar.zig
    parse_grammar.zig
    validate.zig
    normalize.zig
    prepare/
  ir/
    symbols.zig
    rules.zig
    grammar_ir.zig
    lexical_grammar.zig
    syntax_grammar.zig
    aliases.zig
    precedence.zig
    variable_info.zig
  lex/
    nfa.zig
    char_set.zig
    token_conflicts.zig
    lex_table.zig
  parse_table/
    item.zig
    item_set_builder.zig
    build_parse_table.zig
    minimize_parse_table.zig
    conflicts.zig
    reductions.zig
  node_types/
    compute.zig
    render_json.zig
  render/
    render_c.zig
    render_grammar_json.zig
    templates.zig
    escaping.zig
  report/
    states.zig
    conflicts_json.zig
  compat/
    abi.zig
    output_compare.zig
  tests/
    fixtures.zig
    golden.zig
    integration_generate.zig
```

### Boundary rules

- `main.zig` owns process entry and dispatch only
- `cli/` owns argument parsing and command orchestration only
- `support/` contains generic helpers, never grammar logic
- `grammar/` owns schema loading, validation, normalization, and preparation
- `ir/` owns the canonical semantic model used by later stages
- `lex/` owns lexical automata and token conflict generation
- `parse_table/` owns syntax table generation and minimization
- `node_types/` owns `node-types.json` semantics
- `render/` consumes computed structures and emits files; it should not perform algorithmic generation
- `report/` owns human-readable and machine-readable reporting
- `compat/` isolates compatibility-specific behavior and hacks

## External Contract

The Zig generator must preserve these visible behaviors:

- accept `grammar.js` or `grammar.json`
- emit `grammar.json` when starting from `grammar.js`
- emit `node-types.json`
- emit `parser.c` unless `--no-parser` is used
- support ABI version selection
- support report/state dumping
- reject invalid grammars in the same broad cases as the Rust generator

The compatibility target is current observable behavior, not internal Rust structure.

## Compatibility Model

Use four compatibility levels:

- `Exact`: byte-for-byte or textually identical
- `Stable`: semantically identical and deterministic
- `Equivalent`: runtime behavior matches
- `Deferred`: acceptable to differ early

### Compatibility targets by area

| Area | Target |
|---|---|
| `grammar.json` loading | Exact |
| `grammar.js` loading via Node | Stable |
| ABI option semantics | Exact |
| `--no-parser` behavior | Exact |
| `src/grammar.json` | Stable |
| `src/node-types.json` | Stable |
| `src/parser.c` | Equivalent |
| grammar rejection behavior | Equivalent |
| parse-tree behavior on corpus inputs | Equivalent |
| diagnostic wording | Deferred |

### Determinism requirements

The Zig generator must be deterministic:

- symbol ordering must never depend on hash iteration
- JSON key ordering must be stable
- C output ordering must be stable
- report output ordering must be stable

## Core IR Boundary

The most important semantic boundary is `PreparedGrammar`.

Its purpose is to:

- remove raw input quirks
- resolve names to stable symbol IDs
- normalize metadata and rule structure
- provide a clean input to lexing and parse-table generation

### Core types

```zig
pub const SymbolId = enum(u32) { _ };

pub const SymbolKind = enum {
    terminal,
    non_terminal,
    external,
    auxiliary,
    anonymous,
    supertype,
};

pub const RuleId = enum(u32) { _ };

pub const Assoc = enum {
    none,
    left,
    right,
};
```

### Prepared grammar shape

```zig
pub const PreparedGrammar = struct {
    grammar_name: []const u8,
    variables: []Variable,
    rules: []Rule,
    symbols: []SymbolInfo,
    external_tokens: []SymbolId,
    extra_symbols: []SymbolId,
    expected_conflicts: []ConflictSet,
    precedence_orderings: []PrecedenceOrdering,
    variables_to_inline: []SymbolId,
    supertype_symbols: []SymbolId,
    reserved_word_sets: []ReservedWordSet,
    word_token: ?SymbolId,
};
```

### Invariants before later stages

- all symbol references are resolved
- all variable rules point to valid `RuleId`
- duplicate symbol/state conflicts are normalized away where required
- inline and supertype targets exist
- conflict sets are canonicalized
- `word_token`, if present, is valid

### Preparation pass order

1. decode raw grammar
2. intern symbol names
3. assign initial symbol kinds
4. resolve rule references
5. normalize metadata wrappers
6. flatten nested choices/sequences where appropriate
7. expand repeats into auxiliary forms
8. extract token and external-token information
9. compute inline/supertype/default alias data
10. validate invariants

## Parse-Table Plan

This is the highest-risk subsystem. Do not attempt final optimized tables immediately.

Build it in four stages:

### Stage 1: Canonical item builder

Deliver:

- production expansion
- closure computation
- goto computation
- stable item ordering

### Stage 2: Transition and reduction construction

Deliver:

- per-state transitions
- reductions
- terminal vs non-terminal split
- accept-state handling

### Stage 3: Conflict classification

Deliver:

- shift/reduce classification
- reduce/reduce classification
- precedence/associativity integration
- expected conflict handling
- conflict reporting structures

### Stage 4: Minimization and refinement

Deliver:

- state equivalence checks
- optional merge-states optimization
- compact final action representation

### Parse-table debugging order

When Zig diverges from Rust, debug in this order:

1. prepared grammar
2. productions
3. item closure
4. state transitions
5. candidate reductions
6. conflict resolution decisions
7. minimized final table

Never start with `parser.c` diffs unless the intermediate structures already match.

## Rendering Plan

Rendering should happen after all semantic structures are complete.

Artifacts:

- `src/grammar.json`
- `src/node-types.json`
- `src/parser.c`
- optional report JSON / state dump output

Rules:

- no algorithmic generation logic in the renderer
- all ordering must be explicit and deterministic
- ABI/version values must come from a single compatibility module

## JS Loading Plan

Do not embed JS first.

### Initial policy

- support `grammar.json` natively first
- support `grammar.js` later by spawning `node`
- defer `bun`, `deno`, and embedded QuickJS

This avoids turning Milestone 1 into a JS runtime project.

## Testing Strategy

Use five test layers:

1. unit tests
2. snapshot tests
3. fixture integration tests
4. semantic equivalence tests
5. determinism tests

### Unit tests

Use for:

- JSON decode helpers
- symbol interning
- normalization passes
- repeat expansion
- lexical helpers
- item closure / goto logic
- rendering escapes

### Snapshot tests

Use for small grammars and intermediate structures:

- prepared symbol tables
- normalized rules
- lexical grammar dumps
- item sets
- conflict summaries

### Fixture integration tests

Run against real Tree-sitter fixture grammars and assert:

- success or failure classification
- expected artifacts
- diagnostic class

### Semantic equivalence tests

For curated grammars:

- generate with Rust
- generate with Zig
- compile both parsers
- parse the same corpus inputs
- compare parse-tree behavior

### Determinism tests

Run the Zig generator repeatedly on the same input and assert identical output files and reports.

## Output Comparison Methods

Use three comparison methods:

### Canonical JSON compare

For:

- `grammar.json`
- `node-types.json`
- JSON reports

Method:

- parse JSON
- sort keys
- compare values

### Text compare

For:

- selected `parser.c` outputs
- compact dumps
- selected diagnostics

### Behavioral compare

For:

- parser semantics

Method:

- compile generated parser
- run corpus parses
- compare parse trees and failure modes

## Milestones

### Milestone 0: Scaffold

Status:

- complete

Deliverables:

- `build.zig`
- `build.zig.zon`
- executable entry point
- `generate` subcommand skeleton
- diagnostics abstraction
- helper modules
- test harness scaffold

Acceptance:

- `zig build` succeeds
- `zig build test` succeeds
- `zig build run -- help` works
- `zig build run -- generate grammar.json` hits the intended placeholder path

### Milestone 1: `grammar.json` loader

Deliverables:

- `RawGrammar` definition
- `grammar.json` parsing
- schema/base-shape validation
- structured diagnostics

Exit criteria:

- valid fixture grammars decode
- invalid schema fixtures fail correctly

### Milestone 2: Prepared grammar passes

Deliverables:

- symbol interning
- rule reference resolution
- metadata normalization
- inline/supertype/conflict preparation
- invariant validation

Exit criteria:

- prepared IR matches Rust behavior on curated fixtures

### Milestone 3: `node-types.json`

Deliverables:

- variable info computation
- `node-types.json` rendering

Exit criteria:

- semantic match on curated grammars

### Milestone 4: `grammar.json` emission

Deliverables:

- deterministic normalized `src/grammar.json`

Exit criteria:

- stable canonical JSON compare passes

### Milestone 5: Lexical pipeline

Deliverables:

- token extraction
- lexical grammar structures
- NFA / lex-table generation
- token conflict handling

Exit criteria:

- token-focused fixtures behave correctly

### Milestone 6: Parse-table core

Deliverables:

- item sets
- transitions
- reductions
- conflict detection

Exit criteria:

- basic grammars generate enough table data for parser rendering

### Milestone 7: `parser.c`

Deliverables:

- full `parser.c` rendering
- ABI/version handling
- optional report outputs

Exit criteria:

- generated parsers compile on curated grammars

### Milestone 8: Semantic verification

Deliverables:

- harness comparing Rust-generated and Zig-generated parsers

Exit criteria:

- parse-tree equivalence on curated grammars and corpora

### Milestone 9: `grammar.js` through Node

Deliverables:

- subprocess-based `node` loader
- `grammar.js` end-to-end support

Exit criteria:

- real Tree-sitter grammar repos generate without manual conversion

### Milestone 10: Compatibility polish and ergonomics

Deliverables:

- improved diagnostics
- richer report output
- more runtime choices
- performance work

This milestone only begins after correctness is credible.

## Immediate Next Work

The next practical step is Milestone 1 only:

1. add `src/grammar/raw_grammar.zig`
2. add `src/grammar/json_loader.zig`
3. define the minimum schema model
4. implement structured validation
5. add positive and negative fixture tests

Do not start with parse-table work or JS runtime support.

## Risks

### Algorithmic mismatch

Risk:

- silently changing symbol ordering, precedence, or conflict behavior

Mitigation:

- compare intermediate structures, not just final output

### Premature optimization

Risk:

- spending time on compact tables or allocator tuning before correctness

Mitigation:

- use clear deterministic structures first

### JS runtime distraction

Risk:

- spending effort on embedded JS before native `grammar.json` path is solid

Mitigation:

- Node subprocess support only after core stages work

### Over-coupled implementation

Risk:

- mixing normalization, generation, and rendering in one layer

Mitigation:

- keep stage boundaries strict

## Supporting Documents

The following files remain as detailed area plans:

- [zig-generator-architecture.md](./zig-generator-architecture.md)
- [compatibility-matrix.md](./compatibility-matrix.md)
- [prepared-grammar-ir.md](./prepared-grammar-ir.md)
- [parse-table-algorithm-plan.md](./parse-table-algorithm-plan.md)
- [test-strategy.md](./test-strategy.md)
- [milestone-0-task-list.md](./milestone-0-task-list.md)

Use this `MASTER_PLAN.md` as the primary entry point.
