# Milestone 3 Implementation Checklist

## Goal

Implement the first artifact-producing stage after `PreparedGrammar`:

- compute the semantic data needed for `node-types.json`
- define the Zig-side syntax and lexical grammar IR needed by node-type analysis
- port the minimum upstream preparation passes required before parse-table generation
- render deterministic `node-types.json`

Milestone 3 is the point where the Zig rewrite stops being only a validated front-end and starts producing one of Tree-sitter’s public output artifacts.

## What Milestone 3 Includes

- syntax/lexical grammar IR for post-prepared passes
- token extraction planning and implementation boundary
- repeat expansion planning and implementation boundary
- grammar flattening needed for node-type analysis
- default alias extraction
- variable info computation for node-type emission
- `node-types.json` rendering
- canonical JSON comparison tests for curated grammars

## What Milestone 3 Does Not Include

- parse-table generation
- lexer table generation
- `parser.c` rendering
- full `grammar.js` support if still deferred
- report/state dumping parity

Those remain later milestones.

## Upstream Reference Points

Milestone 3 should be guided primarily by these upstream modules:

- `/home/alogic0/prog/tree-sitter/crates/generate/src/prepare_grammar/extract_tokens.rs`
- `/home/alogic0/prog/tree-sitter/crates/generate/src/prepare_grammar/expand_repeats.rs`
- `/home/alogic0/prog/tree-sitter/crates/generate/src/prepare_grammar/flatten_grammar.rs`
- `/home/alogic0/prog/tree-sitter/crates/generate/src/prepare_grammar/extract_default_aliases.rs`
- `/home/alogic0/prog/tree-sitter/crates/generate/src/node_types.rs`
- `/home/alogic0/prog/tree-sitter/crates/generate/src/generate.rs`

Milestone 3 does not need the full build-table pipeline, but it does need enough of the upstream preparation sequence to make node-type output credible.

## Deliverables

By the end of Milestone 3, the repository should have:

- `src/ir/syntax_grammar.zig`
- `src/ir/lexical_grammar.zig`
- `src/ir/aliases.zig`
- optional `src/ir/variable_info.zig`
- `src/grammar/prepare/extract_tokens.zig`
- `src/grammar/prepare/expand_repeats.zig`
- `src/grammar/prepare/flatten_grammar.zig`
- `src/grammar/prepare/extract_default_aliases.zig`
- `src/node_types/compute.zig`
- `src/node_types/render_json.zig`
- CLI plumbing to emit or preview `node-types.json`
- canonical JSON tests for node-type output

## Target Boundary

Milestone 3 should end with a pipeline roughly like:

```zig
PreparedGrammar
  -> ExtractedSyntaxGrammar
  -> ExpandedSyntaxGrammar
  -> FlattenedSyntaxGrammar
  -> VariableInfo / AliasInfo
  -> NodeTypes
  -> node-types.json
```

The exact type names can differ, but the stage boundaries should be clear and testable.

## File-by-File Plan

### 1. `src/ir/syntax_grammar.zig`

Purpose:

- define the syntax-side grammar representation after token extraction and repeat expansion

Implement:

- syntax variable model
- production/step model
- symbol typing for syntax vs lexical references
- precedence and associativity fields needed by flattening

Requirements:

- deterministic ordering
- no raw JSON-layer constructs
- suitable input for node-type analysis and later parse-table construction

### 2. `src/ir/lexical_grammar.zig`

Purpose:

- define the lexical-side grammar representation created by token extraction

Implement:

- lexical variables
- separators/extras representation
- token rule references
- room for later NFA attachment without redesigning the type

Requirements:

- stable token ordering
- enough structure for `node_types` logic to reason about terminal names and visibility

### 3. `src/ir/aliases.zig`

Purpose:

- define default alias and explicit alias data reused by node-type computation

Implement:

- alias map type
- alias lookup helpers

Requirements:

- deterministic keying
- compatibility with both syntax and lexical symbol references

### 4. `src/grammar/prepare/extract_tokens.zig`

Purpose:

