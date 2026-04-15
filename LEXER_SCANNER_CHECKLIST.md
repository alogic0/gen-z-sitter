# Lexer / Scanner Checklist

This checklist turns the lexer/scanner direction into a concrete execution plan.

Its purpose is to move the project beyond parser-table-only coverage and establish the first credible emitted lexer boundary for grammars that cannot be handled by the current scanner-free parser-walk surface.

## Goal

- [ ] emit a first deterministic lexer/scanner surface beyond parser-table-only generation
- [ ] cover scanner-driven grammars that the current behavioral-equivalence boundary cannot support
- [ ] keep the first lexer/scanner stage narrow enough to verify locally and close cleanly

## Implementation Sequence

### 1. Define the first supported lexer/scanner boundary

- [ ] choose the first scanner-driven grammar shape to support
- [ ] decide which part belongs to emitted lexer logic versus deferred external-scanner work
- [ ] document the first supported lexer/scanner comparison surface for this stage

### 2. Introduce lexer-facing IR and serialization boundary

- [ ] define the minimal lexer/scanner IR needed beyond the current parser-only structures
- [ ] keep the first IR deterministic and emitter-oriented
- [ ] make blocked or unsupported lexer features explicit rather than implicit

### 3. Add deterministic lexer/scanner artifacts

- [ ] add exact goldens for the first supported scanner-driven grammar
- [ ] cover both ready and explicitly blocked lexer/scanner cases when applicable
- [ ] preserve deterministic output across `grammar.json` and `grammar.js` load paths where supported

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
