# MILESTONES 43 (Tokenizer In Upstream Shape)

This milestone follows [MILESTONES_42.md](./MILESTONES_42.md).

Milestone 42 closed with a negative but useful result:

- `tree_sitter_haskell_json` was not blocked mainly by lexical separators
- the deeper problem is that our current tokenizer model is not upstream-shaped
- patching one grammar at a time in the behavioral harness is no longer the right path

So the next milestone is not another compatibility-target promotion attempt.
It is a structural lexer milestone.

## Goal

- replace the current ad hoc behavioral token matcher with a tokenizer model that is much closer to upstream tree-sitter
- keep the current parser-table and compatibility work stable while doing so
- reach a point where scanner-boundary behavioral proof can depend on a real lexer model instead of local recursive rule matching

This milestone is still not full scanner.c runtime parity.
It is about the internal tokenizer architecture that both scanner-free and external-scanner behavioral proof depend on.

## Why This Is The Right Next Step

From the M42 comparison against `/home/oleg/prog/tree-sitter`:

- upstream expands lexical rules into an NFA
- upstream computes token conflicts, prefix/continuation overlap, separator interactions, and precedence
- upstream renders parse-state-aware lex tables
- our current harness:
  - recursively matches grammar rules directly
  - supports only a limited lexical-pattern subset
  - treats separators as an outer harness concern
  - uses parser-action existence as a coarse lexical filter
  - does not model upstream token-conflict analysis

That gap is now the main blocker for stronger scanner-boundary proof.

## Scope

In scope:

- introducing an internal lexical automaton / tokenizer representation that follows upstream shape more closely
- integrating separators and immediate-token behavior into that tokenizer model
- implementing token-conflict analysis for lexical disambiguation
- making behavioral simulation consume tokenizer results instead of recursive rule matching
- keeping the external-scanner first-boundary sampling path working during the transition

Out of scope:

- full scanner.c runtime parity
- broad external-scanner onboarding of new targets
- parser-table algorithm refactors unrelated to tokenization
- grammar-specific hacks for Haskell, Bash, or any other single target

## Exit Criteria

- [ ] tokenizer behavior is driven by an explicit lexical automaton/model, not direct recursive rule matching
- [ ] separators are modeled inside the tokenizer path, not as an outer fallback only
- [ ] token-conflict behavior has an explicit internal representation comparable to upstream token conflict handling
- [ ] behavioral simulation no longer relies on the old ad hoc lexical matcher on its primary path
- [ ] current green parser-only and scanner proofs still pass
- [ ] `zig build test` passes

## PR-Sized Slices

### PR 1: Introduce A Real Lexical Model

- [ ] inspect upstream `expand_tokens.rs` and pin the minimum internal structures we need
- [ ] add a local lexical automaton/tokenizer representation
- [ ] build that representation from extracted lexical grammar without changing behavior consumers yet

Success signal:

- tokenizer data is no longer implicit in recursive matcher code

### PR 2: Move Matching Onto The Lexical Model

- [ ] replace the current direct recursive token matcher on the main behavioral path
- [ ] support token sequences/choices/repeats and separator-aware matching through the tokenizer model
- [ ] preserve existing narrow scanner-wave proofs during the switchover

Success signal:

- behavioral simulation uses the new tokenizer path for ordinary lexical matching

### PR 3: Add Token Conflict And Priority Semantics

- [ ] implement a first explicit version of token conflict / overlap handling
- [ ] integrate precedence, implicit precedence, and separator-sensitive matching where needed
- [ ] remove the most important local heuristic mismatches with upstream token choice

Success signal:

- token selection is no longer “longest local match plus parser-action existence”

### PR 4: Reconnect Compatibility Proofs

- [ ] rerun scanner-boundary proofs on current external targets
- [ ] decide whether `tree_sitter_haskell_json` can move beyond `sampled_external_sequence`
- [ ] refresh artifacts and milestone docs based on the new tokenizer behavior

Success signal:

- compatibility boundary changes are driven by the tokenizer architecture, not target-specific patches

## Progress

- [ ] PR 1 completed
- [ ] PR 2 completed
- [ ] PR 3 completed
- [ ] PR 4 completed
- [ ] M43 ready for closeout

## Current Focus

- first class of gap to close:
  - lexical automaton representation
- second class of gap to close:
  - token conflict and separator semantics
- first target that should benefit after the tokenizer work:
  - `tree_sitter_haskell_json`
