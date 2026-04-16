# Zig Generator Compatibility Matrix

## Purpose

Define what compatibility means for a Zig rewrite of `tree-sitter generate`, and how each behavior should be validated.

This document mixes two scopes on purpose:

- the long-term compatibility target for the project
- the current staged compatibility boundary that the repo can actually claim today

Unless a section explicitly says otherwise, table entries below describe the intended target contract, not necessarily the current top-level CLI surface.

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
| ABI option | support ABI version selection in the eventual top-level contract | Exact | golden output and compile tests |
| `--no-parser` | emit only JSON artifacts in the eventual top-level contract | Exact | output presence tests |
| state reporting flags | preserve the same meaning once surfaced as first-class top-level features | Stable | report fixture tests |

## Output Compatibility

| Artifact | Requirement | Level | Validation |
|---|---|---:|---|
| `src/grammar.json` | schema-compatible normalized grammar once exposed as a top-level emitted artifact | Stable | JSON semantic compare |
| `src/node-types.json` | same node/type/field semantics | Stable | canonical JSON compare |
| `src/parser.c` | compilable and ABI-compatible parser source at the eventual target boundary; current repo state is still a staged parser.c-like compatibility surface | Equivalent | compile + corpus parse tests |
| conflict JSON summary | same data model and meaning | Stable | JSON schema compare |
| state reports | same rule/state meaning | Deferred | textual spot checks |

## Semantic Compatibility

| Area | Requirement | Level | Validation |
|---|---|---:|---|
| grammar rejection | invalid grammars fail in the same cases | Equivalent | error fixture tests |
| parse table semantics | generated parser accepts/rejects same corpus at the eventual target boundary; current staged proof is narrower | Equivalent | corpus parse compare |
| external tokens | scanner interactions preserve behavior; current staged proof covers only the first external-token boundary | Equivalent | scanner fixture tests |
| aliases | visible node kinds and fields preserved | Stable | node-types + parse-tree compare |
| supertypes | same supertype relationships | Stable | canonical node-types compare |
| precedence/conflicts | same ambiguity resolution | Equivalent | parse-tree compare on targeted fixtures |
| hidden start rule | reject grammars whose first rule is hidden | Equivalent | lowering fixture tests |
| internal vs external names | prefer internal rule names over duplicate external-token names | Stable | lowering fixture tests |
| missing inline targets | ignore unresolved inline names instead of rejecting the grammar | Stable | lowering fixture tests |
| named precedence declarations | reject uses of undeclared named precedences | Equivalent | lowering fixture tests |
| metadata wrapper collapse | preserve merged field/alias/precedence/token/reserved semantics through lowering | Stable | prepared-IR tests |

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

## Current Staged Boundary

What the repo can credibly claim today:

- `grammar.json` and `grammar.js` loading paths are implemented and exercised
- `node-types.json` output is the most directly surfaced top-level generated artifact
- parser/runtime compatibility work is currently validated mostly through:
  - emitted parser.c-like goldens
  - compile smoke tests
  - structural compatibility checks
  - local behavioral harness checks
- parser-only compatibility coverage now also has a versioned shortlist and checked-in boundary artifact:
  - `compat_targets/shortlist.json`
  - `compat_targets/shortlist_inventory.json`
- the current parser-only shortlist boundary is narrower than real external-repo proof:
  - 3 intended first-wave parser-only targets currently pass within the staged boundary
  - 1 deferred later-wave target is tracked separately for mismatch expansion
  - 1 external-scanner target is tracked explicitly as out of scope
- compatibility-sensitive behavioral proof currently covers:
  - `behavioral_config`
  - `hidden_external_fields`
- `repeat_choice_seq` still preserves deterministic JSON/JS parity and progress, but remains on the staged `unresolved_decision` boundary for its valid path
- the top-level `generate` CLI does not yet expose emitted `parser.c`, emitted `grammar.json`, or compatibility reports as first-class outputs

## Milestone Compatibility Targets

### Milestone 1

- `grammar.json` decode works
- invalid schema failures are structured
- determinism on raw decode summaries

### Milestone 2

- prepared grammar matches Rust generator on curated fixtures
- symbol IDs and normalized rule ordering are stable
- hidden-start, internal-over-external, missing-inline, supertype-hiding, and named-precedence semantics match upstream interning behavior

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
