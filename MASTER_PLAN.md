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

Completed milestones:

- Milestone 0: project scaffold
- Milestone 1: `grammar.json` loading and validation
- Milestone 2: prepared-grammar lowering and semantic preparation
- Milestone 3: integrated `node-types.json` pipeline
- Milestone 4: deferred `node-types.json` parity work
- Milestone 5: parser-state construction foundation
- Milestone 6: lookahead/action/conflict infrastructure
- Milestone 7: supported precedence-aware conflict resolution subset
- Milestone 8: build-owned resolved actions and richer shift-side precedence
- Milestone 9: serializer-facing decision snapshot boundary
- Milestone 10: serialized parse-table IR and first emitter boundary
- Milestone 11: broader parser.c-like emission from `SerializedTable`

The project is no longer in front-end or parse-table-foundation work. The remaining work is parser output, runtime-facing emission, compatibility, and later full-generator parity.

Current implementation boundary:

- validated and prepared grammar pipeline
- `node-types.json` generation and parity-oriented golden coverage
- parser item/state/action/conflict infrastructure
- resolution pipeline with explicit unresolved boundaries
- serialized parse-table boundary
- multiple emitter surfaces:
  - textual table dump
  - C-like table dump
  - broader parser.c-like translation unit

The active next milestone is Milestone 12:

- richer parser output on top of the Milestone 11 parser.c-like boundary
- a clearer runtime-facing emitted API
- exact ready/blocked emission goldens at that richer boundary

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

For the front-end stages, the primary behavioral reference is not generic “grammar preparation” in the abstract. It is the concrete upstream sequence around:

- `crates/generate/src/prepare_grammar.rs`
- `crates/generate/src/prepare_grammar/intern_symbols.rs`

That matters because several user-visible semantics are established there before token extraction or parse-table work begins.

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

The current understanding from upstream Rust is that this boundary must already encode several specific semantics:

- hidden start rules are rejected
- internal rule names win over duplicate external-token names during resolution
- missing `inline` names are ignored rather than rejected
- supertypes force the referenced variables to become hidden
- named precedences used in `PREC`, `PREC_LEFT`, and `PREC_RIGHT` must be declared
- nested metadata wrappers should collapse into one canonical metadata node where possible

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
- missing `inline` names have already been dropped instead of surviving as unresolved entries
- conflict sets are canonicalized
- `word_token`, if present, is valid
- named precedence references are declared
- symbol resolution order is deterministic and prefers internal rules over external-token names

### Preparation pass order

1. decode raw grammar
2. intern symbol names
3. assign initial symbol kinds
4. resolve rule references
5. normalize metadata wrappers into canonical merged metadata nodes
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

Status:

- complete

Deliverables:

- `RawGrammar` definition
- `grammar.json` parsing
- schema/base-shape validation
- structured diagnostics

Exit criteria:

- valid fixture grammars decode
- invalid schema fixtures fail correctly

### Milestone 2: Prepared grammar passes

Status:

- complete

Deliverables:

- symbol interning
- rule reference resolution
- metadata normalization
- inline/supertype/conflict preparation
- invariant validation

Exit criteria:

- prepared IR matches Rust behavior on curated fixtures

### Milestone 3: `node-types.json`

Status:

- complete

Deliverables:

- variable info computation
- `node-types.json` rendering

Exit criteria:

- semantic match on curated grammars

### Milestone 4: `node-types.json` parity cleanup

Status:

- complete

Deliverables:

- `children_without_fields` parity
- named lexical/external collision parity
- supertype pruning and final node ordering cleanup

Exit criteria:

- the deferred Milestone 3 `node-types.json` parity gaps are closed

### Milestone 5: Parser-state foundation

Status:

- complete

Deliverables:

- parse item/state IR
- deterministic narrow LR(0)-style state construction
- structured conflict reporting
- exact parser-state dump artifacts

Exit criteria:

- parser-state construction is deterministic and pinned through exact fixtures

### Milestone 6: Lookahead and action-table infrastructure

Status:

- complete

Deliverables:

- FIRST-set computation
- lookahead-aware closure
- explicit parse-action IR
- builder-owned action tables
- flat and grouped action-table artifacts

Exit criteria:

- action/conflict infrastructure is stable enough for resolution work

### Milestone 7: Supported precedence-aware resolution

Status:

- complete

Deliverables:

- integer precedence in both directions
- named precedence in both directions for the supported subset
- dynamic precedence in both directions
- associativity handling
- explicit unresolved classification

Exit criteria:

- the supported shift/reduce resolution subset is real and artifact-tested

### Milestone 8: Build-owned resolved actions

Status:

- complete

Deliverables:

- builder-owned resolved actions in `BuildResult`
- explicit `reduce_reduce_deferred` boundary
- richer shift-side precedence support at the direct resolver layer

