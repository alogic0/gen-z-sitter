# Zig Tree-sitter Rewrite Notes

This directory contains planning documents for a Zig rewrite of the Tree-sitter generator/tooling stack.

Milestone 3 is complete. Milestone 4 is also complete: the deferred `node-types.json` parity work has been implemented, including the later post-processing cleanup around supertypes and final node ordering.

Milestone 5 is well underway and now has the core parser-table foundation in place:

- parser item/state IR
- deterministic narrow LR(0)-style state construction
- structured conflict reporting
- exact parser-state dump goldens for both simple and conflict grammars
- deterministic state-reuse coverage

The remaining Milestone 5 work is mainly closeout around the currently supported subset and explicit deferrals to later parser-generation milestones.

## Documents

- [MASTER_PLAN.md](./MASTER_PLAN.md)
- [MILESTONE_1_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_1_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_2_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_2_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_3_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_3_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_4_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_4_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_5_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_5_IMPLEMENTATION_CHECKLIST.md)
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
