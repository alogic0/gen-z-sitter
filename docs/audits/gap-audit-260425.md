# Gap Audit: gen-z-sitter vs tree-sitter — 2026-04-25

Reference: `tree-sitter/crates/generate/src/render.rs`,
`tree-sitter/lib/src/parser.h`, `tree-sitter/crates/generate/src/build_tables/`.

Zig entry points examined: `src/parser_emit/parser_c.zig`,
`src/parser_emit/compat.zig`, `src/parse_table/serialize.zig`,
`src/lexer/emit_c.zig`, `src/lexer/serialize.zig`,
`src/parse_table/resolution.zig`.

---

## 1. Confirmed Closed (matches reference)

**TSLanguage struct layout and all non-metadata fields** (`compat.zig` lines 41–141,
`parser_c.zig` lines 343–411).  
Every field defined in `parser.h:107–152` is emitted: `abi_version`,
`symbol_count`, `alias_count`, `token_count`, `external_token_count`,
`state_count`, `large_state_count`, `production_id_count`, `field_count`,
`max_alias_sequence_length`, `parse_table`, `small_parse_table` (conditional),
`small_parse_table_map` (conditional), `parse_actions`, `symbol_names`,
`symbol_metadata`, `public_symbol_map`, `alias_map`, `alias_sequences`,
`field_names`, `field_map_slices`, `field_map_entries`, `lex_modes`, `lex_fn`,
`keyword_lex_fn`, `keyword_capture_token`, `primary_state_ids`, `next_state_ids`,
`supertype_count` / `supertype_symbols` / `supertype_map_slices` /
`supertype_map_entries` (conditional), `reserved_words` (conditional), and the
external-scanner function pointers.  
Verified by reading `parser_c.zig:343–411` against `parser.h:107–152`.

**Small parse table conditional emission** (`parser_c.zig:286–308`, `354–356`).  
Array and pointer both guarded by `large_state_count_value < compacted.states.len`,
identical structure to Rust `render.rs:1362–1595`. Missing fields in the C
initializer default to NULL, which is correct for the runtime (it uses
`large_state_count` to decide whether to index them).

**Parse action list** (`parser_c.zig:310–324`).  
All six action types emitted (ACCEPT\_INPUT, RECOVER, SHIFT, SHIFT\_REPEAT,
SHIFT\_EXTRA, REDUCE). Count and reusable metadata match `render.rs:add_parse_action_list`.

**Lexer — EOF transitions** (`emit_c.zig:41`).  
`if (state_value.eof_target) |target|` correctly models the `eof_target` field
present in serialized lex states.

**Lexer — ADVANCE\_MAP** (`emit_c.zig:92+`).  
Dense character ranges produce `ADVANCE_MAP` table, matching
`render.rs::add_lex_state`.

**`ts_lex_keywords` emission** (`parser_c.zig:174–184`).  
Emitted only when `word_token` is present in the serialized table, matching the
Rust guard at `render.rs:1462`.

**Lex modes — `external_lex_state` and `reserved_word_set_id`** (`parser_c.zig:326–341`).  
Both fields emitted per-state: `.lex_state = {d}`, `.external_lex_state = {d}`,
`.reserved_word_set_id = {d}` — matches `render.rs::add_lex_modes`.

**External scanner: enum, symbol map, states** (`parser_c.zig:515–542`).  
`add_external_token_enum`, `add_external_scanner_symbol_map`, and
`add_external_scanner_states_list` equivalents all present, plus all five
callback function pointers.

**Field map `inherited` flag** (`parser_c.zig:221`, `serialize.zig:141–145`).  
`SerializedFieldMap` carries the boolean and `parser_c.zig` emits `.inherited = {}`.
Matches `render.rs::add_field_sequences`.

**Conflict resolution — dynamic precedence** (`resolution.zig:509–510`).  
Positive/negative dynamic precedence checked as primary reduce/reduce tiebreaker,
matching `build_parse_table.rs` ordering.

**Conflict resolution — reduce/reduce by production order** (`resolution.zig:349–351`).  
When precedence ties, earlier production wins. Deferred and expected conflict
variants both tracked.

