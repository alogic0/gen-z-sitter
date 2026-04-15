# Lexer / Scanner Checklist

This checklist turns the lexer/scanner direction into a concrete execution plan.

Its purpose is to move the project beyond parser-table-only coverage and establish the first credible emitted lexer boundary for grammars that cannot be handled by the current scanner-free parser-walk surface.

## Goal

- [ ] emit a first deterministic lexer/scanner surface beyond parser-table-only generation
- [ ] cover scanner-driven grammars that the current behavioral-equivalence boundary cannot support
- [ ] keep the first lexer/scanner stage narrow enough to verify locally and close cleanly

## Implementation Sequence

### 1. Define the first supported lexer/scanner boundary

- [x] choose the first scanner-driven grammar shape to support
- [x] decide which part belongs to emitted lexer logic versus deferred external-scanner work
- [x] document the first supported lexer/scanner comparison surface for this stage

Current first supported lexer/scanner boundary:
- support first:
  - pattern-based lexical tokens that lower to the existing lexical grammar
  - mixed string and pattern terminals with no external scanner dependency
  - real prepared-grammar inputs that already exist in the repo, centered on:
    - `repeat_choice_seq`
    - similar pattern-token fixtures already used by extraction and parser-table coverage
- explicitly defer from this first stage:
  - grammars whose practical tokenization depends on external tokens
  - full external scanner integration
  - runtime claims that require upstream external-scanner ABI behavior
- staged comparison surface for this checklist:
  - ready path:
    - scanner-free emitted lexer support for pattern/string terminals
  - explicitly blocked path:
    - external-token grammar shapes that are recognized but still deferred to later external-scanner work

### 2. Introduce lexer-facing IR and serialization boundary

- [x] define the minimal lexer/scanner IR needed beyond the current parser-only structures
- [x] keep the first IR deterministic and emitter-oriented
- [x] make blocked or unsupported lexer features explicit rather than implicit

Current lexer-facing boundary:
- `src/lexer/serialize.zig` is the first lexer-oriented serialization boundary
- the ready subset now serializes:
  - string lexical forms
  - pattern lexical forms
  - token/immediate-token metadata
  - lexical precedence and start-state fields
- the blocked subset is explicit instead of implicit:
  - separators are surfaced as unsupported blockers
  - external tokens are surfaced as unsupported blockers
- this stage still does not emit lexer C code or claim external-scanner support

### 3. Add deterministic lexer/scanner artifacts

- [x] add exact goldens for the first supported scanner-driven grammar
- [x] cover both ready and explicitly blocked lexer/scanner cases when applicable
- [x] preserve deterministic output across `grammar.json` and `grammar.js` load paths where supported

Current artifact boundary:
- exact lexical dumps now exist for:
  - ready pattern/string lexical grammar: `repeat_choice_seq`
  - blocked external-token lexical grammar: `mixed_semantics`
- the ready lexical dump is required to remain stable across:
  - `grammar.json`
  - `grammar.js`
- this stage still stops at deterministic serialized lexical artifacts, not emitted lexer C code

### 4. Add emitted lexer/scanner boundary checks

- [ ] add structural checks for the first emitted lexer/scanner surface
- [ ] keep those checks aligned with the staged compatibility boundary rather than claiming full runtime ABI support
- [ ] add compile-oriented or smoke-oriented proof if the emitted lexer surface reaches C output

### 5. Connect lexer/scanner work to behavioral proof

- [ ] add at least one real grammar/input case that specifically requires the new lexer/scanner boundary
- [ ] document what behavioral coverage becomes newly possible because of lexer/scanner support
- [ ] make any remaining external-scanner-only gaps explicit

### 6. Record deferrals and closeout boundary

- [ ] document what remains deferred to external scanner integration
- [ ] document what remains deferred to broader compatibility hardening
- [ ] decide whether this first lexer/scanner boundary is strong enough to close the checklist

## Exit Criteria

- [ ] at least one lexer/scanner-driven grammar shape is supported end to end
- [ ] deterministic lexer/scanner artifacts exist for the supported subset
- [ ] the emitted lexer/scanner boundary has structural proof, and compile proof if applicable
- [ ] the new behavioral coverage enabled by lexer/scanner support is explicit
- [ ] external-scanner and broader compatibility gaps are documented rather than implicit

## Explicit Non-Goals For This Checklist

- [ ] do not claim full external scanner integration here
- [ ] do not claim full Tree-sitter runtime ABI compatibility here
- [ ] do not fold broad compatibility hardening into the first lexer/scanner boundary
- [ ] do not take on parse-table compression/minimization here
