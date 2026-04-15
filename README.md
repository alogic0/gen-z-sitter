# Zig Tree-sitter Rewrite Notes

This directory contains planning documents for a Zig rewrite of the Tree-sitter generator/tooling stack.

Milestone 3 is complete. Milestone 4 is also complete: the deferred `node-types.json` parity work has been implemented, including the later post-processing cleanup around supertypes and final node ordering.

Milestone 5 is complete and establishes the first parser-table foundation:

- parser item/state IR
- deterministic narrow LR(0)-style state construction
- structured conflict reporting
- exact parser-state dump goldens for both simple and conflict grammars
- deterministic state-reuse coverage
- focused reduce/reduce conflict coverage through the real preparation pipeline

The remaining parser-generation work is now Milestone 7+:

- broader grammar support beyond the current narrow LR(0)-style subset
- conflict resolution
- parse-table serialization and eventual `parser.c` emission

Milestone 6 is complete and includes:

- FIRST-set computation
- lookahead-aware closure propagation
- explicit parse-action IR
- builder-owned action tables
- action-derived conflict reporting
- exact state, action-table, and grouped-action-table goldens across tiny, conflict, reduce/reduce, and metadata-rich fixtures

Milestone 7 is complete and implements a real supported resolution subset:

- integer precedence in both directions
- named precedence in both directions when directly ordered against the conflicted symbol
- dynamic precedence in both directions
- dynamic-versus-named precedence priority on the reduce side
- equal-precedence associativity handling
- explicit unresolved classification for shift/reduce and reduce/reduce cases

Milestone 8 is complete and established the next parser-decision boundary before serialization:

- builder-owned resolved actions in `BuildResult`
- an explicit `reduce_reduce_deferred` policy boundary
- richer shift-side precedence support at the direct resolver boundary for:
  - integer precedence
  - named precedence

Milestone 9 is complete and establishes the final pre-serialization parser-decision handoff:

- serializer-facing resolved decisions via `ResolvedDecision`
- structured chosen and unresolved decision refs
- explicit readiness checks on both `ResolvedActionTable` and `BuildResult`
- a single serializer-facing `DecisionSnapshot`
- real-path tests for both serialization-ready and blocked grammars

Milestone 9 closes with two explicit boundary decisions:

- `DecisionSnapshot` is the pre-serialization handoff
- `reduce_reduce_deferred` remains the explicit unresolved reduce/reduce boundary

Milestone 10 is complete and establishes the first real serialization/code-emission boundary:

- serialized parse-table IR
- explicit ready vs blocked serialization behavior
- deterministic serialized-table artifacts
- the first narrow emitter-facing boundary on top of serialized parser data

Milestone 10 includes:

- `src/parse_table/serialize.zig` as the serialized parse-table boundary
- explicit strict vs diagnostic serialization policy
- exact serialized-table goldens for ready and blocked grammars
- a first textual emitter-facing parser-table skeleton
- a first C-like table skeleton consumer of serialized parser data

Milestone 11 is complete and establishes the first broader parser-emission boundary on top of `SerializedTable`.

Milestone 11 includes:

- a broader `parser.c`-like emitter on top of `SerializedTable`
- exact real-path emitter goldens for ready and blocked grammars
- shared emitter helpers in `src/parser_emit/common.zig`
- a broader emitted parser translation unit with:
  - per-state arrays
  - state-table descriptors
  - a top-level parser descriptor
  - basic accessor/query helpers

Milestone 12 is complete and establishes a richer runtime-facing parser-emission boundary.

Milestone 12 includes:

- richer parser output on top of the Milestone 11 boundary
- a clearer runtime-facing emitted API boundary
- deterministic richer parser-emission goldens
- explicit blocked behavior at that richer emitted boundary
- emitted parser helpers for:
  - parser-level queries
  - per-state queries
  - indexed entry access
  - field-level access
  - symbol-based lookup
  - predicate helpers

Milestone 13 is complete and establishes the first compatibility-oriented parser boundary.

Milestone 13 includes:

- an explicit emitted API scope before any ABI claim
- compatibility layering through an intermediate layer rather than a direct upstream ABI claim
- richer parser output beyond the Milestone 12 helper/query layer
- exact ready/blocked artifacts for the richer runtime-facing parser surface
- explicit blocked-output behavior at the richer runtime-facing layer
- richer compatibility-oriented emitted helpers, including:
  - runtime summary structs
  - state summary access
  - symbol-based lookup
  - predicate helpers

Milestone 14 is complete:

- `grammar.js` end-to-end support through a `node` subprocess path
- `grammar.json` kept as the native/core path
- deterministic `grammar.json`, `node-types.json`, and parser emission through the JS loading path
- non-Node JS runtimes explicitly deferred

Milestone 15 is complete:

- first concrete parser/runtime compatibility target
- centralized ABI/version handling
- structural compatibility checks for ready and blocked parser output
- deterministic emitted symbol-table contract and symbol accessors
- explicit remaining compatibility mismatches deferred to later milestones

The next parser-generation work is now Milestone 16:

- behavioral equivalence and corpus verification
- compiled-parser comparison against upstream generated output
- classification of remaining semantic mismatches

The next promoted execution checklist after the first behavioral-equivalence stage is:

- [LEXER_SCANNER_CHECKLIST.md](./LEXER_SCANNER_CHECKLIST.md)
  - first lexer/scanner emission boundary
  - deterministic lexer/scanner artifacts
  - staged proof before external scanner integration and broader compatibility hardening

## Documents

- [MASTER_PLAN.md](./MASTER_PLAN.md)
- [MILESTONE_1_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_1_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_2_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_2_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_3_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_3_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_4_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_4_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_5_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_5_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_6_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_6_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_7_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_7_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_8_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_8_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_9_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_9_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_10_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_10_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_11_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_11_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_12_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_12_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_13_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_13_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_15_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_15_IMPLEMENTATION_CHECKLIST.md)
- [BEHAVIORAL_EQUIVALENCE_CHECKLIST.md](./BEHAVIORAL_EQUIVALENCE_CHECKLIST.md)
- [LEXER_SCANNER_CHECKLIST.md](./LEXER_SCANNER_CHECKLIST.md)
- [NEXT_DIRECTION_CHECKLIST.md](./NEXT_DIRECTION_CHECKLIST.md)
- [LATER_WORK_CHECKLIST.md](./LATER_WORK_CHECKLIST.md)
- [zig-generator-architecture.md](./zig-generator-architecture.md)
- [compatibility-matrix.md](./compatibility-matrix.md)
- [prepared-grammar-ir.md](./prepared-grammar-ir.md)
- [parse-table-algorithm-plan.md](./parse-table-algorithm-plan.md)
- [test-strategy.md](./test-strategy.md)
- [milestone-0-task-list.md](./milestone-0-task-list.md)

## Project Commands

- `zig build`
- `zig build test`
- `zig build run -- help`
- `zig build run -- generate path/to/grammar.json`
- `zig build run -- generate --debug-prepared path/to/grammar.json`

## Suggested Reading Order

1. master plan
2. milestone 1 checklist
3. milestone 2 checklist
4. milestone 3 checklist
5. architecture
6. compatibility matrix
7. prepared grammar IR
8. test strategy
9. milestone 0 task list
10. parse-table algorithm plan
