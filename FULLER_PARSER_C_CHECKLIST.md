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

- [x] identify which currently emitted string-oriented helpers and entry surfaces are still primarily diagnostic
- [x] move the most important parser-facing data toward more table-oriented emitted structures
- [x] keep any remaining string-heavy helpers only when they are explicitly part of the staged compatibility layer

Current result for this stage:
- core emitted `TSActionEntry`, `TSGotoEntry`, and `TSUnresolvedEntry` tables now use `symbol_id` and numeric codes instead of embedding symbol/kind/reason strings directly
- string-returning helpers like `ts_parser_action_kind(...)`, `ts_parser_action_symbol(...)`, and `ts_parser_unresolved_reason(...)` remain only as compatibility-oriented wrappers over the lower-level emitted tables
- the remaining string-heavy layer is now downstream API sugar, not the primary data representation

### 3. Strengthen symbol/runtime metadata

- [x] review the current emitted symbol table for missing runtime-relevant properties
- [x] add any clearly justified symbol metadata needed for a more credible parser artifact
- [x] keep compatibility-oriented symbol accessors and checks aligned with the richer metadata

Current result for this stage:
- emitted `TSSymbolInfo` now carries symbol identity and kind metadata in addition to name and terminal/external flags
- the symbol surface now exposes:
  - `ts_parser_symbol_id(...)`
  - `ts_parser_symbol_kind(...)`
  - existing name/terminal/external compatibility helpers
- compatibility checks now require the richer symbol struct and accessors, so the stronger metadata surface is part of the enforced emitted boundary

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