**Non-terminal extras** (`resolution.zig`, builder level).  
Supported at the parse-table builder and serialization boundary; covered by
compile-smoke in `test-compat-heavy`.

**Primary state IDs, supertypes, alias sequences** (`parser_c.zig:259–268`, `365–406`).  
All three tables emitted with correct conditional guards.

---

## 2. Confirmed Gaps (still missing or wrong)

### Gap 1 — `TSLanguageMetadata` (.metadata) not emitted

**What is missing.**  
The `TSLanguage.metadata` field (`TSLanguageMetadata { major, minor, patch }`) is
never written to the C initializer in `parser_c.zig`. The field will read as
`{0, 0, 0}` in every generated parser.

**Where the reference does it.**  
`render.rs:1663–1669`:
```rust
add_line!(self, ".metadata = {{");
add_line!(self, ".major_version = {},", metadata.major);
add_line!(self, ".minor_version = {},", metadata.minor);
add_line!(self, ".patch_version = {},", metadata.patch);
add_line!(self, "}},");
```
`metadata` comes from the `semantic_version` parameter passed through from
`grammar.json`'s `.version` field.

**Where the Zig code is missing.**  
Two-step problem:
1. `SerializedTable` (`serialize.zig`) has no `version` / `metadata` field at
   all — the grammar-level version is dropped at the boundary between JSON
   parsing (`support/json.zig:18` shows `.version = "0.0.0"` as the parsed
   default) and serialized table construction.
2. `parser_c.zig` has no emit path for `.metadata = {...}` even if the data
   were available.

**Runtime impact.**  
Tools and language bindings that inspect `TSLanguage.metadata` to report or
validate the grammar's semantic version will always see `0.0.0`. This is a
correctness issue for any consumer that uses the version for compatibility
checks or display. The tree-sitter CLI `parse --version` output for third-party
grammars relies on this field.

**Fix sketch.**  
Add `grammar_version: [3]u8` (major, minor, patch) to `SerializedTable`.
Populate it in the serialization entry point from the parsed grammar JSON.
Emit `.metadata = { .major_version = {d}, .minor_version = {d}, .patch_version = {d} }` in `parser_c.zig` after the `abi_version` line.

---

## 3. Uncertain / Needs Deeper Check

### Item A — Lex modes array completeness

`parser_c.zig:328–331` falls back to `SerializedLexMode{ .lex_state = 0 }` for
states beyond `compacted.lex_modes.len`. In Rust, `render.rs::add_lex_modes`
iterates *all* states explicitly and assigns `.lex_state = 0` only for
non-terminal-extra end states (which have no real lex work to do).

**Concern.** If `serialize.zig` fails to populate a lex mode for a state that
genuinely needs a non-zero lex state, the fallback silently uses state 0.
This would produce mis-lexing at runtime with no error at generation time.

**What to check.** Audit `src/lexer/serialize.zig` to confirm it produces one
`SerializedLexMode` for every parse state, or that the only skipped states are
provably the same set that Rust assigns `.lex_state = 0`.

### Item B — Grammar version propagation path

The grammar JSON parser (`support/json.zig`) parses `.version` (default
`"0.0.0"`), but it is unclear whether the parsed value ever reaches the
serialization boundary. The gap in section 2 above assumed it is dropped; if
there is a code path that stores it somewhere not found by the grep, the fix is
simpler (just emit it from `parser_c.zig`).

**What to check.** Trace the grammar JSON struct from `json.zig` through the
pipeline entry point (`src/main.zig` or equivalent) to `SerializedTable` to
confirm whether version is stored or discarded.

### Item C — Keyword capture token silent zero

`parser_c.zig:151–154` resolves the word-token symbol with
`symbolIdForRef(...) orelse 0`. If the symbol reference is not found,
`keyword_capture_token` silently becomes 0 (the built-in `ts_builtin_sym_end`).

**Concern.** The Rust generator validates symbol references early; a missing
word_token would be a generator error, not a silent 0. The Zig generator
would produce a parser that treats the wrong symbol as the keyword capture
token — hard to diagnose at runtime.

**What to check.** Determine whether the upstream builder guarantees that
`word_token` in `SerializedTable` always names a valid symbol, making the `orelse 0`
branch unreachable. If not, add a generator-time assertion.
