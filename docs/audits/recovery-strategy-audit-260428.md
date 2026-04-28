# Recovery Strategy Audit — 2026-04-28

Upstream references:

- `../tree-sitter/lib/src/parser.c`
- `../tree-sitter/lib/src/subtree.c`
- `../tree-sitter/lib/src/subtree.h`

## Upstream Shape

Tree-sitter recovery has three relevant surfaces for this project:

- Recover to a previous stack state when the current lookahead is valid there.
- If recovery stays in error state, wrap or skip the current lookahead token
  and re-lex from the next byte position.
- When more invalid input follows, extend the existing error span instead of
  treating every skipped byte as an unrelated parse failure.

Upstream ranks versions with subtree error cost. Skipped trees, skipped bytes,
skipped lines, missing trees, and recovery steps all contribute to cost.

## Local Status

Behavioral harness:

- Previous-state recovery is implemented in `recoverFromMissingAction`.
- Skip-and-relex is implemented for both recognized but unwanted tokens and
  unrecognized bytes.
- Consecutive unrecognized bytes are represented as aggregated recovery
  counters and error cost. The temporary `ParseNode` tree model does not yet
  build Tree-sitter-compatible ERROR nodes.

Emitted generated parser:

- Previous-state recovery is emitted through
  `ts_generated_recover_to_stack_action`.
- Skip-and-relex is emitted in `ts_generated_drive_version`.
- `TSGeneratedParseResult` exposes `error_count`, `error_cost`,
  `recovery_attempts`, `stack_recoveries`, `skipped_tokens`, and
  `skipped_bytes`.

## Remaining Difference

The current project surface tracks recovery metrics and tree strings for the
temporary generated result API. It does not yet reproduce upstream ERROR-node
subtree construction, ERROR-repeat coalescing, or public `TSTree`/`TSNode`
ownership semantics. Those belong to a future compatible tree ABI plan, not to
the current temporary runtime proof.
