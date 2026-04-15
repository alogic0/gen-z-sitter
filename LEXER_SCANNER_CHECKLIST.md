# Lexer / Scanner Checklist

This checklist turns the lexer/scanner direction into a concrete execution plan.

Its purpose is to move the project beyond parser-table-only coverage and establish the first credible emitted lexer boundary for grammars that cannot be handled by the current scanner-free parser-walk surface.

## Goal

- [x] emit a first deterministic lexer/scanner surface beyond parser-table-only generation
- [x] cover scanner-driven grammars that the current behavioral-equivalence boundary cannot support
- [x] keep the first lexer/scanner stage narrow enough to verify locally and close cleanly

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

- [x] add structural checks for the first emitted lexer/scanner surface
- [x] keep those checks aligned with the staged compatibility boundary rather than claiming full runtime ABI support
- [x] add compile-oriented or smoke-oriented proof if the emitted lexer surface reaches C output

Current check boundary:
- `src/lexer/checks.zig` now validates the serialized lexical surface directly
- ready lexical surfaces must:
  - contain serialized lexical variables
  - avoid unsupported separators and external-token blockers
- blocked lexical surfaces must:
  - carry explicit blocker information
- compile-oriented proof is intentionally recorded as not yet applicable at this stage because the current lexer boundary stops at serialized/dumped lexical artifacts rather than emitted lexer C output

### 5. Connect lexer/scanner work to behavioral proof

- [x] add at least one real grammar/input case that specifically requires the new lexer/scanner boundary
- [x] document what behavioral coverage becomes newly possible because of lexer/scanner support
- [x] make any remaining external-scanner-only gaps explicit

Current behavioral coverage added by this checklist:
- `repeat_choice_seq` now serves as the first real lexer-driven grammar/input case
- the behavioral harness now supports the first staged lexical subset:
  - string terminals
  - simple `[a-z]+`-style pattern terminals
- that makes new behavioral proof possible beyond the earlier scanner-free literal-only boundary:
  - lexer-driven parser-walk progress on valid pattern-token input
  - deterministic JSON-path and JS-path behavioral parity for that lexer-driven case
- still explicitly deferred:
  - broader regex/pattern coverage
  - external-token and external-scanner-driven behavior
  - runtime claims that depend on a full external scanner surface

### 6. Record deferrals and closeout boundary

- [x] document what remains deferred to external scanner integration
- [x] document what remains deferred to broader compatibility hardening
- [x] decide whether this first lexer/scanner boundary is strong enough to close the checklist

Closeout decision:
- this checklist is complete as the first staged lexer/scanner boundary
- delivered now:
  - a ready lexical subset for string and simple pattern terminals
  - deterministic serialized lexical artifacts
  - explicit blocked handling for separators and external-token grammar shapes
  - structural lexer-boundary checks
  - lexer-driven behavioral proof on `repeat_choice_seq`
- explicitly deferred:
  - broader regex/pattern support
  - emitted lexer C output
  - external scanner integration
  - runtime ABI claims that depend on a full scanner surface
  - broader compatibility hardening after this first lexer boundary
- those deferrals map directly to:
  - `NEXT_DIRECTION_CHECKLIST.md`
    - `Compatibility Hardening`
  - `LATER_WORK_CHECKLIST.md`
    - `external scanner integration`
    - `broader real-grammar/repo compatibility coverage`

## Exit Criteria

- [x] at least one lexer/scanner-driven grammar shape is supported end to end
- [x] deterministic lexer/scanner artifacts exist for the supported subset
- [x] the emitted lexer/scanner boundary has structural proof, and compile proof if applicable
- [x] the new behavioral coverage enabled by lexer/scanner support is explicit
- [x] external-scanner and broader compatibility gaps are documented rather than implicit

## Explicit Non-Goals For This Checklist

- [x] do not claim full external scanner integration here
- [x] do not claim full Tree-sitter runtime ABI compatibility here
- [x] do not fold broad compatibility hardening into the first lexer/scanner boundary
- [x] do not take on parse-table compression/minimization here
