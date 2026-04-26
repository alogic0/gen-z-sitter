# ReWrite-5: Broader External-Scanner Runtime Parity

**Goal**: widen the proven external-scanner boundary from a single stateless token link
test to:

- focused serialization coverage for per-state external-token validity sets,
- a multi-token runtime link test,
- a stateful external scanner runtime link test,
- a small generated-from-grammar external-scanner parser that goes through the local
  grammar-to-parser pipeline and links against scanner C.

**Scope rule**: keep the project self-contained Zig. Do not copy tree-sitter source
files into this project. Tests may compile against `../tree-sitter/lib/src` as an
external reference/runtime dependency.

**Prerequisite**: RW-4 implementation is complete. The fast/local/runtime-link RW-4
gates pass. RW-4 explicitly defers `zig build test-compat-heavy` and the full
compatibility target compile-smoke sweep, so those deferred gates are not prerequisites
for starting RW-5.

**Non-goals for RW-5**:

- Do not run `zig build test-compat-heavy` during the implementation pass; it remains a
  separate manual gate.
- Do not run the full compatibility target compile-smoke sweep during the implementation
  pass; it remains a separate manual gate.
- Do not promote Haskell or Bash grammar.json snapshots to full runtime link scope.
  Their parse-table construction cost (see `GAPS_260425.md` gap 1) makes the full
  pipeline impractical until that cost issue is addressed. Bash and Haskell remain at
  their current `sampled_expansion_path` / `sampled_external_sequence` proof scopes.
- Do not claim parser error recovery or GLR scanner interaction parity. Those are
  runtime behavior areas and need separate, narrowly designed tests.
- Do not claim scanner serialize/deserialize rewind coverage unless a test explicitly
  proves those callbacks were called by the runtime.

**Reference**:

- `../tree-sitter/lib/src/parser.h`: `TSExternalScanner` struct and `TSLexer`
  callbacks.
- `../tree-sitter/crates/generate/src/render.rs`: `add_external_scanner_states_list`,
  `add_external_scanner_symbol_map`.
- `src/parse_table/serialize.zig`: `buildExternalScannerStatesAlloc`, which derives
  `external_lex_state` per parse state and the `bool[EXTERNAL_TOKEN_COUNT]` rows used
  by `ts_external_scanner_states`.
- `src/parser_emit/parser_c.zig`: `writeExternalScannerTables`, which emits the runtime
  external scanner state matrix and symbol map.
- `src/compat/runtime_link.zig`: current `emitExternalScannerParserC` and
  `externalScannerSource` baseline.

---

## Background: Current Coverage

`linkAndRunExternalScannerParser` / `externalScannerSource` currently proves:

- The five external scanner function pointers link correctly.
- A scanner with no persistent state compiles and runs.
- A single external token is recognized when `valid_symbols[0]` is true.
- A single external lex state is wired into the generated parser.

It does not prove:

- Correct bool-set construction for multiple external tokens.
- Correct `valid_symbols` routing for different parse states.
- Stateful scanner payload allocation, mutation, serialization function wiring, and
  destruction.
- Full grammar JSON / grammar IR / parse-table / serialization / emitter pipeline
  coverage for an external-scanner fixture.

Implementation order matters. Start with the deterministic serialization/emission
surface, then runtime link tests, then the generated-from-grammar fixture, then
inventory/proof-scope reporting.

---

## Phase 1 — External Scanner State Matrix Unit Coverage

**Why first.** This is the smallest and most deterministic gap. It tests the exact
serialized data that the runtime scanner consumes without designing a full parser.

- [x] Read `buildExternalScannerStatesAlloc` in `src/parse_table/serialize.zig` and
  confirm how it:
  - collects external symbols from parse-state action entries,
  - deduplicates bool rows,
  - assigns `external_lex_state` per parse state,
  - keeps all-false state 0 for parse states with no external-token action.
- [x] Add a focused unit test in `serialize.zig` that builds hand-crafted serialized
  states:
  - State A has action for `external 0` only.
  - State B has actions for `external 0` and `external 1`.
  - State C has no external actions.
  - The serialized symbol metadata declares three external symbols:
    `OPEN`, `CLOSE`, and `ERROR_SENTINEL`.
- [x] Assert the produced matrix:
  - State A maps to `{ true, false, false }`.
  - State B maps to `{ true, true, false }`.
  - State C maps to all-false state 0.
  - `ERROR_SENTINEL` is false in every row.
