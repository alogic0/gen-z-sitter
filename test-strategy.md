# Zig Generator Test Strategy

## Purpose

Define the test layers needed to make a Zig rewrite of `tree-sitter generate` credible.

The rewrite is too risky for end-to-end tests alone. The test strategy must catch:

- schema and normalization bugs
- lexical bugs
- parse-table bugs
- rendering bugs
- compatibility regressions

## Test Layers

Use five layers:

1. unit tests
2. snapshot tests
3. fixture integration tests
4. semantic equivalence tests
5. determinism tests

## 1. Unit Tests

### Scope

- JSON decode helpers
- symbol interning
- normalization passes
- metadata handling
- repeat expansion
- lexical helper utilities
- item closure and goto logic
- rendering escapes

### Goal

Catch local logic bugs without requiring a full parser build.

### Rule

Every algorithmic helper should have at least one direct unit test.

## 2. Snapshot Tests

### Scope

Use small grammars to snapshot intermediate structures:

- prepared symbol tables
- normalized rule trees
- extracted lexical grammar
- item sets
- conflict summaries

### Goal

Make internal regressions visible before they surface in generated C.

### Format

Prefer compact text dumps over binary snapshots.

## 3. Fixture Integration Tests

### Scope

Run the generator against real fixture grammars.

Primary source:

- Tree-sitter fixture grammars already used by the upstream project

Classify fixtures into:

- should generate successfully
- should fail validation
- should fail conflict checks

### Assertions

- exit status
- expected artifact presence
- diagnostic class

## 4. Semantic Equivalence Tests

### Scope

For selected grammars:

- generate with Rust
- generate with Zig
- compile both
- parse the same corpus inputs
- compare parse trees

### Goal

Catch semantic differences even if text output differs.

### Priority Targets

- simple expression grammar
- precedence grammar
- associativity grammar
- external scanner grammar
- lexical conflict grammar

## 5. Determinism Tests

### Scope

Run the Zig generator multiple times on the same input and assert:

- identical JSON output
- identical `parser.c`
- identical report output

### Goal

Prevent hash-order or allocator-order bugs.

## Test Data Categories

### Tiny hand-authored grammars

Use for:

- unit and snapshot tests
- fast iteration

### Upstream fixture grammars

Use for:

- integration and semantic tests

### Minimized regression grammars

Use for:

- preserving fixes for discovered bugs

## Output Comparison Methods

### Canonical JSON compare

Use for:

- `grammar.json`
- `node-types.json`
- JSON reports

Method:

- parse JSON
- sort keys canonically
- compare values

### Text compare

Use for:

- compact intermediate dumps
- selected `parser.c` tests

### Behavioral compare

Use for:

- parser semantics

Method:

- compile generated parser
- run corpus parses
- compare tree output

## Parser Compilation Tests

At minimum, curated semantic tests should:

- compile generated `parser.c`
- compile `scanner.c` when present
- link against the C runtime
- run parse checks on real input

The first version can use a simple helper harness rather than full packaging parity.

## Negative Testing

Negative tests are mandatory.

Required categories:

- malformed schema
- missing symbols
- invalid inline/supertype references
- precedence misuse
- unresolved conflicts
- unsupported grammar forms if temporarily deferred

Each negative test should assert:

- failure occurs
- failure is attributed to the correct subsystem

## Milestone-Based Test Plan

### Milestone 0

- allocator and CLI smoke tests
- diagnostics formatting tests

### Milestone 1

- `grammar.json` decode tests
- schema-negative tests

### Milestone 2

- prepared IR snapshots
- invariant validation tests

### Milestone 3-4

- JSON artifact canonical compare tests

### Milestone 5

- lexical snapshot tests
- token-conflict fixture tests

### Milestone 6-7

- state dump tests
- parser compile tests
- corpus semantic equivalence tests

### Milestone 9+

- `grammar.js` subprocess integration tests

## CI Recommendations

Have at least three CI groups:

- fast: unit + small snapshots
- medium: fixture integration
- slow: semantic equivalence with parser compilation

This allows frequent feedback without making every iteration expensive.

## Failure Triage Policy

When a test fails, classify it immediately:

- decode/validation
- normalization
- lex
- parse-table
- render
- compare harness

This should map directly to code ownership areas or module groups.

## Immediate Test Harness Priorities

Build these helpers first:

1. fixture loader
2. stable text snapshot writer/comparer
3. canonical JSON comparator
4. parser compile-and-run helper
5. corpus parse tree comparator

Without these helpers, debugging later milestones will be slow.
