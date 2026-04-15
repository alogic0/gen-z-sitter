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

## Current Status

Implemented and passing:

- post-prepared IR scaffolding:
  - `src/ir/syntax_grammar.zig`
  - `src/ir/lexical_grammar.zig`
  - `src/ir/aliases.zig`
- token extraction:
  - `src/grammar/prepare/extract_tokens.zig`
  - lexical extraction for string, pattern, and token-marked rules
  - syntax-side terminal replacement
  - extras vs separators split
  - external token carry-through
  - `word_token`, precedence-symbol, conflict-member, and `SYMBOL`-extra rewrites through the extracted graph
  - extraction-stage validation for invalid supertype, inline, conflict, precedence, and word-token inputs
- repeat expansion:
  - `src/grammar/prepare/expand_repeats.zig`
  - auxiliary repeat creation
  - repeat deduplication
  - hidden top-level repeat promotion in place
  - removal of promoted hidden repeats from `variables_to_inline`
  - nested repeat auxiliary allocation without symbol-index collisions
  - mixed `choice` / `seq` repeat regression coverage
  - deterministic auxiliary naming coverage
- grammar flattening:
  - `src/grammar/prepare/flatten_grammar.zig`
  - duplicate production deduplication
  - metadata preservation
  - empty-string validation outside the start rule
  - auxiliary-repeat empty-production allowance
  - recursive-inline rejection
- default alias extraction:
  - `src/grammar/prepare/extract_default_aliases.zig`
  - syntax, lexical, and external default-alias support
- node-type computation and rendering:
  - `src/node_types/compute.zig`
  - `src/node_types/render_json.zig`
  - `src/node_types/pipeline.zig`
  - deterministic JSON rendering
  - hidden-wrapper inheritance
  - duplicate node-type entry canonicalization
- CLI and integration:
  - debug preview path
  - `generate --output <dir>` writes `node-types.json`
  - exact golden coverage for multiple curated grammars, including:
    - hidden wrappers
    - mixed semantics
    - repeat-heavy choice/sequence shapes
    - alternative field aggregation
    - hidden-wrapper alternative field aggregation
    - hidden-wrapper external field aggregation
    - extras plus alias-visible children

Still remaining:

- finish the last `extract_tokens.zig` audit passes and either implement or explicitly defer the remaining upstream edge cases
- decide whether any remaining `compute.zig` differences from upstream should be fixed in Milestone 3 or documented as Milestone 4+ work
- do a final closeout review against current goldens, CLI coverage, and upstream expectations
- update docs to mark Milestone 3 complete if the remaining deltas are acceptable

## Remaining Critical Path

Milestone 3 is no longer blocked on missing subsystems. The shortest path to completion is:

1. finish the last `extract_tokens.zig` parity audit and record any intentional deferrals
2. review current `compute.zig` behavior against the now-broader golden set and fix only the mismatches worth closing in Milestone 3
3. add another golden fixture only if that review still reveals an uncovered artifact class
4. update docs and mark Milestone 3 complete if the remaining deltas are acceptable

## Remaining Work From Current Code State

The remaining work is mostly semantic tightening and proof, not new architecture.

### 1. `extract_tokens.zig` closeout audit

Keep auditing symbol-bearing collections so every reference follows the extracted graph or fails explicitly.

Remaining checks to decide and implement:

- reserved-word and word-token interactions if upstream extraction treats some combinations specially
- external-token corner cases beyond the current visibility and alias coverage
- document any symbol-wrapper paths that intentionally stay syntax-side because changing them would collapse alias or visibility boundaries
- decide whether any upstream extraction mismatches are real bugs or acceptable Milestone 3 deferrals

Done when:

- all symbol-bearing extracted collections either:
  - track the extracted symbol graph, or
  - fail with a dedicated extraction-stage error

### 2. repeat-expansion confidence

The implementation now has real mixed-shape and artifact-level coverage.

Remaining:

- no further repeat work unless another closeout review exposes a mismatch

Done when:

- repeat expansion is no longer an obvious source of downstream artifact mismatch risk

### 3. `compute.zig` parity cleanup

Most major functionality exists, but some upstream semantics still need stronger proof and possibly refinement.

Remaining:

- review current behavior for any still-questionable cases around:
  - alias materialization boundaries
  - lexical node self-child emission
  - hidden-node inheritance in cases not already covered by current goldens
  - supertype behavior beyond the implemented hidden-supertype emission rule
- decide which of those should be fixed now versus documented as Milestone 4+ work

Done when:

- additional tricky fixtures do not force structural changes to node-type aggregation

### 4. stronger golden fixtures

Current goldens are broad enough that this is now a closeout task, not a buildout task.

Current coverage already includes:

- aliases and alias-visible children
- externals
- extras
- supertypes
- hidden wrappers
- repeat-heavy choice/sequence shapes
- multiple fields across alternatives
- optional fields inherited through hidden wrappers
- external fields inherited through hidden wrappers

