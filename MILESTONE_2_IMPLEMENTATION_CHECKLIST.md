# Milestone 2 Implementation Checklist

## Goal

Implement the first semantic lowering stage after raw loading:

- lower `RawGrammar` into a validated `PreparedGrammar`
- intern rule and symbol names into stable IDs
- resolve references between rules
- normalize rule wrappers into a form suitable for later lexical and parse-table work
- add debug-visible, testable intermediate structures

Milestone 2 is the point where the project stops being only a loader and becomes a real grammar compiler front-end.

## What Milestone 2 Includes

- `PreparedGrammar` data model
- symbol interning
- rule lowering from raw JSON forms
- variable kind assignment
- word token resolution
- conflict/supertype/inline target resolution
- base semantic validation on resolved structures
- deterministic IR dumps or summaries for testing

## What Milestone 2 Does Not Include

- lexical grammar extraction
- token extraction
- repeat expansion
- flattening into final productions
- node-types computation
- parse-table construction
- `parser.c` rendering
- `node-types.json`

Those remain later milestones.

## Upstream Reference Points

Milestone 2 should be guided primarily by the upstream preparation pipeline in:

- `/home/alogic0/prog/tree-sitter/crates/generate/src/prepare_grammar.rs`
- `/home/alogic0/prog/tree-sitter/crates/generate/src/prepare_grammar/intern_symbols.rs`

The later preparation passes are useful as planning references, but Milestone 2 should stop short of full token extraction and production flattening.

Relevant future-reference modules:

- `flatten_grammar.rs`
- `expand_repeats.rs`
- `extract_tokens.rs`
- `expand_tokens.rs`
- `extract_default_aliases.rs`
- `process_inlines.rs`

## Deliverables

By the end of Milestone 2, the repository should have:

- `src/ir/symbols.zig`
- `src/ir/rules.zig`
- `src/ir/grammar_ir.zig`
- `src/grammar/parse_grammar.zig` implemented for real
- optional `src/grammar/normalize.zig` if pass separation is useful
- expanded tests for resolved grammar semantics

Optionally useful in Milestone 2:

- `src/grammar/debug_dump.zig`
- `src/tests/golden.zig` extensions for IR snapshots

## Target Boundary

Milestone 2 should end with a resolved structure roughly like:

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

That structure does not need to be final forever, but it should be sufficient for later passes.

## File-by-File Plan

### 1. `src/ir/symbols.zig`

Purpose:

- define the stable identity model for terminals, non-terminals, externals, and auxiliary symbols

Implement:

- `SymbolId`
- `SymbolKind`
- `SymbolInfo`
- helper constructors or functions for deterministic symbol creation

Requirements:

- stable ordering
- explicit kind
- explicit `named`, `visible`, and `supertype` flags where needed

Acceptance criteria:

- symbol identities are deterministic for the same input grammar
- internal and external symbol spaces are not ambiguous

### 2. `src/ir/rules.zig`

Purpose:

- define the lowered semantic rule model used after raw decoding

Implement:

- `RuleId`
- semantic `Rule` union
- `Metadata`
- `Alias`
- `Assoc`
- `PrecedenceValue`

Recommended rule forms:

- `blank`
- `symbol`
- `string`
- `pattern`
- `choice`
- `seq`
- `repeat`
- `metadata`
- `reserved`

Requirements:

- preserve all semantically relevant information from raw rules
- no JSON-shape baggage in this layer

Acceptance criteria:

- all raw rule variants can be lowered into the IR model

### 3. `src/ir/grammar_ir.zig`

Purpose:

- define the top-level `PreparedGrammar` structure and associated semantic lists

Implement:

- `Variable`
- `VariableKind`
- `ConflictSet`
- `PrecedenceOrdering`
- `ReservedWordSet`
- `PreparedGrammar`

Requirements:

- all slices/IDs allocated from a single invocation allocator or arena
- deterministic ordering

### 4. `src/grammar/parse_grammar.zig`

Purpose:

- replace the current deferred placeholder with a real lowering pipeline

Implement:

- `parseRawGrammar(allocator, raw_grammar) !PreparedGrammar`

Subtasks:

- assign variable list from raw rules
- determine variable kinds
- intern references
- lower raw rules recursively
- resolve external token references
- resolve extras
- resolve conflicts
- resolve `inline`
- resolve `supertypes`
- resolve `word`
- copy precedence orderings in a resolved or near-resolved form

Acceptance criteria:

- valid grammars lower to `PreparedGrammar`
- undefined references fail with structured semantic errors

### 5. `src/grammar/normalize.zig` (optional but recommended)

Purpose:

- separate pure lowering from small semantic cleanup passes

Possible responsibilities:

- canonical ordering of conflict sets
- duplicate elimination in inline/supertypes/conflicts
- metadata normalization

This file is optional if the logic remains small, but separation is likely useful.

## Semantic Rules to Implement

Milestone 2 should cover these resolved semantics.

### Variable kind assignment

Use the same basic visibility model as upstream:

- names starting with `_` become hidden variables
- start rule must not be hidden
- named rules remain named unless transformed later

Errors to support:

- hidden start rule

### Reference resolution

For every named symbol reference in rules:

- resolve to a declared variable or external token
- otherwise fail

Errors to support:

