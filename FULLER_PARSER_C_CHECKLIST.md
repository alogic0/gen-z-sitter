# Fuller `parser.c` Checklist

This checklist turns the `fuller parser output closer to upstream parser.c` direction into an executable implementation plan.

Its purpose is not to claim full upstream parity. Its purpose is to make the emitted `parser.c` artifact meaningfully closer to a runtime-consumable Tree-sitter translation unit, with explicit completion criteria and explicit deferrals.

## Goal

- [ ] make the emitted `parser.c` stop feeling like a diagnostic wrapper over `SerializedTable`
- [ ] make the emitted `parser.c` feel like a coherent language-centered runtime artifact
- [ ] keep ready/blocked behavior explicit and deterministic while the emitted surface becomes more upstream-shaped

## Implementation Sequence

### 1. Clarify the top-level emitted layout

- [x] make `TSLanguage` the clear top-level emitted boundary, not just an added wrapper
- [x] review whether `TSParser`, `TSParserRuntime`, and compatibility metadata are arranged in the most runtime-oriented way for the current stage
- [x] document the intended top-level translation-unit shape for this stage before deeper emitter changes

Current intended top-level shape for this stage:
- `ts_language` is the emitted root object
- `ts_language` owns pointers to parser, runtime, and compatibility metadata
- parser/runtime/compatibility accessors should flow through `ts_language` rather than treating those objects as independent roots
- symbol/state/query helpers may still exist, but they are downstream convenience APIs, not the primary emitted boundary

### 2. Reduce string-heavy emitter surfaces

- [ ] identify which currently emitted string-oriented helpers and entry surfaces are still primarily diagnostic
- [ ] move the most important parser-facing data toward more table-oriented emitted structures
- [ ] keep any remaining string-heavy helpers only when they are explicitly part of the staged compatibility layer

### 3. Strengthen symbol/runtime metadata

- [ ] review the current emitted symbol table for missing runtime-relevant properties
- [ ] add any clearly justified symbol metadata needed for a more credible parser artifact
- [ ] keep compatibility-oriented symbol accessors and checks aligned with the richer metadata

### 4. Add compile-oriented proof

- [ ] add a basic compile smoke test for the emitted `parser.c` artifact
- [ ] prove that both a ready grammar and a blocked grammar emit syntactically valid C at the current boundary
- [ ] keep the compile proof narrow and deterministic; do not turn it into full runtime execution yet

### 5. Keep artifacts and checks in sync

- [ ] update exact ready parser.c goldens as the emitted layout improves
- [ ] update exact blocked parser.c goldens as the emitted layout improves
- [ ] extend compatibility checks where the richer emitted surface should now be required

### 6. Closeout review

- [ ] review the remaining gap between the current emitted `parser.c` and the intended staged runtime surface
- [ ] explicitly defer anything that belongs to fuller runtime ABI compatibility or later upstream-like codegen work
- [ ] document the completion boundary for this checklist in the later-work docs

## Exit Criteria

- [ ] the emitted artifact is centered around `TSLanguage` as the real top-level boundary
- [ ] the emitted translation unit has a coherent parser/runtime/symbol layout, not only scattered helper-oriented structures
- [ ] the most important remaining string-heavy surfaces are either removed or explicitly justified as staged compatibility helpers
- [ ] emitted ready and blocked `parser.c` artifacts still have exact deterministic goldens
- [ ] emitted `parser.c` passes a basic compile smoke test
- [ ] remaining differences from fuller upstream-style `parser.c` are explicitly documented as deferred

## Explicit Non-Goals For This Checklist

- [ ] do not claim full upstream `parser.c` parity
- [ ] do not take on lexer/scanner emission here
- [ ] do not take on runtime ABI compatibility in full here
- [ ] do not start parse-table compression/minimization here
