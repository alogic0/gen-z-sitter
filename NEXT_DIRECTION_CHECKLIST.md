# Next Direction Checklist

This checklist captures the recommended direction for the project after the current milestone sequence and later-work backlog framing.

The goal is to bias the project toward real generated-parser usefulness, not more internal layering for its own sake.

## Priority Order

### 1. Behavioral Equivalence

- [x] verify generated parser behavior on real grammars, not only fixture grammars
- [x] compare parse behavior and failure behavior, not only emitted file shape
- [x] add corpus-oriented checks that exercise generated parsers end to end
- [x] document the current behavioral-equivalence boundary and known gaps

Current completed boundary:
- first staged behavioral equivalence is now in place for a scanner-free real-language-style grammar
- current proof includes:
  - deterministic JSON-path and JS-path emitted output
  - deterministic parser-walk behavior
  - explicit failure classification on invalid input
- broader equivalence still belongs to later sections here:
  - `Lexer / Scanner Path`
  - `Compatibility Hardening`

### 2. Fuller `parser.c` Output

- [x] move emitted `parser.c` closer to an actually runtime-consumable Tree-sitter artifact
- [x] reduce the remaining gap between the current diagnostic-friendly emitter and a real generated parser translation unit
- [x] define concrete exit criteria for “closer to upstream `parser.c`” so the work can be marked complete objectively
- [x] keep exact ready/blocked emission goldens stable while the parser surface becomes more realistic

### 3. Lexer / Scanner Path

- [x] implement lexer/scanner emission beyond parser-table-only coverage
- [ ] add external scanner integration support
- [x] prove the lexer/scanner path on real grammar cases that cannot be covered by the current parser-only boundary
- [x] document any staged compatibility limits in the emitted scanner/runtime surface

Promoted execution checklist:
- [x] [LEXER_SCANNER_CHECKLIST.md](./LEXER_SCANNER_CHECKLIST.md)
- [x] use that checklist as the active implementation plan before deciding whether compatibility hardening runs in parallel or after it
- [x] decide that compatibility hardening should follow the first lexer/scanner and external-scanner stages rather than run in parallel
- [x] promote external-scanner integration into its own implementation checklist:
  - [EXTERNAL_SCANNER_CHECKLIST.md](./EXTERNAL_SCANNER_CHECKLIST.md)

### 4. Compatibility Hardening

- [ ] document the remaining runtime-surface mismatches against expected Tree-sitter contracts
- [ ] shrink the emitted compatibility gaps that still block credible runtime use
- [ ] make ABI and compatibility-layer boundaries explicit and testable
- [ ] add compatibility-oriented checks for the richer emitted parser surface

### 5. Optimization Later

- [ ] implement parse-table compression and/or minimization only after correctness is credible
- [ ] avoid performance-oriented rewrites that blur unresolved correctness and compatibility gaps
- [ ] document the intended optimization boundary before changing table layout materially

## Immediate Recommended Next Target

- [x] promote `fuller parser output closer to upstream parser.c` into a dedicated milestone with concrete exit criteria
- [x] implement that milestone before broadening into more optimization or ergonomics work
- [x] promote behavioral equivalence into a dedicated checklist with concrete exit criteria
- [x] promote `Lexer / Scanner Path` into a dedicated implementation checklist
- [x] decide whether `Compatibility Hardening` should run in parallel with the lexer/scanner checklist or immediately after it
- [x] prefer the sequence:
  - first lexer/scanner boundary
  - then first external-scanner boundary
  - then broader compatibility hardening

## Guiding Rule

- [ ] prefer end-to-end generated parser correctness on real grammars over additional planning-heavy internal refactoring
