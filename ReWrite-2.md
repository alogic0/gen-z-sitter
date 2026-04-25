# ReWrite-2: Real Lexer Emission and Runtime Table Completion

**Goal**: generate a self-contained `parser.c` that can compile, link against the
tree-sitter runtime, and tokenize non-external input through a real `ts_lex`.

**Prerequisite**: ReWrite-1 emitter ABI alignment is complete.

**Reference algorithms**:

- `../tree-sitter/lib/src/parser.h`: lexer macros and `TSLanguage` layout.
- `../tree-sitter/crates/generate/src/render.rs`:
  - `add_non_terminal_alias_map`
  - `add_primary_state_id_list`
  - `add_supertype_map`
  - `add_lex_function`
  - `add_lex_state`
  - `add_lex_modes`
  - `add_reserved_word_sets`
  - `add_external_token_enum`
  - `add_external_scanner_symbol_map`
  - `add_external_scanner_states_list`
- `../tree-sitter/crates/generate/src/build_tables/build_parse_table.rs`:
  - parse-state `core_id`
  - terminal/non-terminal extra action handling
  - reserved-word-set assignment

Do not copy tree-sitter source files into this project. Reproduce the required algorithms
in Zig and emit self-contained C ABI definitions from our own code.

---

## Phase 1 — Validation Baseline

- [x] Run focused tests that cover the current RW-1 emitter surface and record the
  baseline.
- [x] Run `zig fmt --check src`.
- [x] Run a self-contained compile smoke for emitted parser C.
- [x] Defer broad/heavy compatibility harness tests until a phase changes cross-module
  behavior that those tests cover.

---

## Phase 2 — Preserve Tree-Sitter Runtime Metadata in Serialization

The C emitter should consume serialized data, not raw `PreparedGrammar`. Keep the
serialization boundary clean: all data required by `parser_c.zig` must be present in
`SerializedTable` or a serialized child model.

### 2a — Lex State Terminal Sets

- [x] Extend `assignLexStateIdsAlloc()` so it preserves one terminal set per assigned
  `lex_state_id`, in ID order.
- [x] Add the terminal-set list to `BuildResult` or another parse-table build artifact.
- [x] Serialize those terminal sets into `SerializedTable`, using terminal indexes or
  symbol refs that can be mapped to runtime symbol IDs later.
- [x] Keep `SerializedTable.lex_modes[parse_state].lex_state` aligned with this terminal
  set array.

### 2b — Parse-State Core IDs

Tree-sitter `add_primary_state_id_list` emits one entry per parse state:

```c
static const TSStateId ts_primary_state_ids[STATE_COUNT] = {
  [state_id] = first_state_with_same_core_id,
};
```

- [x] Add `core_id` to local parse states, following tree-sitter's parse item core
  identity.
- [x] Preserve `core_id` through parse-table build, serialization, and optimization.
- [x] Compute `SerializedTable.primary_state_ids` as the first state ID seen for each
  `core_id`.
- [x] Update state compaction to recompute or remap `primary_state_ids`.

### 2c — Alias-Map Source Data

Tree-sitter `add_non_terminal_alias_map` groups aliases by original non-terminal symbol:

```c
symbol_id, 1 + alias_count,
  public_symbol_id,
  alias_symbol_id_0,
  alias_symbol_id_1,
0,
```

- [x] Extend serialized alias data so each alias entry also carries the original step
  symbol, not just `production_id` and `step_index`.
- [x] Exclude default aliases when the local IR can identify them.
- [x] Deduplicate alias IDs per original symbol and sort by original symbol ID.
- [x] Build and emit the grouped alias map shape from serialized source data.

### 2d — Shift Flags and Extras

Tree-sitter distinguishes `Shift`, `ShiftExtra`, and `Shift { is_repetition }`.

- [x] Extend local parse actions so serialized shift actions can carry `extra` and
  `repetition`.
- [x] Set `extra = true` for terminal extra shifts derived from `SyntaxGrammar.extra_symbols`.
- [x] Set `repetition = true` for shifts that tree-sitter would mark `is_repetition`.
- [x] Keep non-terminal extra handling explicit. If local build still cannot model it,
  preserve a diagnostic blocker instead of silently emitting a normal shift.