Exit criteria:

- parser-decision output is cleaner and closer to serialization

### Milestone 9: Pre-serialization decision boundary

Status:

- complete

Deliverables:

- serializer-facing resolved decisions
- chosen/unresolved decision refs
- readiness checks
- `DecisionSnapshot`

Exit criteria:

- serialization can consume a stable decision handoff

### Milestone 10: Serialized parse-table boundary

Status:

- complete

Deliverables:

- serialized parse-table IR
- strict vs diagnostic serialization policy
- deterministic serialized-table artifacts
- first emitter-facing serialized consumers

Exit criteria:

- serialized tables are a stable emission boundary

### Milestone 11: Broader parser code emission

Status:

- complete

Deliverables:

- broader parser.c-like emitter on top of `SerializedTable`
- shared emitter helpers
- exact ready/blocked emitter goldens
- emitted translation unit with:
  - state arrays
  - `TSStateTable`
  - `TSParser`
  - accessor/query helpers

Exit criteria:

- the project has a broader parser-emission boundary than Milestone 10’s skeleton emitters

### Milestone 12: Richer parser output boundary

Status:

- planned

Deliverables:

- richer parser output on top of Milestone 11
- clearer runtime-facing emitted API boundary
- exact ready/blocked goldens for the richer emitted artifact

Exit criteria:

- the emitter exposes a clearer runtime-shaped boundary without claiming full upstream parity

### Milestone 13+: Runtime compatibility and broader generator parity

Status:

- future work

Likely themes:

- fuller parser output closer to real Tree-sitter `parser.c`
- runtime/ABI compatibility targets
- lexer/scanner emission
- parse-table compression/minimization
- broader grammar/repo compatibility
- semantic and corpus-level equivalence verification

## Immediate Next Work

The next practical step is Milestone 12:

1. deepen `src/parser_emit/parser_c.zig` into a richer parser-oriented translation unit
2. define one small but explicit runtime-facing emitted API layer
3. keep blocked output explicit at that richer boundary
4. pin the richer ready/blocked outputs through exact real-path goldens
5. stop short of claiming runtime ABI compatibility or full upstream `parser.c` parity

## Remaining Work Checklist

This checklist covers only work that is still outstanding from the current project state.

### Milestone 12: Richer parser output boundary

- [x] deepen `src/parser_emit/parser_c.zig` beyond the current broader parser.c-like skeleton
- [x] define the next emitted runtime-facing API layer without reopening `SerializedTable`
- [x] keep blocked-output behavior explicit at the richer emitted boundary
- [x] update exact real-path parser.c-like goldens for:
- [x] one ready grammar
- [x] one blocked grammar
- [x] review whether the richer emitted boundary is sufficient to close Milestone 12
- [x] document the Milestone 12 completion boundary and remaining deferrals

### Milestone 13: Runtime-facing parser output and compatibility boundary

- [x] decide the intended runtime-facing emitted API scope before any ABI claim
- [x] expand emitted parser output beyond the Milestone 12 query/helper layer
- [x] decide whether the project will target upstream C runtime ABI compatibility directly, or stage that through an intermediate compatibility layer
- [x] add exact artifacts for the richer runtime-facing emitted parser surface
- [x] define blocked-output behavior for that richer runtime-facing surface
- [x] review whether the emitted parser boundary is strong enough to begin compatibility work

### Milestone 14: `grammar.js` end-to-end support

- [x] add subprocess-based `node` loading for `grammar.js`
- [x] keep `grammar.json` as the native/core path
- [x] add end-to-end tests that start from `grammar.js`
- [x] verify emitted `grammar.json`, `node-types.json`, and parser output remain deterministic through the JS path
- [x] keep non-Node JS runtimes deferred unless they become necessary

### Milestone 15: Parser/runtime compatibility work

- [ ] define the first concrete compatibility target against upstream generated parser behavior
- [ ] add compatibility checks for parser output structure and runtime-facing expectations
- [ ] decide how ABI/version handling should be centralized
- [ ] close the most important remaining gaps between the emitted parser surface and the expected C runtime contract
- [ ] document which compatibility mismatches are still deferred

### Milestone 16: Behavioral equivalence and corpus verification

- [ ] add harness support for comparing Zig-generated and Rust-generated parser behavior
- [ ] compile generated parsers for curated grammars
- [ ] run shared corpus inputs through both generated parsers
- [ ] compare parse-tree behavior and failure behavior
- [ ] classify and document any remaining semantic mismatches

### Later Work: Fuller generator parity

- [ ] fuller parser output closer to upstream `parser.c`
- [ ] lexer/scanner emission
- [ ] external scanner integration
- [ ] parse-table compression/minimization
- [ ] broader real-grammar/repo compatibility coverage
- [ ] compatibility polish and ergonomics after correctness is credible

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
