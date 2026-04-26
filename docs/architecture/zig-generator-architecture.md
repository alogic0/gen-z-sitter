# Zig Tree-sitter Generator Architecture

## Goal

Reimplement `tree-sitter generate` in Zig while preserving the existing Tree-sitter ecosystem contracts:

- Inputs remain `grammar.js` and `grammar.json`
- Outputs remain `src/parser.c`, `src/grammar.json`, and `src/node-types.json`
- Generated parsers remain compatible with the existing C runtime ABI
- Failure behavior and diagnostics stay close enough to the current generator to avoid ecosystem breakage

This is a compiler rewrite, not a syntax translation from Rust to Zig.

## Non-Goals

- Replacing the C runtime
- Changing the generated parser artifact from C to Zig
- Redesigning the grammar DSL
- Achieving full command-line parity before the core generation pipeline is correct
- Embedding a JS engine in the first implementation

## External Contract

The Zig generator should preserve these visible behaviors:

- Accept a path to `grammar.js` or `grammar.json`
- Write `grammar.json` when starting from `grammar.js`
- Write `node-types.json`
- Write `parser.c` unless `--no-parser` is requested
- Support ABI version selection
- Support state/conflict reporting
- Fail on the same invalid grammars that the current generator rejects

The primary compatibility target is the current Rust generator's observable behavior, not its internal structure.

## Top-Level Pipeline

The generator should be implemented as an explicit staged pipeline:

1. Load source grammar
2. Decode grammar into a raw AST/JSON model
3. Normalize and validate grammar
4. Lower normalized grammar into generator IR
5. Build lexical automata
6. Build parse tables
7. Compute node-type metadata
8. Render output files
9. Compare or verify generated outputs in tests

Each stage should have:

- Narrow input/output types
- Deterministic behavior
- Explicit error types
- Unit tests independent from later stages where possible

## Proposed Directory Layout

```text
zig_tree_sit/
  build.zig
  build.zig.zon
  docs/
    zig-generator-architecture.md
  src/
    main.zig
    cli/
      args.zig
      command_generate.zig
    support/
      alloc.zig
      arena.zig
      fs.zig
      json.zig
      diag.zig
      process.zig
      hash.zig
      strings.zig
    grammar/
      loader.zig
      js_loader.zig
      json_loader.zig
      raw_grammar.zig
      parse_grammar.zig
      validate.zig
      normalize.zig
      prepare/
        expand_tokens.zig
        flatten_grammar.zig
        extract_tokens.zig
        process_inlines.zig
        expand_repeats.zig
        extract_default_aliases.zig
        intern_symbols.zig
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

## Module Boundaries

### `src/main.zig`

Responsibilities:

- Program entry point
- Exit code policy
- Top-level panic handling
- Dispatch into CLI commands

Should not contain:

- Grammar logic
- Rendering logic
- Table construction logic

### `src/cli/`

Responsibilities:

- Parse CLI arguments
- Build an immutable `GenerateOptions`
- Invoke generator pipeline
- Print diagnostics and summaries

Core type:

```zig
pub const GenerateOptions = struct {
    grammar_path: []const u8,
    output_dir: ?[]const u8 = null,
    abi_version: u32,
    no_parser: bool = false,
    report_states_for_rule: ?[]const u8 = null,
    json_summary: bool = false,
    js_runtime: ?[]const u8 = null,
    optimize_merge_states: bool = true,
};
```

### `src/support/`

Responsibilities:

- Shared low-level helpers
- Memory strategy wrappers
- Filesystem helpers
- process spawning
- structured diagnostics
- stable JSON serialization wrappers

Important rule:

No grammar-specific logic belongs here.

### `src/grammar/`

Responsibilities:

- Load `grammar.js` or `grammar.json`
- Represent raw schema-level grammar
- Validate required fields and base shape
- Normalize grammar before IR lowering
- Perform the current Rust `prepare_grammar`-style passes

Core output:

- `PreparedGrammar`

Important rule:

This layer knows the grammar DSL schema, but not parse-table internals.

Recommended types:

```zig
pub const RawGrammar = struct {
    name: []const u8,
    word: ?[]const u8,
    rules: []RawRuleEntry,
    conflicts: [][]const []const u8,
    precedences: []RawPrecedenceList,
    externals: []RawRule,
    extras: []RawRule,
    supertypes: [][]const u8,
    inline: [][]const u8,
    reserved: []RawReservedSet,
};

