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
- the repo currently relies on distinct proof layers, not one uniform compatibility claim:
  - curated fixture proof:
    - emitted parser.c-like goldens
    - compile smoke tests
    - structural compatibility checks
    - local behavioral harness checks
  - real external snapshot proof:
    - dedicated machine-readable inventory for promoted external-repo snapshots under `compat_targets/external_repo_inventory.json`
  - real external scanner proof:
    - dedicated machine-readable inventory for real external scanner-family evidence under `compat_targets/external_scanner_repo_inventory.json`
  - parser-only shortlist proof:
    - versioned checked-in artifacts under `compat_targets/`
  - staged scanner-boundary proof:
    - the promoted scanner-wave entries in those same checked-in artifacts
- the dedicated external-repo inventory keeps real snapshot evidence visible even when the main shortlist still includes staged fixtures, frozen controls, and deferred larger parser-only targets
- parser-only shortlist proof currently comes from versioned checked-in artifacts:
  - `compat_targets/shortlist.json`
  - `compat_targets/shortlist_inventory.json`
  - `compat_targets/shortlist_report.json`
- real external snapshot proof currently comes from:
  - `compat_targets/external_repo_inventory.json`
- real external scanner proof currently comes from:
  - `compat_targets/external_scanner_repo_inventory.json`
- that dedicated external scanner artifact now records:
  - `tree_sitter_haskell_json` as a passing sampled real external scanner snapshot
  - `tree_sitter_bash_json` as a passing sampled real external scanner snapshot
  - machine-readable `proof_scope` values so those two sampled proofs are distinguished in JSON rather than only in notes
- the currently checked-out `tree-sitter-c` and `tree-sitter-zig` repos do not change that state for this milestone because both available `src/grammar.json` snapshots declare `externals: []` and neither repo includes a scanner implementation file
- the current real external scanner boundary is explicit:
  - `tree_sitter_haskell_json` passes within a sampled external-sequence proof layer after structural first-boundary extraction
  - `tree_sitter_bash_json` passes within a narrower sampled expansion path built around `_bare_dollar` and `variable_name`
  - both remain narrower than full runtime scanner support
- the staged scanner-boundary claim and the real external scanner claim remain separate:
  - staged scanner proof covers promoted in-repo scanner families inside the shortlist artifacts
  - real external scanner proof covers the promoted Haskell and Bash snapshots inside `external_scanner_repo_inventory.json`
- `compat_targets/README.md` explains the relationship between shortlist policy, aggregate boundary, mismatch inventory, and coverage decision artifacts
- the checked-in shortlist inventory and full report now expose family-level coverage alongside aggregate target totals
- the current parser-only shortlist boundary is now explicit and broader than the original staged wave:
  - 5 intended first-wave parser-only targets currently pass within the staged boundary
  - 1 real external parser-only target is now onboarded but explicitly deferred at a parser boundary
  - 1 staged deferred target remains intentionally frozen as an ambiguity/control fixture
  - that control case is now classified explicitly as a `frozen_control_fixture` in the checked-in reports rather than being counted as a normal pass
  - 6 scanner/external-scanner targets now pass within the current sampled boundary across 4 grammar families
- the currently represented families are:
  - parser-only:
    - `parse_table_tiny`
    - `behavioral_config`
    - `repeat_choice_seq`
    - `ziggy`
    - `ziggy_schema`
    - `c`
    - `parse_table_conflict`
  - scanner/external-scanner:
    - `hidden_external_fields`
    - `mixed_semantics`
    - `haskell`
    - `bash`
- scanner/external-scanner repo proof remains narrower than full runtime parity and is currently limited to the staged first-boundary checks plus two sampled real external scanner proofs with different scope
- `mixed_semantics` widens that scanner proof by showing that a grammar can still carry extras elsewhere while remaining compatible on a narrower first-boundary sample path
- compatibility-sensitive behavioral proof currently covers:
  - `behavioral_config`
  - `hidden_external_fields`
- `repeat_choice_seq` still preserves deterministic JSON/JS parity and progress, but now rejects on the staged blocked path as `missing_action`
- the top-level `generate` CLI does not yet expose emitted `parser.c`, emitted `grammar.json`, or compatibility reports as first-class outputs
- the current checked-in coverage decision now recommends second-wave parser-only repo coverage because the larger real external `tree_sitter_c_json` snapshot is explicitly deferred at a parser proof boundary rather than already promoted
- the routine compatibility refresh and the heavier deferred parser probe are now separated explicitly:
  - `update_compat_artifacts.zig` owns the routine checked-in compatibility surfaces
  - `update_parser_boundary_probe.zig` is reserved for standalone deeper parser-boundary investigation
  - `compat_targets/artifact_manifest.json` records that split machine-readably

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