- undefined symbol
- undefined supertype
- undefined conflict member
- undefined word token

### `word` token resolution

If `word` is present:

- resolve it to a valid symbol
- store as `word_token`

Errors to support:

- undefined word token

### `inline` resolution

If `inline` names are present:

- resolve to symbol IDs
- deduplicate

Later constraints about what may be inlined can remain for later passes.

### `supertypes` resolution

Resolve every supertype name to a symbol ID.

At this stage:

- require symbol existence
- record the supertype symbol list

### Conflict resolution metadata

Resolve every conflict set member to a symbol ID.

At this stage:

- existence matters
- later grammar-specific conflict behavior remains for later milestones

### Reserved word context lowering

Convert reserved-word sets into resolved rule lists or symbol lists, depending on the chosen IR.

At this stage:

- preserve the context name
- preserve the rule content
- ensure deterministic ordering

## Suggested Error Set

Milestone 2 should add a dedicated semantic error set, for example:

```zig
pub const ParseGrammarError = error{
    HiddenStartRule,
    UndefinedSymbol,
    UndefinedSupertype,
    UndefinedConflict,
    UndefinedWordToken,
    DeferredUnsupportedCase,
    OutOfMemory,
};
```

You may prefer richer error structs plus an umbrella error set. That is better if it stays manageable.

## Recommended Implementation Order

Implement in this order:

1. `src/ir/symbols.zig`
2. `src/ir/rules.zig`
3. `src/ir/grammar_ir.zig`
4. update `src/grammar/parse_grammar.zig` with real lowering
5. add `src/grammar/normalize.zig` if the lowering file becomes overloaded
6. add tests and snapshots

This keeps the semantic data model stable before lowering logic gets large.

## Detailed Task Groups

### Task Group A: Create IR modules

- add `src/ir/symbols.zig`
- add `src/ir/rules.zig`
- add `src/ir/grammar_ir.zig`
- import them in the top-level test block

Done when:

- IR files compile independently

### Task Group B: Define symbol interning rules

- assign rule-defined non-terminal symbols in raw rule order
- assign external symbols in external-token order
- assign deterministic IDs
- compute variable kinds from names

Done when:

- a grammar can produce a stable symbol table

### Task Group C: Implement recursive rule lowering

- lower each `RawRule` recursively
- convert named symbol references into `SymbolId`
- preserve metadata wrappers
- preserve field names and aliases

Done when:

- a simple valid grammar lowers completely

### Task Group D: Resolve top-level semantic lists

- resolve `externals`
- resolve `extras`
- resolve `inline_rules`
- resolve `supertypes`
- resolve `conflicts`
- resolve `word`
- resolve `reserved`

Done when:

- all top-level lists in `PreparedGrammar` are populated and validated

### Task Group E: Add semantic validation

- reject hidden start rule
- reject undefined names
- reject undefined `word`
- reject undefined conflict members
- reject undefined supertypes

Done when:

- negative tests cover every semantic failure category

### Task Group F: Add debug-visible output

Choose at least one:

- symbol table textual dump
- prepared grammar summary
- normalized rule-tree dump

This is important for debugging later mismatches.

Done when:

- one prepared-grammar snapshot can be asserted in tests

## Test Plan

Milestone 2 should add tests in three categories.

### Unit tests

For:

- variable kind assignment
- symbol interning
- undefined reference detection
- hidden start-rule rejection
- word token resolution

### Snapshot tests

For curated grammars, dump:

- symbols
- variables
- top-level semantic lists

These should be deterministic.

### Integration tests

For selected fixture grammars:

- load `grammar.json`
- lower to `PreparedGrammar`
- assert semantic invariants

## Fixture Additions Recommended

Add new fixtures for:

- valid grammar with symbol references
- valid grammar with externals
- valid grammar with inline names
- valid grammar with supertypes
- valid grammar with word token
- hidden start rule
- undefined symbol reference
- undefined supertype
- undefined conflict member
- undefined word token

## Suggested Success Output

Milestone 2 can extend command output optionally, but it is not required.

If you do expose a debug mode, useful fields are:

- grammar name
- variable count
- symbol count
- external token count
- inline count
- supertype count
- conflict set count
- whether `word_token` is present

## Exit Criteria

Milestone 2 is complete when:

- IR modules exist and compile
- `parseRawGrammar` lowers valid raw grammars into `PreparedGrammar`
- undefined references fail with semantic errors
- hidden start rule is rejected
- `word`, `inline`, `supertypes`, and `conflicts` are resolved into deterministic structures
- at least one prepared-grammar snapshot or debug dump test exists
- `zig build`
- `zig build test`

## Explicitly Deferred to Milestone 3+

- token extraction
- repeat expansion
- grammar flattening into productions
- lexical grammar generation
- inlining validation beyond name resolution
- default alias extraction
- node-types generation
- parse-table generation

## Immediate Next Command Sequence

After this plan is accepted, the implementation sequence should start with:

1. create `src/ir/symbols.zig`
2. create `src/ir/rules.zig`
3. create `src/ir/grammar_ir.zig`
4. replace the placeholder in `src/grammar/parse_grammar.zig`
5. add one valid lowering test and one undefined-symbol failure test

That is the shortest path into real Milestone 2 work.