- [x] Add a focused parser C emitter test that emits `ts_external_scanner_states` and
  `ts_external_scanner_symbol_map` for the same matrix and asserts the expected rows
  appear in generated C.

---

## Phase 2 — Multi-Token Runtime Link Test

**Purpose.** Prove that generated C passes the correct `valid_symbols` row to a scanner
with multiple external tokens.

Use a hand-crafted serialized table in `runtime_link.zig`. Keep this parser small and
deterministic. The grammar shape can be bracket-like:

```text
source := item
item   := OPEN CLOSE
OPEN and CLOSE are external tokens
ERROR_SENTINEL is declared but never valid
```

- [x] Add `emitMultiTokenExternalScannerParserC` in `runtime_link.zig`.
- [x] The serialized table must include three external symbols:
  `OPEN`, `CLOSE`, and `ERROR_SENTINEL`.
- [x] Use at least two parse states with different external lex states:
  - start state: `OPEN` valid, `CLOSE` false, `ERROR_SENTINEL` false,
  - after `OPEN`: `CLOSE` valid, `OPEN` false unless the grammar intentionally allows
    nesting, `ERROR_SENTINEL` false.
- [x] Add `multiTokenScannerSource()` with:
  - `enum TokenType { OPEN, CLOSE, ERROR_SENTINEL }`,
  - a hard assertion/failure path if `valid_symbols[ERROR_SENTINEL]` is true,
  - `scan` that advances over `(` for `OPEN` and `)` for `CLOSE`.
- [x] Add `linkAndRunMultiTokenExternalScannerParser` that links the parser, scanner,
  and tree-sitter runtime, parses `"()"`, and asserts the root is not an ERROR node.
- [x] Add a driver assertion that the parse tree has the expected root and child token
  types using `ts_node_child_count` and `ts_node_type`.
- [x] Add `test "linkAndRunMultiTokenExternalScannerParser ..."` in
  `runtime_link.zig`.
- [x] Add `zig build test-link-multi-token-scanner` in `build.zig`.

---

## Phase 3 — Stateful Scanner Runtime Link Test

**Purpose.** Prove scanner payload allocation, mutation, serialize/deserialize function
linking, and destruction work with generated parser C. Do not claim runtime rewind
coverage unless the test proves serialize/deserialize were called.

Scanner semantics:

- Payload struct stores:
  - `uint8_t depth`,
  - counters for `serialize`, `deserialize`, and `destroy` if the driver needs to
    inspect them.
- `create`: allocate and zero-initialize the payload.
- `destroy`: mark/free the payload.
- `serialize`: write `depth` into `buffer[0]`, return 1.
- `deserialize`: read `depth` from `buffer[0]` if `length >= 1`, otherwise reset to 0.
- `scan`:
  - if `valid_symbols[OPEN]` and lookahead is `(`: set `result_symbol = OPEN`,
    advance over `(`, increment `depth`, mark end, return true.
  - if `valid_symbols[CLOSE]` and lookahead is `)`: set `result_symbol = CLOSE`,
    advance over `)`, decrement `depth` only when `depth > 0`, mark end, return true.
  - never return a token without advancing for `(` or `)`.
  - return false if `ERROR_SENTINEL` is valid.

Parser shape can extend Phase 2 to a tiny nested language:

```text
source := item
item   := OPEN item? CLOSE
```

Parse target: `"(())"`.

- [ ] Add `emitStatefulExternalScannerParserC` in `runtime_link.zig`.
- [ ] Add `statefulScannerSource()` following the scanner semantics above.
- [ ] Add `linkAndRunStatefulExternalScannerParser` that parses `"(())"` and asserts
  the root is not an ERROR node.
- [ ] Add parse-tree shape assertions for nesting depth 2.
- [ ] If claiming serialize/deserialize coverage, add a reliable assertion that those
  callbacks were actually called. If the runtime does not call them for this grammar,
  document that this phase proves stateful scanner linking and mutation only.
- [ ] Add `test "linkAndRunStatefulExternalScannerParser ..."` in `runtime_link.zig`.
- [ ] Add `zig build test-link-stateful-scanner` in `build.zig`.

---

## Phase 4 — Generated-from-Grammar External Scanner Fixture

**Purpose.** Prove a small external-scanner grammar can travel through the local grammar
JSON loader, grammar lowering, parse-table builder, serialization boundary, parser C
emitter, compile step, and runtime link.

Use a fixture small enough to finish under a few seconds in normal local tests.

Fixture grammar:

