# Fuller `parser.c` Checklist

This checklist turns the `fuller parser output closer to upstream parser.c` direction into an executable implementation plan.

Its purpose is not to claim full upstream parity. Its purpose is to make the emitted `parser.c` artifact meaningfully closer to a runtime-consumable Tree-sitter translation unit, with explicit completion criteria and explicit deferrals.

## Goal

- [x] make the emitted `parser.c` stop feeling like a diagnostic wrapper over `SerializedTable`
- [x] make the emitted `parser.c` feel like a coherent language-centered runtime artifact
- [x] keep ready/blocked behavior explicit and deterministic while the emitted surface becomes more upstream-shaped

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

- [x] add a basic compile smoke test for the emitted `parser.c` artifact
- [x] prove that both a ready grammar and a blocked grammar emit syntactically valid C at the current boundary
- [x] keep the compile proof narrow and deterministic; do not turn it into full runtime execution yet

Current result for this stage:
- the parser.c pipeline tests now write emitted parser C to a temp file and compile it with `zig cc -std=c11 -c`
- both the ready metadata-rich grammar and the blocked conflict grammar are compile-smoke checked
- this is still only a syntax/translation-unit proof, not a runtime execution or ABI proof

### 5. Keep artifacts and checks in sync

- [x] update exact ready parser.c goldens as the emitted layout improves
- [x] update exact blocked parser.c goldens as the emitted layout improves
- [x] extend compatibility checks where the richer emitted surface should now be required

Current result for this stage:
- ready and blocked parser.c-like goldens have been updated alongside each layout change in this checklist
- compatibility checks now require not only the earlier parser/runtime surface, but also the richer symbol metadata and language-centered accessors
- the emitted parser.c surface is now enforced by both exact artifacts and structural compatibility checks, not only by one or the other

### 6. Closeout review

- [x] review the remaining gap between the current emitted `parser.c` and the intended staged runtime surface
- [x] explicitly defer anything that belongs to fuller runtime ABI compatibility or later upstream-like codegen work
- [x] document the completion boundary for this checklist in the later-work docs

Closeout decision:
- this checklist is complete
- the current emitted parser.c is now a language-centered, compile-smoke-checked, compatibility-checked staged runtime artifact
- it is intentionally still short of full upstream `parser.c` parity and full C runtime ABI compatibility

Deferred beyond this checklist:
- fuller upstream-shaped parser output and layout details beyond the current staged boundary
- full runtime ABI compatibility rather than the current staged compatibility layer
- lexer/scanner emission and external scanner integration
- parse-table compression/minimization
- broader behavioral equivalence and real-grammar compatibility proof

## Exit Criteria

- [x] the emitted artifact is centered around `TSLanguage` as the real top-level boundary
- [x] the emitted translation unit has a coherent parser/runtime/symbol layout, not only scattered helper-oriented structures
- [x] the most important remaining string-heavy surfaces are either removed or explicitly justified as staged compatibility helpers
- [x] emitted ready and blocked `parser.c` artifacts still have exact deterministic goldens
- [x] emitted `parser.c` passes a basic compile smoke test
- [x] remaining differences from fuller upstream-style `parser.c` are explicitly documented as deferred

## Explicit Non-Goals For This Checklist

- [x] do not claim full upstream `parser.c` parity
- [x] do not take on lexer/scanner emission here
- [x] do not take on runtime ABI compatibility in full here
- [x] do not start parse-table compression/minimization here