### 2e — Reserved-Word State Data

Tree-sitter assigns a reserved word set to parse states while building actions for states
that see the `word_token`.

- [x] Serialize `reserved_word_set_id` into each `SerializedLexMode`.
- [x] Serialize reserved word sets in runtime symbol-ID form.

> Builder-level reserved-word-set propagation (threading set IDs through the
> parse-table action loop, mirroring `build_parse_table.rs`) is a larger task deferred
> to ReWrite-3.

---

## Phase 3 — Serialized Lex Table Model

Build lex tables before C emission and store a serialized representation. Do not pass
`PreparedGrammar` into `parser_emit`.

- [x] Add serialized lexer table structs in `src/lexer/serialize.zig`, for example:
  - `SerializedLexTable { states, start_state_id }`
  - `SerializedLexState { accept_symbol, eof_target, transitions }`
  - `SerializedLexTransition { ranges, next_state_id, skip }`
  - `SerializedCharacterRange { start, end_inclusive }`
- [x] Build one lex table per serialized lex-state terminal set, ordered by
  `lex_state_id`.
- [x] Convert `LexState.completion.variable_index` into serialized terminal symbol refs;
  final runtime symbol IDs are still resolved by the C emitter.
- [x] Add deinit helpers for serialized lex tables because they contain nested owned
  arrays.
- [x] Thread serialized lex tables through `optimize.prepareSerializedTableAlloc()`.

> EOF-specific transitions (`eof_target`) are deferred to ReWrite-3: they require adding
> an EOF transition field to the lexer model itself, which is a broader change than this
> rewrite scope.

---

## Phase 4 — Lexer C Emitter

Implement tree-sitter's `render.rs::add_lex_function` and `add_lex_state` shape in Zig.

### 4a — New Emitter Module

- [x] Create `src/lexer/emit_c.zig`.
- [x] Public entry point:

```zig
pub fn emitLexFunction(
    writer: anytype,
    fn_name: []const u8,
    lex_table: SerializedLexTable,
) !void
```

- [x] Keep generated C self-contained. The macros `START_LEXER`, `ADVANCE`,
  `ADVANCE_MAP`, `SKIP`, `ACCEPT_TOKEN`, and `END_STATE` are emitted by
  `parser_emit/compat.zig` from local Zig strings, matching the runtime ABI behavior.

### 4b — Function Shape

Emit the tree-sitter shape:

```c
static bool ts_lex(TSLexer *lexer, TSStateId state) {
  START_LEXER();
  eof = lexer->eof(lexer);
  switch (state) {
    case 0:
      ...
    default:
      return false;
  }
}
```

- [x] Emit one `case` per serialized lex state ID.
- [x] Emit `ACCEPT_TOKEN(symbol)` before transitions when the state has an accept action,
  matching tree-sitter.
- [x] Emit EOF transition handling before normal transitions when present:
  `if (eof) ADVANCE(target);`
- [x] Emit `END_STATE();` at the end of every state.

### 4c — Transition Conditions

- [x] Render single codepoints as `lookahead == X`.
- [x] Render adjacent two-character ranges as two equality checks, matching tree-sitter's
  readability optimization.
- [x] Render longer ranges as `start <= lookahead && lookahead <= end`.
- [x] Handle ranges containing `0` with `!eof` guards, matching tree-sitter's
  `add_character_range_conditions`.
- [x] Implement `SKIP(next)` for separator transitions and `ADVANCE(next)` for normal
  transitions.
- [x] Add `ADVANCE_MAP` only after the simple transition path works. Tree-sitter uses it
  when the leading simple transition range count is at least 8.

> Large character set constants are deferred: add only if generated code size or
> compile time becomes a problem in practice.

---

## Phase 5 — Wire Lexer Emission into `parser_c.zig`

- [x] Replace the stub `ts_lex` body with `lexer/emit_c.zig` output for the serialized
  main lex table.
- [x] Keep `.lex_fn = ts_lex`.
- [x] Keep `.keyword_lex_fn = NULL` until Phase 6 unless `word_token` lexing is complete.
- [x] Emit `ts_lex_modes` from serialized lex modes:
  - `.lex_state`
  - `.external_lex_state`
  - `.reserved_word_set_id`