```json
{
  "name": "bracket_lang",
  "version": "1.0.0",
  "externals": [
    { "type": "SYMBOL", "name": "open_bracket" },
    { "type": "SYMBOL", "name": "close_bracket" }
  ],
  "rules": {
    "source": { "type": "REPEAT", "content": { "type": "SYMBOL", "name": "item" } },
    "item": {
      "type": "SEQ",
      "members": [
        { "type": "SYMBOL", "name": "open_bracket" },
        { "type": "REPEAT", "content": { "type": "SYMBOL", "name": "item" } },
        { "type": "SYMBOL", "name": "close_bracket" }
      ]
    }
  }
}
```

Implementation notes:

- Prefer existing pipeline helpers over manually reproducing build/serialize/attach
  steps in `runtime_link.zig`. If a helper is missing, add a narrow helper in the
  pipeline layer and use it from the runtime-link test.
- The scanner C prefix must match `tree_sitter_bracket_lang`.
- The staged scanner must advance for both `open_bracket` and `close_bracket`.

Tasks:

- [ ] Study `src/parse_table/pipeline.zig` and `src/compat/runtime_link.zig`; choose
  the smallest existing helper path for grammar JSON → emitted parser C.
- [ ] Read `src/parse_table/build.zig` and confirm external token actions are inserted
  as shift actions with `symbol = .{ .external = N }`, and that those actions reach
  `buildExternalScannerStatesAlloc`. Write a short note here before coding.
- [ ] Stage `compat_targets/bracket_lang/grammar.json`.
- [ ] Stage `compat_targets/bracket_lang/scanner.c`.
- [ ] Add `emitBracketLangParserC` using the existing grammar loader/pipeline path.
- [ ] Add `linkAndRunBracketLangParser` that links generated parser C with staged
  `scanner.c`, parses `"(())"`, and asserts the root is not an ERROR node.
- [ ] Add parse-tree shape assertions for the bracket nesting.
- [ ] Add `test "linkAndRunBracketLangParser ..."` in `runtime_link.zig`.
- [ ] Add `zig build test-link-bracket-lang` in `build.zig`.

---

## Phase 5 — Proof Scope Infrastructure

**Purpose.** Record that a fixture has full runtime-link proof without claiming that
large real-world grammars are ready for that scope.

- [ ] Add `full_runtime_link` to `RealExternalScannerProofScope` in
  `src/compat/targets.zig`.
- [ ] Add `bracket_lang` to `TargetFamily`.
- [ ] Add `bracket_lang_json` to `shortlist_targets` with:
  - `family = .bracket_lang`,
  - `source_kind = .grammar_json`,
  - `boundary_kind = .scanner_external_scanner`,
  - `real_external_scanner_proof_scope = .full_runtime_link`,
  - `standalone_parser_proof_scope = .coarse_serialize_only`,
  - notes that it is a staged small external-scanner runtime fixture,
  - success criteria covering load, prepare, emit, compile, link, parse `(())`, and
    root-not-error assertion.
- [ ] Update reporting code that enumerates proof scopes, including
  `buildExternalScannerRepoInventoryAlloc` if needed.
- [ ] Update JSON snapshots/tests that include target families, proof scopes, or
  shortlist inventories.
- [ ] Update `targets.zig` tests to cover the bracket-lang entry.

---

## Phase 6 — Regression Sweep

Run only the fast/local/runtime-link gates during the implementation pass.

- [ ] Run `zig fmt --check src`.
- [ ] Run `zig build test` and fix failures.
- [ ] Run:
  - `zig build test-link-no-external`,
  - `zig build test-link-keywords`,
  - `zig build test-link-external-scanner`,
  - `zig build test-link-multi-token-scanner`,
  - `zig build test-link-stateful-scanner`,
  - `zig build test-link-bracket-lang`.
- [ ] Run `zig build test-link-runtime` and confirm no regressions.
- [ ] Do not run `zig build test-compat-heavy` unless explicitly requested.
- [ ] Do not run the full compatibility target compile-smoke sweep unless explicitly
  requested.
- [ ] Update `GAPS_260425.md`:
  - Replace gap 3 ("Broader External-Scanner Runtime Parity") with a narrowed
    statement: Bash and Haskell promotion to `full_runtime_link` is blocked on
    parse-table construction cost and broader real-scanner fixture work, not on the
    basic generated scanner-table wiring.
  - Add "No Longer Gaps — Closed by ReWrite-5" entries for multi-token
    `valid_symbols` correctness, stateful scanner runtime link coverage, and the
    generated-from-grammar bracket scanner pipeline.
