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

- [ ] add one or more real-grammar inputs that run through the existing `grammar.js` or `grammar.json` loading path
- [ ] preserve deterministic generated outputs for those real grammars
- [ ] keep the first comparison set focused on grammars that fit the current parser/emitter boundary

### 3. Compare behavior, not just text

- [ ] define a staged comparison target for generated parser behavior
- [ ] compare successful parse behavior on representative corpus inputs
- [ ] compare failure behavior on representative invalid inputs
- [ ] make any intentionally deferred behavior mismatches explicit

### 4. Add corpus-oriented harness coverage

- [ ] add a small harness that can run corpus-style inputs through the current generated-parser boundary
- [ ] keep the first harness deterministic and local to the repo
- [ ] avoid broad runtime/ABI claims beyond what the current emitted parser boundary actually supports

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
