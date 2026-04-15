# Zig Tree-sitter Rewrite Notes

This directory contains planning documents for a Zig rewrite of the Tree-sitter generator/tooling stack.

Milestone 3 is complete. Milestone 4 is in closeout review: the two main deferred `node-types.json` parity targets are implemented, and the remaining work is limited to smaller upstream post-processing differences documented in the Milestone 4 checklist.

## Documents

- [MASTER_PLAN.md](./MASTER_PLAN.md)
- [MILESTONE_1_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_1_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_2_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_2_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_3_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_3_IMPLEMENTATION_CHECKLIST.md)
- [MILESTONE_4_IMPLEMENTATION_CHECKLIST.md](./MILESTONE_4_IMPLEMENTATION_CHECKLIST.md)
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
