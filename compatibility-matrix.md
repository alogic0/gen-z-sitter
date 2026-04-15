# Zig Generator Compatibility Matrix

## Purpose

Define what compatibility means for a Zig rewrite of `tree-sitter generate`, and how each behavior should be validated.

## Compatibility Levels

Use four compatibility levels:

- `Exact`: byte-for-byte or textually identical output
- `Stable`: semantically identical and deterministic, but textual formatting may differ
- `Equivalent`: behavior matches in generated parser/runtime outcomes
- `Deferred`: acceptable to differ in early milestones

## Input Compatibility

| Area | Requirement | Level | Validation |
|---|---|---:|---|
| `grammar.json` loading | Accept current schema used by Tree-sitter grammars | Exact | fixture decode tests |
| `grammar.js` loading via Node | Accept current DSL bootstrap contract | Stable | integration against real grammars |
| path handling | support file and explicit path arguments | Stable | CLI integration tests |
| ABI option | support ABI version selection | Exact | golden output and compile tests |
| `--no-parser` | emit only JSON artifacts | Exact | output presence tests |
| state reporting flags | same flag meaning | Stable | report fixture tests |

## Output Compatibility

| Artifact | Requirement | Level | Validation |
|---|---|---:|---|
| `src/grammar.json` | schema-compatible normalized grammar | Stable | JSON semantic compare |
| `src/node-types.json` | same node/type/field semantics | Stable | canonical JSON compare |
| `src/parser.c` | compilable and ABI-compatible parser source | Equivalent | compile + corpus parse tests |
| conflict JSON summary | same data model and meaning | Stable | JSON schema compare |
| state reports | same rule/state meaning | Deferred | textual spot checks |

## Semantic Compatibility

| Area | Requirement | Level | Validation |
|---|---|---:|---|
| grammar rejection | invalid grammars fail in the same cases | Equivalent | error fixture tests |
| parse table semantics | generated parser accepts/rejects same corpus | Equivalent | corpus parse compare |
| external tokens | scanner interactions preserve behavior | Equivalent | scanner fixture tests |
| aliases | visible node kinds and fields preserved | Stable | node-types + parse-tree compare |
| supertypes | same supertype relationships | Stable | canonical node-types compare |
| precedence/conflicts | same ambiguity resolution | Equivalent | parse-tree compare on targeted fixtures |

## Diagnostics Compatibility

| Area | Requirement | Level | Validation |
|---|---|---:|---|
| major error class | same broad reason for failure | Equivalent | fixture assertions |
| rule attribution | mention same offending rule where possible | Stable | fixture assertions |
| message wording | identical prose | Deferred | not required early |
| report structure | same JSON keys where output is machine-consumed | Stable | schema tests |

## Determinism Requirements

The Zig generator must be deterministic across repeated runs with identical inputs:

- symbol ordering must not depend on hash map iteration order
- rendered JSON key order must be stable
- rendered C table order must be stable
- conflict/state reporting must be stable

Validation:

- run the same fixture multiple times in one test
- hash outputs and assert equality

## Milestone Compatibility Targets

### Milestone 1

- `grammar.json` decode works
- invalid schema failures are structured
- determinism on raw decode summaries

### Milestone 2

- prepared grammar matches Rust generator on curated fixtures
- symbol IDs and normalized rule ordering are stable

### Milestone 3

- `node-types.json` is semantically identical

### Milestone 4

- `grammar.json` output is semantically identical and deterministic

### Milestone 5

- lexical structures are behaviorally equivalent on token-focused fixtures

### Milestone 6-7

- `parser.c` compiles
- generated parsers behave equivalently on corpora

### Milestone 9

- `grammar.js` path is supported through Node without manual conversion

## Comparison Modes

Use three comparison modes in tests.

### Canonical JSON compare

- parse JSON
- sort object keys
- normalize formatting
- compare values

Use for:

- `grammar.json`
- `node-types.json`
- report JSON

### Text compare

- compare rendered text directly

Use for:

- selected `parser.c` samples
- CLI diagnostics where exactness matters

### Behavioral compare

- compile generated parser
- parse fixture corpus
- compare parse trees and failures

Use for:

- final parser equivalence

## Known Areas Where Exactness May Be Unnecessary

- whitespace and indentation in `parser.c`
- ordering of non-semantic helper declarations in `parser.c`
- wording details in human-readable diagnostics
- formatting of state dumps

These can differ if:

- outputs remain deterministic
- machine-consumed structure is preserved
- behavior is equivalent

## Known Areas Where Exactness Matters

- ABI version values
- symbol visibility semantics
- field names and node kinds
- grammar rejection vs acceptance
- `node-types.json` meaning
- external token numbering and symbol ordering where it affects runtime behavior

## Regression Policy

Any compatibility bug should be classified as one of:

- input contract mismatch
- normalization mismatch
- lexical mismatch
- parse-table mismatch
- render-only mismatch
- diagnostic mismatch

Every fixed bug should add one of:

- a fixture-level semantic test
- a golden JSON compare
- a parser corpus equivalence test
