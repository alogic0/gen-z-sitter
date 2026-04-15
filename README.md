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

The next parser-generation work is now Milestone 8:

- whether shift-side precedence semantics need one more expansion now
- whether reduce/reduce resolution stays deferred
- whether builder-owned resolved actions are required before closeout
- and how far parser-decision semantics should be stabilized before table serialization work

Milestone 8 is now underway and already implements:

- builder-owned resolved actions in `BuildResult`
- an explicit `reduce_reduce_deferred` policy boundary
- richer shift-side precedence support at the direct resolver boundary for:
  - integer precedence
  - named precedence

The remaining Milestone 8 work is narrower:

- whether to add one more semantic rule beyond the current supported subset
- or close the milestone and defer the remaining parser-decision gaps to the next milestone

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