Done when:

- no additional uncovered artifact class is found during closeout review

### 5. Milestone 3 closeout

Before declaring completion:

- update this checklist and `README.md` to reflect the real end state
- decide which remaining parity gaps are acceptable for Milestone 3 and which are explicitly deferred to Milestone 4+
- document any explicitly deferred extraction or node-type mismatches

## Status By Task Group

### Task Group A: Post-prepared IR

Status:

- mostly done for Milestone 3 needs

Remaining:

- decide whether `src/ir/aliases.zig` is sufficient as-is or needs richer lookup helpers once flattening begins
- add `src/ir/variable_info.zig` only if node-type computation becomes awkward without a dedicated intermediate type

Exit criteria:

- no new IR redesign should be needed once flattening starts

### Task Group B: Token Extraction

Status:

- implemented and in parity cleanup

Already implemented:

- lexical extraction for string/pattern/token-marked rules
- syntax-side terminal replacement
- extras vs separators split
- basic metadata carry-through
- external token carry-through
- extracted-graph rewrites for:
  - `word_token`
  - precedence symbol entries
  - `SYMBOL` extras
  - conflict members
- extraction-stage validation for invalid:
  - inline symbols
  - conflict symbols
  - precedence symbols
  - supertype symbols
  - supertype structures through externals
  - word tokens

Remaining:

- compare `extract_tokens.zig` more closely against upstream `extract_tokens.rs` for:
  - remaining word-token edge cases
  - reserved-word token restrictions
  - external-token behavior
  - any remaining supertype edge cases worth rejecting earlier
  - whether any still-syntax-side symbol-wrapper paths are intentional or should be reworked later

Exit criteria:

- token extraction is stable enough that node-type work does not need to reinterpret symbol categories or stale references

### Task Group C: Repeat Expansion

Status:

- done for Milestone 3 unless closeout review finds a mismatch

Already implemented:

- explicit repeat auxiliaries
- auxiliary reuse for repeated content
- hidden top-level repeat promotion
- nested repeat regression coverage

Remaining:

- none unless another fixture exposes a mismatch

Exit criteria:

- no raw repeat semantics remain as a blocker for flattening

### Task Group D: Grammar Flattening

Status:

- implemented in initial form

Already implemented:

- `src/grammar/prepare/flatten_grammar.zig`
- duplicate production deduplication
- metadata preservation through deduplication
- empty-string validation outside the start rule
- recursive-inline rejection

Remaining:

- compare more closely against upstream flattening behavior for nested structure normalization if future fixtures expose gaps
- decide whether a dedicated flattened IR is still needed or whether the current `SyntaxGrammar` form is sufficient

Exit criteria:

- downstream code can iterate productions without recursive syntax-rule descent

### Task Group E: Alias Extraction And Variable Info

Status:

- implemented, with room for more parity proof

Already implemented:

- `src/grammar/prepare/extract_default_aliases.zig`
- default-alias extraction for syntax, lexical, and external symbols
- redundant explicit alias clearing

Remaining:

- decide whether a dedicated `variable_info` IR is still warranted or unnecessary for Milestone 3
- document current alias-materialization behavior if it remains intentionally different from upstream in any uncovered edge case

Exit criteria:

- node-type computation can ask questions about aliases and variable identity without re-walking raw productions

### Task Group F: Node-Type Computation And Rendering

Status:

- implemented and usable, with parity cleanup remaining

Already implemented:

- `src/node_types/compute.zig`
- `src/node_types/render_json.zig`
- `src/node_types/pipeline.zig`
- deterministic JSON rendering
- hidden-wrapper inheritance
- duplicate node-type canonicalization
- CLI preview and output path
- exact golden fixtures for several curated grammars

Remaining:

- perform a final review against upstream expectations rather than only internal current-output goldens
- decide whether any remaining alias-materialization or lexical-node-shape differences should be fixed now or documented as Milestone 4+ work

Exit criteria:

- `node-types.json` is emitted deterministically for at least one curated grammar and matches the expected output

### CLI And Test Integration

Status:

- implemented

Already implemented:

- debug preview path for `node-types.json`
- `generate --output <dir>` writing `node-types.json`
- exact pipeline and CLI artifact tests

Remaining:

- add more mixed-semantic golden fixtures only if the closeout review exposes a missing artifact class
- decide whether any additional user-facing output mode is needed before Milestone 3 closeout

Exit criteria:

- the artifact can be exercised from the CLI and compared in tests

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

From the current code state, implementation should continue with:

1. audit `extract_tokens.zig` one final time against upstream and record any intentional Milestone 3 deferrals
2. review the current golden set for any remaining `compute.zig` behavior that still looks upstream-questionable
3. fix only the parity gaps that are still worth closing in Milestone 3
4. add another golden fixture only if that review reveals a still-uncovered artifact class
5. update docs and perform a Milestone 3 completion review

That is the shortest path from the current code state into a clean Milestone 3 closeout.
