# ReWrite-1: Align Emitter to tree-sitter ABI

**Goal**: make `src/parser_emit/` produce a `parser.c` that compiles and links against the
tree-sitter runtime (`lib/src/`).  
**Reference struct**: `tree-sitter/lib/src/parser.h:107–152` (`TSLanguage`).  
**Reference renderer**: `tree-sitter/crates/generate/src/render.rs`.

All changes are confined to `src/parser_emit/` and the serialization boundary in
`src/parse_table/serialize.zig` / `src/lexer/serialize.zig`.

---

## Phase 1 — Replace custom type hierarchy with ABI-compatible C definitions

These changes are all in `src/parser_emit/compat.zig`.

- [x] Remove the custom typedefs: `TSActionEntry`, `TSGotoEntry`, `TSCandidateEntry`,
  `TSUnresolvedEntry`, `TSSymbolInfo`, `TSStateTable`, `TSParser`, `TSRuntimeStateInfo`,
  `TSParserRuntime`.  Keep `TSCompatibilityInfo` only as a private build-time struct
  (not emitted into parser.c).
- [x] Emit the `TSParseActionEntry` union exactly as in `parser.h` (shift branch: `state`,
  `extra`, `repetition`; reduce branch: `child_count`, `symbol`, `dynamic_precedence`,
  `production_id`; plus `type` byte).
- [x] Emit `TSSymbolMetadata` struct `{ bool visible; bool named; bool supertype; }`.
- [x] Emit `TSFieldMapEntry` struct `{ TSFieldId field_id; uint8_t child_index; bool inherited; }`.
- [x] Emit `TSMapSlice` struct `{ uint16_t index; uint16_t length; }`.
- [x] Emit `TSLexerMode` struct `{ uint16_t lex_state; uint16_t external_lex_state; }`.
  Note: emitted as runtime-compatible `TSLexerMode`, including `reserved_word_set_id`.
- [x] Replace the emitted `TSLanguage` typedef with the layout-compatible struct matching
  `parser.h:107–152`, covering all fields in declaration order.
- [x] Update `writeContractPrelude()` / ABI emission to reproduce the required
  tree-sitter runtime ABI types from Zig-generated C, without including tree-sitter headers,
  so the project remains self-contained.

---

## Phase 2 — Emit parse tables in runtime format

These changes are in `src/parser_emit/parser_c.zig` and
`src/parse_table/serialize.zig`.

### 2a — TSParseActionEntry flat list

- [x] In `serialize.zig`, extend `SerializedTable` with a flat `parse_action_list` field:
  a deduplicated list of `TSParseActionEntry` values in the packed union format.
- [x] In `parser_c.zig`, emit `static const TSParseActionEntry ts_parse_actions[] = { … };`
  from `SerializedTable.parse_action_list`.
- [ ] Each action entry must encode `type` (shift/reduce/accept/recover) and the correct
  branch fields; shift entries need `state`, `extra`, `repetition`; reduce entries need
  `child_count`, `symbol`, `dynamic_precedence`, `production_id`.
  Partial: serialized/emitted action entries support shift/reduce/accept/recover fields,
  but the current parse action model only produces shift/reduce/accept and has no true
  extra/repetition source yet.

### 2b — Large-state parse table

- [x] In `serialize.zig`, compute `large_state_count`: states where the number of
  (symbol → action/goto) entries justifies a direct 2D row (match tree-sitter's heuristic:
  all states up to the first state that saves space in the small-table format).
- [x] Emit `static const uint16_t ts_parse_table[STATE_COUNT][SYMBOL_COUNT] = { … };`
  where each cell holds either a direct state ID (for goto) or an index into
  `ts_parse_actions` (for terminals).  Fill unused cells with `0` (no action).
  Note: emitted as `ts_parse_table[LARGE_STATE_COUNT][SYMBOL_COUNT]`, matching the runtime renderer shape.

### 2c — Small-state compressed table

- [ ] Identify states `>= large_state_count`.  Group their rows as (symbol, value) pairs,
  deduplicate identical rows.
- [x] Emit `static const uint16_t ts_small_parse_table[] = { … };` — packed groups of
  `[entry_count, sym0, val0, sym1, val1, …]`.
- [x] Emit `static const uint32_t ts_small_parse_table_map[] = { … };` — one offset per
  small state pointing into `ts_small_parse_table`.
  Note: initial small-table emission is present; identical-row deduplication is not done.

### 2d — Wire into TSLanguage initializer

- [x] Set `.parse_table = ts_parse_table`, `.small_parse_table = ts_small_parse_table`,
  `.small_parse_table_map = ts_small_parse_table_map`, `.parse_actions = ts_parse_actions`
  in the emitted `ts_language` struct literal.
- [x] Set `.large_state_count`, `.state_count`, `.production_id_count` from
  `SerializedTable`.
- [x] Remove the old per-state `ts_state_{id}_actions[]` / `ts_state_{id}_gotos[]` arrays
  and the `TSStateTable ts_states[]` array.

---

## Phase 3 — Emit symbol metadata tables

Data source: `PreparedGrammar.symbols` (`[]SymbolInfo`) in `src/ir/grammar_ir.zig` and
`src/ir/symbols.zig`.

- [ ] Emit `static const char * const ts_symbol_names[] = { … };` — one C string per
  symbol in symbol-ID order, matching `SymbolInfo.name`.
  Partial: table is emitted from collected serialized refs; it is not yet sourced from `PreparedGrammar.symbols`.