pub const PreparedGrammar = struct {
    grammar_name: []const u8,
    variables: []PreparedVariable,
    externals: []PreparedToken,
    extras: []PreparedToken,
    expected_conflicts: []ConflictSet,
    supertype_symbols: []SymbolId,
    variables_to_inline: []SymbolId,
    word_token: ?SymbolId,
    precedence_orderings: []PrecedenceOrdering,
};
```

### `src/ir/`

Responsibilities:

- Define the generator's internal semantic model
- Assign stable symbol identifiers
- Separate lexical and syntactic structures
- Represent aliases, fields, precedences, and variable metadata

Core constraint:

This layer must be serializable enough for debugging but optimized for deterministic compilation.

Key types:

```zig
pub const SymbolId = enum(u32) { _ };

pub const SymbolKind = enum {
    terminal,
    non_terminal,
    external,
    auxiliary,
    anonymous,
};

pub const Rule = union(enum) {
    blank,
    string: []const u8,
    pattern: RegexLike,
    seq: []RuleId,
    choice: []RuleId,
    repeat: RuleId,
    metadata: MetadataRule,
    symbol: SymbolId,
};
```

### `src/lex/`

Responsibilities:

- Build lexical NFA/DFA-ish structures as needed by Tree-sitter generation
- Compute token conflicts
- Produce lex tables for rendering

Inputs:

- `PreparedGrammar`
- symbol metadata

Outputs:

- `LexicalGrammar`
- lex states/tables

Important rule:

No C rendering in this layer.

### `src/parse_table/`

Responsibilities:

- Build LR-style items and item sets
- Compute transitions, reductions, conflicts, and reusable states
- Minimize parse tables when enabled
- Produce the final syntax table representation used by the C renderer

Outputs:

- `SyntaxGrammar`
- `ParseTable`
- conflict report structures

Important rule:

This is the highest-risk logic layer. Keep it isolated from I/O and CLI concerns.

### `src/node_types/`

Responsibilities:

- Compute node visibility, supertypes, field relationships, and aliases
- Produce the semantic data required for `node-types.json`

Outputs:

- `VariableInfo`
- rendered JSON data model

This layer should be testable without rendering `parser.c`.

### `src/render/`

Responsibilities:

- Convert final generator structures into output artifacts
- Render:
  - `grammar.json`
  - `node-types.json`
  - `parser.c`

Inputs:

- `PreparedGrammar`
- `LexicalGrammar`
- `SyntaxGrammar`
- node-type metadata
- ABI/version settings

Important rule:

No algorithmic generation logic here. Rendering should only consume precomputed structures.

### `src/report/`

Responsibilities:

- Human-readable conflict reports
- machine-readable summary reports
- state dump emission for a given rule or all rules

This module is separate so reporting can evolve without destabilizing generation logic.

### `src/compat/`

Responsibilities:

- ABI/version constants
- behavior flags needed to match current generator output
- optional output-diff helpers against the Rust generator

This is where compatibility hacks belong, not scattered through the codebase.

### `src/tests/`

Responsibilities:

- fixture loading
- golden file comparison
- integration tests
- parser build/compile verification

Integration tests should exercise:

- success fixtures
- failure fixtures
- output equivalence where practical
- ABI/version permutations

## Data Flow

The intended in-memory flow is:

```text
grammar.js / grammar.json
  -> RawGrammar
  -> PreparedGrammar
  -> GeneratorIR
  -> LexicalGrammar + ParseTable + VariableInfo
  -> RenderedOutputs
  -> files on disk