- split `PreparedGrammar` into syntax-facing and lexical-facing pieces

Implement:

- extraction of string/pattern/token rules into lexical variables
- replacement of syntax-side terminal occurrences with lexical symbol references
- extras/separators handling needed for later stages

Acceptance criteria:

- simple grammars produce a non-empty lexical grammar when they contain tokens
- hidden wrapper rules are not left behind as lexical variables where upstream would fold them away

### 5. `src/grammar/prepare/expand_repeats.zig`

Purpose:

- expand repeat constructs into explicit auxiliary forms aligned with upstream expectations

Implement:

- repeat auxiliary variable creation
- deterministic naming/indexing for auxiliary repeat variables

Acceptance criteria:

- repeated syntax structures are explicit in the post-expansion grammar
- repeat expansion is stable across runs

### 6. `src/grammar/prepare/flatten_grammar.zig`

Purpose:

- flatten syntax rules into production-like structures suitable for node-type analysis and later parse-table generation

Implement:

- flattening of sequences/choices
- precedence propagation
- dynamic precedence carry-through
- field-name retention
- alias retention

Acceptance criteria:

- flattened grammar preserves semantic metadata
- complex nested metadata does not disappear during flattening

### 7. `src/grammar/prepare/extract_default_aliases.zig`

Purpose:

- compute the alias information used by `node-types.json`

Implement:

- default alias extraction from flattened syntax and lexical grammar

Acceptance criteria:

- alias behavior matches curated upstream cases

### 8. `src/node_types/compute.zig`

Purpose:

- compute the internal node-type model from syntax grammar, lexical grammar, and alias information

Implement:

- variable info computation
- node visibility/namedness decisions
- field aggregation
- child-type aggregation
- supertype relationships

Acceptance criteria:

- generated node-type structures are sufficient to render `node-types.json`
- named/anonymous distinctions match curated upstream cases

### 9. `src/node_types/render_json.zig`

Purpose:

- render deterministic `node-types.json`

Implement:

- stable JSON writer for node types
- canonical ordering for nodes, fields, and children

Acceptance criteria:

- output is deterministic
- output is canonically comparable against upstream JSON

## Semantic Rules to Implement

Milestone 3 should cover these semantics.

### Token extraction semantics

- string, pattern, and token-marked rules must move into lexical structures when upstream would treat them as tokens
- syntax-side references must be rewritten to lexical symbol references where appropriate
- hidden wrapper variables should not survive as accidental lexical variables if upstream would fold them into token variables

### Repeat expansion semantics

- repeat nodes must become explicit auxiliary variables or equivalent explicit grammar structures
- generated auxiliary entities must be deterministic

### Flattening semantics

- precedence metadata must survive flattening
- dynamic precedence must survive flattening
- field names must survive flattening
- explicit aliases and default aliases must remain distinguishable

### Node-type semantics

- named node kinds must match syntax and lexical visibility rules
- fields must aggregate correctly across productions
- child-type sets must be canonical and deterministic
- supertypes must appear in node-type output with the correct relationships

## Suggested Error Set

Milestone 3 will likely need one or more new error sets, for example:

```zig
pub const ExtractTokensError = error{
    UnsupportedRuleShape,
    InvalidTokenExtraction,
    OutOfMemory,
};

pub const FlattenGrammarError = error{
    RecursiveInline,
    UnsupportedProductionShape,
    OutOfMemory,
};

pub const NodeTypesError = error{
    InvalidVariableInfo,
    JsonRenderFailure,
    OutOfMemory,
};
```

Precise names can differ, but the failures should be separated by stage.

## Recommended Implementation Order

Implement in this order:

1. `src/ir/syntax_grammar.zig`
2. `src/ir/lexical_grammar.zig`
3. `src/ir/aliases.zig`
4. `src/grammar/prepare/extract_tokens.zig`
5. `src/grammar/prepare/expand_repeats.zig`
6. `src/grammar/prepare/flatten_grammar.zig`
7. `src/grammar/prepare/extract_default_aliases.zig`
8. `src/node_types/compute.zig`
9. `src/node_types/render_json.zig`
10. CLI and test integration

