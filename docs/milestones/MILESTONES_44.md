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

The original structural gap was:

- tree-sitter builds lex tables once and reuses them
- behavioral simulation still performed ad hoc lexer traversal

That gap is now mostly closed for scanner-free and sampled external-boundary
paths. The remaining M44 work is narrower: keyword/reserved-word lexing and
cleaner external-scanner integration.

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

- [x] A lexer-state builder exists for valid token sets, analogous in role to tree-sitter `build_lex_table.rs`
- [x] Parse states can be assigned stable `lex_state_id`s
- [x] Main behavioral tokenization runs through lexer states instead of `selectBestTokenForSet(...)`
- [x] Existing `lexer.model`, `behavioral`, and full `zig build test` suites pass
- [x] The remaining lexer mismatch with tree-sitter is mainly keyword/external-scanner integration, not ad hoc token probing

## PR 1: Lex Table Builder

- [x] Add a lexer-state builder module in the lexer layer
- [x] Input is expanded lexical grammar plus a valid token set
- [x] Output is interned lexer states with:
  - [x] accept action
  - [x] advance transitions
  - [x] EOF handling
- [x] Reuse the current combined-state machinery instead of re-deriving the algorithm again
- [x] Add focused tests for:
  - [x] same-string token preference
  - [x] separator-sensitive completion vs continuation
  - [x] stable reuse of identical combined states

## PR 2: Parse State to Lex State Assignment

- [x] Derive valid token sets from parse states
- [x] Assign each parse state a stable `lex_state_id`
- [x] Reuse lex states across parse states with equivalent valid token sets
- [x] Add tests that verify deterministic `lex_state_id` assignment on small grammars

## PR 3: Behavioral Harness on Lex States

- [x] Replace main behavioral lexical selection with lexer-state execution
- [x] Scanner-free path uses `lex_state_id` instead of probing valid terminals individually
- [x] First-external-boundary path uses the same lexer-state execution for lexical tokens
- [x] Sampled external-only path also uses lexer states where syntax grammar is available
- [x] Keep old helper paths only where still required for unsupported features, and isolate them clearly

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

- [x] `zig build test --summary all`
- [x] `zig build test-behavioral --summary all`
- [x] targeted scanner-wave runtime-link check: `zig build test-link-runtime --summary all`

## Completion Notes

- [ ] record what now matches tree-sitter `build_lex_table.rs`
- [ ] record what still differs
- [ ] decide whether the next milestone should be:
  - [ ] keyword lex table parity
  - [ ] external-scanner lex-state integration
  - [ ] remaining regex / lexer feature gaps
