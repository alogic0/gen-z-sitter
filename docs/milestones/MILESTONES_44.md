# MILESTONES 44

## Goal

Move the tokenizer from the current matcher-driven approximation to a real tree-sitter-style lexer pipeline:

- build reusable lexer states from valid token sets
- assign parse states stable `lex_state_id`s
- drive behavioral tokenization by executing lexer states, not by probing tokens one-by-one
- prepare the lexer boundary for keyword and external-scanner integration

## Why This Milestone

The current code is much closer to tree-sitter than before:

- lexical grammar is expanded into an NFA-like model
- token conflicts use grammar-derived following-token information
- valid-token selection already uses combined-state traversal
- combined lexer states are now interned during selection

But the main remaining gap is structural:

- tree-sitter builds lex tables once and reuses them
- we still perform ad hoc lexer traversal during behavioral simulation

This milestone closes that gap.

## Scope

In scope:

- lexer-state / lex-table builder
- parse-state to lexer-state assignment
- behavioral harness execution through lexer states
- keyword / word-token planning boundary
- external-scanner integration preparation

Out of scope:

- broad scanner-runtime redesign
- parser-core refactors unrelated to lexer-state construction
- changing the current compatibility boundary claims unless the new lexer path directly improves them

## Exit Criteria

- [ ] A lexer-state builder exists for valid token sets, analogous in role to tree-sitter `build_lex_table.rs`
- [ ] Parse states can be assigned stable `lex_state_id`s
- [ ] Main behavioral tokenization runs through lexer states instead of `selectBestTokenForSet(...)`
- [ ] Existing `lexer.model`, `behavioral`, and full `zig build test` suites pass
- [ ] The remaining lexer mismatch with tree-sitter is mainly keyword/external-scanner integration, not ad hoc token probing

## PR 1: Lex Table Builder

- [ ] Add a lexer-state builder module in the lexer layer
- [ ] Input is expanded lexical grammar plus a valid token set
- [ ] Output is interned lexer states with:
  - [ ] accept action
  - [ ] advance transitions
  - [ ] EOF handling
- [ ] Reuse the current combined-state machinery instead of re-deriving the algorithm again
- [ ] Add focused tests for:
  - [ ] same-string token preference
  - [ ] separator-sensitive completion vs continuation
  - [ ] stable reuse of identical combined states

## PR 2: Parse State to Lex State Assignment

- [ ] Derive valid token sets from parse states
- [ ] Assign each parse state a stable `lex_state_id`
- [ ] Reuse lex states across parse states with equivalent valid token sets
- [ ] Add tests that verify deterministic `lex_state_id` assignment on small grammars

## PR 3: Behavioral Harness on Lex States

- [ ] Replace main behavioral lexical selection with lexer-state execution
- [ ] Scanner-free path uses `lex_state_id` instead of probing valid terminals individually
- [ ] First-external-boundary path uses the same lexer-state execution for lexical tokens
- [ ] Sampled external-only path also uses lexer states where syntax grammar is available
- [ ] Keep old helper paths only where still required for unsupported features, and isolate them clearly

## PR 4: Keyword / Word Token Boundary

- [ ] Compare current repo behavior with tree-sitter keyword lex table handling
- [ ] Add a dedicated plan for `word_token` / keyword-state execution
- [ ] Implement the smallest viable split if current fixtures already need it
- [ ] Otherwise leave a narrow tracked boundary with tests and notes

## PR 5: External Scanner Integration Boundary

- [ ] Define how external-scanner validity should plug into lexer-state execution
- [ ] Replace more harness-side special casing with lexer-state-aware scanner entry checks
- [ ] Keep sampled scanner behavior green while shrinking ad hoc boundary logic

## Verification

- [ ] `zig test src/main.zig --test-filter "lexer.model"`
- [ ] `zig test src/main.zig --test-filter "behavioral"`
- [ ] targeted compat-harness scanner-wave checks
- [ ] `zig build test`

## Completion Notes

- [ ] record what now matches tree-sitter `build_lex_table.rs`
- [ ] record what still differs
- [ ] decide whether the next milestone should be:
  - [ ] keyword lex table parity
  - [ ] external-scanner lex-state integration
  - [ ] remaining regex / lexer feature gaps