This order gets the grammar into the minimum post-prepared form needed for node-type computation before spending time on JSON rendering.

## Detailed Task Groups

### Task Group A: Create post-prepared IR modules

- add `src/ir/syntax_grammar.zig`
- add `src/ir/lexical_grammar.zig`
- add `src/ir/aliases.zig`
- optionally add `src/ir/variable_info.zig`
- register them in the top-level test build

Done when:

- the new IR files compile independently

### Task Group B: Implement token extraction

- port the minimum viable token extraction logic from upstream
- preserve token naming and visibility
- rewrite syntax references to lexical references

Done when:

- a grammar with strings/patterns/tokens produces both syntax and lexical IR

### Task Group C: Implement repeat expansion

- expand repeat constructs into explicit auxiliary forms
- prove determinism with unit tests

Done when:

- no raw repeat nodes remain in the post-expansion stage

### Task Group D: Implement grammar flattening

- flatten nested grammar structures into production-like forms
- preserve metadata and aliases

Done when:

- production-level syntax data exists and is stable enough for node-type analysis

### Task Group E: Implement alias extraction and variable info

- compute default aliases
- compute variable info needed for node-type rendering

Done when:

- node-type computation has all required semantic inputs

### Task Group F: Implement node-type computation and rendering

- compute internal node-type representation
- render deterministic JSON
- compare against curated expected output

Done when:

- `node-types.json` is emitted for selected grammars and matches canonical expectations

## Test Plan

Milestone 3 should add tests in four categories.

### Unit tests

For:

- token extraction helpers
- repeat expansion helpers
- flattening helpers
- alias extraction
- node-type field aggregation
- JSON rendering order

### Snapshot tests

For curated grammars, dump:

- extracted lexical grammar
- flattened syntax grammar
- alias/default-alias maps
- computed node-type structures

These should be deterministic.

### Canonical JSON tests

For curated grammars:

- render `node-types.json`
- compare canonicalized JSON with expected output or upstream output

Priority grammars:

- simple expression grammar
- precedence/associativity grammar
- alias-heavy grammar
- field-heavy grammar
- supertype grammar

### Integration tests

For selected fixture grammars:

- load `grammar.json`
- lower to `PreparedGrammar`
- run Milestone 3 pipeline
- assert `node-types.json` artifact generation and semantic content

## Fixture Additions Recommended

Add new fixtures for:

- grammar with visible and hidden tokens
- grammar with explicit aliases
- grammar with fields on multiple productions
- grammar with supertypes
- grammar with repeats that must expand
- grammar whose `node-types.json` is small enough to keep inline as expected output

## Suggested CLI Scope

Milestone 3 does not need final CLI parity, but one of these should exist:

- generate `node-types.json` as part of `generate` when `grammar.json` lowering succeeds
- or add a temporary debug flag to emit node-type JSON only

The first option is preferable if the implementation is stable enough.

## Exit Criteria

Milestone 3 is complete when:

- post-prepared IR modules exist and compile
- token extraction, repeat expansion, and flattening are implemented for the supported grammar subset
- alias/default-alias data is computed
- `node-types.json` can be rendered deterministically
- canonical JSON tests exist for curated grammars
- at least one integration path emits node-type JSON from `generate`
- `zig build`
- `zig build test`

## Explicitly Deferred to Milestone 4+

- full `grammar.json` normalized artifact parity
- lexical NFA construction
- lex table generation
- parse-table generation
- `parser.c` rendering
- final conflict/state reports

## Immediate Next Command Sequence

After this plan is accepted, implementation should start with:

1. create `src/ir/syntax_grammar.zig`
2. create `src/ir/lexical_grammar.zig`
3. create `src/ir/aliases.zig`
4. scaffold `src/grammar/prepare/extract_tokens.zig`
5. add one successful extraction test and one tiny `node-types.json` target grammar

That is the shortest path into real Milestone 3 work without overcommitting to parse-table logic too early.