```

Suggested orchestrator type:

```zig
pub const GenerateArtifacts = struct {
    grammar_json: []const u8,
    node_types_json: []const u8,
    parser_c: ?[]const u8,
    report_json: ?[]const u8,
};
```

## Memory Strategy

Use explicit allocator layering rather than ad hoc allocation:

- General-purpose allocator for process lifetime
- Arena allocator for one-shot grammar compilation
- Optional scratch allocators for table construction hot paths

Recommended policy:

- One arena per `generate` invocation
- No ownership ambiguity across stages
- Long-lived cross-stage data should be allocated from the invocation arena
- Temporary builder data should be freed per pass where it materially reduces peak memory

This keeps the rewrite simple first, then allows optimization later.

## Error Model

Use structured error sets plus diagnostic payloads, not plain strings.

Suggested shape:

```zig
pub const Diagnostic = struct {
    kind: Kind,
    message: []const u8,
    path: ?[]const u8 = null,
    rule_name: ?[]const u8 = null,
    span: ?SourceSpan = null,
    notes: []const Note = &.{},
};
```

Error classes:

- I/O and path errors
- JS runtime invocation errors
- invalid grammar schema
- grammar semantic validation failures
- generator algorithm failures
- rendering failures

Keep source location attachment wherever possible, even if initial coverage is partial.

## JS Loading Strategy

Do not start with embedded JS.

### Phase 1 policy

- Support `grammar.json` natively
- Support `grammar.js` by spawning `node`
- Defer `bun`, `deno`, and embedded QuickJS until core generation is stable

Implement `src/grammar/js_loader.zig` as a subprocess adapter that:

- canonicalizes the grammar path
- sets `TREE_SITTER_GRAMMAR_PATH`
- writes the DSL bootstrap to stdin
- reads stdout
- splits diagnostic noise from the final JSON payload if needed

Once this is stable, add:

- `bun`
- `deno`
- optional embedded JS runtime

## Compatibility Rules

The rewrite should preserve:

- current language ABI version handling
- symbol ordering
- state numbering stability where practical
- generated C formatting stable enough for deterministic tests
- invalid-grammar rejection behavior

Where exact textual equivalence is impractical, semantic equivalence should still be measured by:

- parser compilation success
- identical `node-types.json` semantics
- equivalent parse trees on fixture corpora

## Testing Strategy

Testing must be layered.

### Unit tests

For:

- grammar schema decoding
- normalization passes
- symbol interning
- NFA components
- parse-table item/set builders
- JSON rendering
- C escaping/render helpers

### Fixture tests

Run the Zig generator against the existing fixture grammars in the Tree-sitter repo and classify:

- should succeed
- should fail
- should emit a known diagnostic class

### Golden output tests

For a small curated set of grammars:

- compare `grammar.json`
- compare `node-types.json`
- compare `parser.c`

### Semantic equivalence tests

For grammars where textual output may drift:

- compile generated parser
- run it against sample corpus
- compare parse trees to the Rust generator result

### Regression tests

Any discovered mismatch should produce:

- a minimized fixture
- a stored golden or semantic test

## First Implementation Sequence

This sequence is optimized for shortest path to a credible generator.

### Milestone 0: Scaffold

Deliverables:

- `build.zig`
- executable with `generate` command
- allocator/logging/diagnostic infrastructure
- test harness skeleton

Exit criteria:

- `zig build test` runs
- CLI accepts basic options

### Milestone 1: `grammar.json` loader only

Deliverables:

- parse `grammar.json` into `RawGrammar`
- validate base schema
- print decoded summary for debugging

Exit criteria:

- valid fixture grammars load
- invalid schema failures are structured

Risk reduced:

- confirms JSON model and normalization entry point

### Milestone 2: Prepared grammar passes

Deliverables:

- implement core normalization/prepare passes
- symbol interning
- conflict/preference normalization
- inline/supertype/default-alias preparation

Exit criteria:

- prepared model matches the Rust generator on selected fixture grammars

Risk reduced:

- isolates grammar semantics before automata/table work

### Milestone 3: `node-types.json`

Deliverables:

- compute variable info
- render `node-types.json`

Exit criteria:

- `node-types.json` matches current generator for a curated grammar set

Why now:

- yields visible progress without requiring parse-table generation

### Milestone 4: `grammar.json` emission

Deliverables:

- stable rendered `src/grammar.json`

Exit criteria:

- output is deterministic and compatible with current tooling

### Milestone 5: Lexical pipeline

Deliverables:

- lexical grammar structures
- token extraction
- NFA and lex-table generation
- token conflict computation

Exit criteria:

- lex states produce correct tokenization behavior on fixture grammars

Risk reduced:

- one half of parser generation is now validated independently

### Milestone 6: Parse-table core

Deliverables:

- item sets
- transitions
- reductions
- conflict detection

Exit criteria:

- basic grammars render enough syntax table data to generate compilable `parser.c`

This is the first major algorithmic milestone.

### Milestone 7: `parser.c` rendering

Deliverables:

- render complete `parser.c`
- honor ABI/version constants
- emit optional reports

Exit criteria:

- generated parsers compile for curated grammars

### Milestone 8: Semantic verification

Deliverables:

- harness that compares Zig-generated parsers against Rust-generated parsers

Checks:

- generated parser compiles
- parses corpus fixtures
- trees match or fail equivalently

### Milestone 9: `grammar.js` support through Node

Deliverables:

- subprocess-based JS grammar loading
- `grammar.js` end-to-end generation

Exit criteria:

- standard Tree-sitter grammar repos can be generated without intermediate manual conversion

### Milestone 10: Compatibility and ergonomics

Deliverables:

- conflict/state JSON reporting
- improved diagnostics
- additional runtime choices
- performance work

This milestone should only happen after correctness is established.

## Recommended Implementation Order by File

Start in this order:

1. `src/main.zig`
2. `src/cli/args.zig`
3. `src/support/diag.zig`
4. `src/grammar/raw_grammar.zig`
5. `src/grammar/json_loader.zig`
6. `src/grammar/parse_grammar.zig`
7. `src/grammar/normalize.zig`
8. `src/ir/symbols.zig`
9. `src/node_types/compute.zig`
10. `src/node_types/render_json.zig`
11. `src/render/render_grammar_json.zig`
12. `src/lex/nfa.zig`
13. `src/lex/lex_table.zig`
14. `src/parse_table/item.zig`
15. `src/parse_table/item_set_builder.zig`
16. `src/parse_table/build_parse_table.zig`
17. `src/parse_table/minimize_parse_table.zig`
18. `src/render/render_c.zig`
19. `src/grammar/js_loader.zig`
20. `src/tests/integration_generate.zig`

## First Deliverable Definition

The first useful deliverable is not full parity.

It is:

- a Zig binary that accepts `grammar.json`
- emits `node-types.json`
- emits normalized `grammar.json`
- has fixture-based regression tests

That is the right checkpoint because it proves:

- schema handling
- semantic normalization
- deterministic output
- project structure viability

without taking on parse-table construction too early.

## Risks

### Algorithmic mismatch

The Rust generator contains many implicit invariants. A direct rewrite may accidentally change:

- symbol ordering
- state merge behavior
- conflict resolution
- alias handling

Mitigation:

- compare intermediate structures, not just final outputs

### Premature optimization

Trying to beat Rust performance early will slow correctness work.

Mitigation:

- use clear data structures first
- optimize only after semantic parity exists

### JS loading distractions

Embedding JS early adds a separate runtime problem.

Mitigation:

- subprocess-based `node` first

### Over-coupled modules

If parsing, normalization, and rendering are mixed, later debugging becomes expensive.

Mitigation:

- keep stage boundaries strict

## Suggested Next Documents

After this architecture document, the next useful documents are:

1. `compatibility-matrix.md`
2. `prepared-grammar-ir.md`
3. `parse-table-algorithm-plan.md`
4. `test-strategy.md`
5. `milestone-0-task-list.md`

## Immediate Next Step

Implement Milestone 0 and Milestone 1 only:

- scaffold Zig project
- add `generate` CLI surface
- support `grammar.json`
- decode into `RawGrammar`
- emit structured diagnostics

Do not start with parse-table generation.