- [x] For now, support grammars with no external tokens. Grammars with externals should
  remain blocked or compile-smoke-only until Phase 8.

---

## Phase 6 — Keyword Lexer and Reserved Words

Tree-sitter emits `ts_lex_keywords` only when `syntax_grammar.word_token` is present.

- [x] Build a keyword lex table that covers tokens competing with the word token.
- [x] Emit `ts_lex_keywords` using the same `emitLexFunction` path.
- [x] Set `.keyword_lex_fn = ts_lex_keywords` and `.keyword_capture_token` to the runtime
  symbol ID for `word_token`.
- [x] Serialize reserved word sets as `ts_reserved_words[set_count][MAX_RESERVED_WORD_SET_SIZE]`.
  Set index 0 as the empty/default set, matching tree-sitter.
- [x] Emit `MAX_RESERVED_WORD_SET_SIZE` from serialized data.
- [x] Set `.reserved_words` only when there is more than one reserved-word set.
- [x] Set `.max_reserved_word_set_size` unconditionally from the serialized maximum.

---

## Phase 7 — Runtime Stub Table Completion

### 7a — Non-Terminal Alias Map

- [x] Emit `ts_non_terminal_alias_map[]` in tree-sitter's grouped format:

```c
static const uint16_t ts_non_terminal_alias_map[] = {
  symbol_id, 1 + alias_count,
    public_symbol_id,
    alias_symbol_id,
  0,
};
```

- [x] Set `.alias_map = ts_non_terminal_alias_map`.

### 7b — Primary State IDs

- [x] Emit `static const TSStateId ts_primary_state_ids[STATE_COUNT]`.
- [x] Index by parse state ID, not symbol ID.
- [x] Values are the first parse state with the same serialized `core_id`.
- [x] Set `.primary_state_ids = ts_primary_state_ids`.

### 7c — Supertype Tables

Tree-sitter builds `ts_supertype_symbols`, `ts_supertype_map_slices`, and
`ts_supertype_map_entries` from a supertype-to-subtypes map. Aliased child types must map
through alias IDs where present.

- [x] Serialize `supertype_symbols` in runtime symbol-ID order.
- [x] Serialize `supertype_map_slices` indexed by supertype symbol ID.
- [x] Serialize deduplicated/sorted `supertype_map_entries`.
- [x] Emit and wire `.supertype_count`, `.supertype_symbols`,
  `.supertype_map_slices`, and `.supertype_map_entries`.

---

## Phase 8 — External Scanner Tables

External scanner support must be emitted as a complete set.

- [x] Serialize external scanner symbol identifiers in declared external-token order.
- [x] Emit `enum ts_external_scanner_symbol_identifiers`.
- [x] Emit `ts_external_scanner_symbol_map[EXTERNAL_TOKEN_COUNT]`, mapping scanner-local
  IDs to runtime symbol IDs.
- [x] Add external lex-state sets to the parse-table builder and serialize
  `external_lex_state` per parse state.
- [x] Emit `ts_external_scanner_states[external_state_count][EXTERNAL_TOKEN_COUNT]`.
- [x] Emit scanner function declarations:
  - `tree_sitter_NAME_external_scanner_create`
  - `tree_sitter_NAME_external_scanner_destroy`
  - `tree_sitter_NAME_external_scanner_scan`
  - `tree_sitter_NAME_external_scanner_serialize`
  - `tree_sitter_NAME_external_scanner_deserialize`
- [x] Wire `TSLanguage.external_scanner` with states, symbol map, and function pointers.
- [x] Keep grammars with externals blocked until all of the above are present.

---

## Phase 9 — End-to-End Validation

- [x] Run focused unit tests for each new serialized model and emitter helper.
- [ ] Run `zig build test` after the lexer path is wired.
- [x] Compile-smoke emitted parser C for no-external fixtures first.
- [x] Link one no-external fixture with the tree-sitter runtime from `../tree-sitter/lib/src`
  and parse minimal valid input. Assert the root is not an ERROR node.
  - Implemented as a serialized runtime fixture so this gate validates emitted C/runtime ABI
    behavior without pulling builder-level EOF propagation forward from ReWrite-3.
- [x] Add a keyword/reserved-word link test after Phase 6.
- [x] Add an external-scanner compile/link test after Phase 8.
