# Behavioral Equivalence Checklist

This checklist turns the behavioral-equivalence direction into an executable implementation plan.

Its purpose is to prove that the generator is producing parsers with credible real-grammar behavior, not only deterministic emitted artifacts. This is still not full ecosystem-wide equivalence; it is a staged proof boundary before broader compatibility and optimization work.

## Goal

- [ ] verify generated parser behavior on real grammars, not only synthetic fixture grammars
- [ ] compare parse behavior and failure behavior, not only emitted file shape
- [ ] add end-to-end corpus-oriented checks that exercise generated parsers from grammar input through parser emission

## Implementation Sequence

### 1. Pick the first real-grammar comparison boundary

- [x] choose a small real grammar or representative fixture set that is strong enough to expose behavior differences without bringing in broad scanner/runtime complexity immediately
- [x] document what counts as the first supported behavioral-equivalence comparison surface for this stage
- [x] keep the initial comparison target narrow enough to debug deterministically

Current first comparison boundary:
- use a small config/value language as the first real-language-style comparison target
- keep the grammar scanner-free and compatible with the current parser/emitter boundary
- cover both:
  - valid nested value inputs
  - invalid structural inputs
- treat this as the first supported behavioral-equivalence surface, not as a claim of broad ecosystem parity

### 2. Add end-to-end emitted-parser comparison inputs

- [x] add one or more real-grammar inputs that run through the existing `grammar.js` or `grammar.json` loading path
- [x] preserve deterministic generated outputs for those real grammars
- [x] keep the first comparison set focused on grammars that fit the current parser/emitter boundary

Current result for this stage:
- the `behavioral_config` comparison target now exists in both:
  - `grammar.json` fixture form
  - `grammar.js` fixture form
- parser-oriented output is now compared across both load paths for that same real-language-style grammar
- the first end-to-end comparison input remains scanner-free and bounded to the current emitted parser surface

### 3. Compare behavior, not just text

- [x] define a staged comparison target for generated parser behavior
- [x] compare successful parser-walk behavior on representative corpus inputs
- [x] compare failure behavior on representative invalid inputs
- [x] make any intentionally deferred behavior mismatches explicit

Current result for this stage:
- a first deterministic behavioral harness now simulates scanner-free parser walks over the built parser tables for `behavioral_config`
- the valid input is required to make non-trivial parser progress through that harness
- the invalid input is required to fail through that harness with an explicit classified failure reason
- `grammar.json` and `grammar.js` loading paths are now required to produce the same behavioral result for both valid and invalid inputs
- this stage still intentionally treats deterministic parser-walk progress and classified failure as the supported behavioral boundary, not as a claim of full parse acceptance or full runtime equivalence

### 4. Add corpus-oriented harness coverage

- [x] add a small harness that can run corpus-style inputs through the current generated-parser boundary
- [x] keep the first harness deterministic and local to the repo
- [x] avoid broad runtime/ABI claims beyond what the current emitted parser boundary actually supports

Current harness boundary:
- the first harness is local to the repo and runs directly from prepared grammar to built parser tables
- it covers both `grammar.json` and `grammar.js` loading paths for the same config-language comparison target
- it does not claim full Tree-sitter runtime ABI behavior, external scanner support, broad corpus parity, or full acceptance semantics beyond the current staged parser-table/runtime surface

### 5. Record the current behavioral boundary

- [ ] document which behaviors are now credibly covered
- [ ] document which real-grammar or runtime behaviors remain deferred
- [ ] connect those deferrals back to later checklist items when appropriate

### 6. Closeout review

- [ ] review whether the first behavioral-equivalence boundary is strong enough to mark this checklist complete
- [ ] explicitly defer anything that depends on fuller runtime ABI coverage, lexer/scanner work, or broader grammar support
- [ ] document the completion boundary in the later-work and direction docs

## Exit Criteria

- [ ] at least one real-grammar path is exercised end to end through generation and parser-oriented output
- [ ] behavioral checks go beyond exact emitted text and compare parser behavior on real inputs
- [ ] the first corpus-style comparison harness exists and is deterministic
- [ ] known behavioral gaps are explicitly documented rather than left implicit
- [ ] remaining broader-equivalence work is clearly deferred

## Explicit Non-Goals For This Checklist

- [ ] do not claim full corpus parity across the Tree-sitter ecosystem
- [ ] do not require full runtime ABI compatibility here
- [ ] do not take on lexer/scanner emission here
- [ ] do not fold broad optimization or compression work into behavioral proof
