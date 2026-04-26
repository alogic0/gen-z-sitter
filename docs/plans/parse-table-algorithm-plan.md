# Parse-Table Algorithm Plan

## Purpose

Define how to approach the highest-risk part of the Zig rewrite: constructing syntax tables equivalent to Tree-sitter's current generator.

This document is an implementation plan, not a proof of correctness.

## Scope

This covers:

- item representation
- item set construction
- transitions
- reductions
- conflict handling
- minimization
- reporting hooks

It does not cover:

- `grammar.js` loading
- node-types generation
- final C rendering details

## Strategy

Do not try to reproduce the final optimized tables immediately.

Build the parse-table subsystem in four stages:

1. unoptimized canonical structures
2. correct transitions and reductions
3. conflict behavior and reporting
4. minimization and compatibility refinements

## Core Data Types

```zig
pub const Item = struct {
    production_id: ProductionId,
    step_index: u16,
    lookahead_set_id: LookaheadSetId,
};

pub const ItemSet = struct {
    id: StateId,
    items: []Item,
};

pub const Transition = struct {
    symbol: SymbolId,
    state: StateId,
};

pub const Reduction = struct {
    symbol: SymbolId,
    production_id: ProductionId,
    dynamic_precedence: i16,
    associativity: Assoc,
};
```

Names may change, but the separation should remain:

- items
- states
- transitions
- reductions
- lookahead sets

## Stage 1: Canonical Item Builder

### Deliverables

- production expansion
- closure computation
- goto computation
- stable item ordering

### Requirements

- deterministic state construction
- deterministic item ordering within states
- ability to dump item sets for debugging

### Validation

- tiny grammars with hand-checked state graphs
- snapshot tests for item sets

## Stage 2: Transition and Reduction Construction

### Deliverables

- per-state symbol transitions
- reduction sets
- terminal vs non-terminal split
- accept-state handling

### Requirements

- no minimization yet
- no state merging yet
- prioritize transparent correctness

### Validation

- generate state graphs for tiny grammars
- compare selected transitions against Rust behavior

## Stage 3: Conflict Classification

### Deliverables

- shift/reduce classification
- reduce/reduce classification
- expected conflict matching
- precedence/associativity influence
- conflict reporting data model

### Requirements

- preserve distinction between resolvable and unresolvable conflicts
- report unresolved conflicts in a structured way

### Validation

- fixture grammars that intentionally fail with conflicts
- fixtures with expected conflicts
- fixtures with precedence-controlled ambiguity

## Stage 4: Minimization and Table Refinement

### Deliverables

- state equivalence checks
- optional merge-states optimization
- compact parse action representation

### Requirements

- optimization must be optional
- unoptimized and optimized builds must remain semantically equivalent

### Validation

- compare parse outcomes before and after minimization
- ensure deterministic state numbering policy

## State Numbering Policy

State numbering drift can make debugging difficult.

Recommended policy:

- assign state IDs in discovery order
- preserve discovery order in the unoptimized pipeline
- if minimization changes numbering, expose a debug mapping from pre-merge to final states

This is not strictly required for compatibility, but it helps differential debugging.

## Conflict Resolution Policy

Represent conflict resolution as a separate pass.

Inputs:

- raw candidate actions
- precedence metadata
- associativity metadata
- expected conflict sets

Outputs:

- resolved actions
- unresolved conflict records
- reportable explanations

This is preferable to burying precedence logic inside item construction.

## Suggested Modules

```text
src/parse_table/
  production.zig
  item.zig
  lookahead.zig
  closure.zig
  goto.zig
  item_set_builder.zig
  actions.zig
  reductions.zig
  conflicts.zig
  precedence.zig
  minimize_parse_table.zig
  debug_dump.zig
```

## Differential Debugging Plan

When the Zig generator diverges from Rust, debug intermediate representations in this order:

1. prepared grammar
2. productions
3. item closure
4. state transitions
5. candidate reductions
6. conflict resolution decisions
7. minimized table output

Do not jump directly to `parser.c` diffs.

## Test Grammar Progression

Introduce grammars in increasing complexity:

1. single literal rule
2. simple sequence
3. simple choice
4. precedence example
5. associativity example
6. inline/supertype example
7. lexical conflict example
8. external token example
9. expected conflict fixture

Each progression step should have:

- state dump goldens
- parse behavior assertions

## Observability Requirements

Build debug dumps from day one:

- productions dump
- item set dump
- transitions dump
- reductions dump
- unresolved conflict dump

A large part of the risk is invisibility. The subsystem should be inspectable.

## Performance Guidance

Early implementation priorities:

- deterministic and clear structures
- straightforward hashing and equality
- reusable debug dumps

Do not optimize for:

- allocation count
- compressed table representation
- merge-state heuristics

until correctness is established.

## Exit Criteria for "Parse-Table Correct Enough"

The subsystem is ready for integration when:

- simple and medium grammars generate compilable parsers
- conflict fixtures fail as expected
- precedence fixtures parse correctly
- parser outputs match Rust behavior on curated corpus tests
- minimization can be enabled without semantic change