- [ ] Emit `static const TSSymbolMetadata ts_symbol_metadata[] = { … };` — `visible` and
  `named` from `SymbolInfo`, `supertype` from `SymbolInfo.supertype`.
  Partial: table is emitted with inferred placeholder metadata; it is not yet sourced from `SymbolInfo`.
- [ ] Compute and emit `static const TSSymbol ts_symbol_map[] = { … };` — maps internal
  symbol IDs to the deduplicated public IDs (collapsing anonymous/alias duplicates).
  Partial: identity map is emitted; public-ID deduplication is not done.
- [x] Set `.symbol_count`, `.symbol_names`, `.symbol_metadata`, `.public_symbol_map` in
  the `ts_language` literal.

---

## Phase 4 — Emit lex modes table

Data source: `src/lexer/serialize.zig` (`SerializedLexTable`) and the lexer pipeline.

- [ ] In `src/lexer/serialize.zig`, expose a `lex_modes` field: one `(lex_state,
  external_lex_state)` pair per parse state, in parse-state-ID order.
- [x] In `parser_c.zig`, emit `static const TSLexerMode ts_lex_modes[] = { … };`.
- [x] Set `.lex_modes = ts_lex_modes` in the `ts_language` literal.
- [x] Set `.lex_fn = ts_lex`, `.keyword_lex_fn = ts_lex_keywords` (NULL if no word token),
  `.keyword_capture_token` from `SerializedTable.word_token`.
  Note: `ts_lex` is a compiling stub and `keyword_lex_fn` is left NULL by zero-initialization.

  > Note: the function bodies `ts_lex()` and `ts_lex_keywords()` are not in scope for
  > this rewrite (see ReWrite-2).  Emit forward declarations and NULL stubs for now so
  > the struct literal compiles.

---

## Phase 5 — Emit field tables

Data source: `PreparedGrammar.variables` and the field metadata already tracked in
`src/parse_table/build.zig` via `production_id` → field assignments.

- [ ] Enumerate all distinct field names across all productions; assign sequential
  `TSFieldId` values starting at 1.
- [ ] Emit `static const char * const ts_field_names[] = { "", … };` — index 0 is the
  empty string; indices 1..N are field names.
- [ ] Build the flat `ts_field_map_entries[]` list: `{ field_id, child_index, inherited }`
  per (production, step) pair that carries a field name.
- [ ] Build `ts_field_map_slices[]`: one `{ index, length }` per production ID pointing
  into `ts_field_map_entries`.
- [ ] Emit both arrays and set `.field_count`, `.field_names`, `.field_map_slices`,
  `.field_map_entries` in the `ts_language` literal.

---

## Phase 6 — Fix alias sequences format

Data source: `SerializedTable.alias_sequences` (currently flat `[]SerializedAliasEntry`).

- [ ] Change the emitted format from the flat `TSAliasEntry ts_alias_sequences[]` array to
  the 2D layout `TSSymbol ts_alias_sequences[PRODUCTION_COUNT][MAX_ALIAS_SEQUENCE_LENGTH]`.
- [ ] Fill cells with the aliased symbol ID where an alias exists, `0` (UNNAMED) elsewhere.
- [ ] Emit `static const TSSymbol ts_alias_sequences[][MAX_ALIAS_SEQUENCE_LENGTH] = { … };`.
- [ ] Set `.alias_count`, `.max_alias_sequence_length`, `.alias_sequences` in the
  `ts_language` literal.

---

## Phase 7 — Remaining TSLanguage fields

These fields are straightforward once Phases 1–6 are done.

- [x] Emit `static const TSSymbol ts_non_terminal_alias_map[] = { … };` — pairs of
  `(original_symbol, alias_symbol)` terminated by `0`.  Set `.alias_map`.
- [x] Emit `static const TSStateId ts_primary_state_ids[] = { … };` — for each symbol,
  the lowest state ID where it is the leading production.  Set `.primary_state_ids`.
- [x] Set `.abi_version = LANGUAGE_VERSION` (15), `.token_count`, `.external_token_count`,
  `.alias_count` in the `ts_language` literal.
- [ ] Set `.name` to the grammar name string literal.  Leave `.metadata` zero-initialized
  (no semver yet).
  Partial: `.name` is emitted as `"generated"`, not the grammar name yet.

---

## Phase 8 — Cleanup and validation

- [ ] Delete `src/parser_emit/c_tables.zig` (diagnostic skeleton superseded by the real
  emission).
- [x] Remove all accessor functions from `parser_c.zig` (`ts_parser_find_symbol_id()`,
  `ts_parser_actions()`, etc.) — these are runtime functions, not emitted code.
- [ ] Update `src/parser_emit/compat.zig`: retain only the build-time constants
  (`language_version`, `min_compatible_language_version`) used during generation; remove
  all emitted accessor functions.
  Partial: emitted accessor functions are removed; `compat.zig` still owns self-contained ABI type emission.
- [ ] Run `zig build test` — all existing unit tests must still pass.
- [x] Run compile-smoke check: `zig cc -std=c11 -c` on an emitted parser.c. Fix any type
  or layout errors.
  Note: per project direction, this is a self-contained generated-C compile smoke with no tree-sitter header include.
- [ ] Verify a complete fixture (e.g. `behavioral_config`) links and the resulting shared
  library passes `ts_parser_set_language()` without crashing.
