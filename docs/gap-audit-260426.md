# Gap Audit Reevaluation — 2026-04-26

Reevaluates `docs/gap-audit-260425.md` against `GAPS_260425.md` (updated through RW-5)
and the current state of both codebases.

---

## Status of the 2026-04-25 Audit Items

### Gap 1 — `TSLanguageMetadata` not emitted → **CLOSED (RW-4)**

Verified: `parser_c.zig:414–415` now emits
`.metadata = { .major_version = {d}, .minor_version = {d}, .patch_version = {d} }`.
`SerializedTable` carries `grammar_version: [3]u8` (`serialize.zig:203`).
Tests at `parser_c.zig:1361–1399` cover both non-zero and zero versions.

### Item A — Lex modes array completeness → **CLOSED (RW-4)**

Verified: `lexer/serialize.zig:88` now emits one `SerializedLexMode` per parse state.
Non-terminal-extra end states receive `std.math.maxInt(u16)` (the upstream sentinel),
not a fallback zero.

### Item B — Grammar version propagation path → **CLOSED (RW-4)**

Same fix as Gap 1. Version flows from the grammar JSON loader through
`PreparedGrammar.grammar_version` into `SerializedTable.grammar_version`.

### Item C — Keyword capture token silent zero → **CLOSED (RW-4)**

Verified: `parser_c.zig:153` now uses `orelse unreachable` instead of `orelse 0`.

---

## Errors in the 2026-04-25 Audit

### Invented field: `next_state_ids`

The audit listed `next_state_ids` as a confirmed-closed `TSLanguage` field.
This field **does not exist** in `parser.h:107–152`. The actual struct has
`primary_state_ids` (line 143), which is correctly emitted. The string
`next_state` appears only as a C goto label inside the lexer macros
(`parser.h:189`), not as a struct field. The Zig emitter never needed to emit
it, so there is no runtime impact — but the audit listed a non-existent field
as evidence of coverage.

---

## New Confirmed Gaps (not in the 2026-04-25 audit)

### Gap 2 — Large character sets: `TSCharacterRange` / `set_contains` not emitted

**What is missing.**
The upstream generator (`render.rs::add_character_set`, `add_lex_state`) emits
a `static const TSCharacterRange name[] = {...}` table for any character class
with ≥ 8 ranges. In the lex state body it then calls:

```c
set_contains(name, count, lookahead)
```

where `set_contains` is a binary-search inline function defined at
`parser.h:154–170`. The Zig `emit_c.zig` has no support for this path — it
always expands every transition as explicit inline range comparisons, regardless
of how many ranges the character class has.

**Reference.**
- `build_tables/build_lex_table.rs:19`: `LARGE_CHARACTER_RANGE_COUNT = 8`
- `render.rs:946`: guard `if simplified_chars.range_count() >= LARGE_CHARACTER_RANGE_COUNT`
- `render.rs:1116–1150`: `add_character_set` emitting `TSCharacterRange` tables
- `parser.h:154–170`: `set_contains` binary search over `TSCharacterRange`

**Zig status.**
`emit_c.zig:6`: `const advance_map_threshold = 8` — this is a different
optimization (leading single-character transitions → `ADVANCE_MAP`). There is
no `TSCharacterRange` path and no `set_contains` call anywhere in `emit_c.zig`
or `compat.zig`.

**Correctness impact.** None. The inline range comparisons are semantically
equivalent. Grammars that use this code path will compile and produce correct
parsers.

**Practical impact.** Grammars with large Unicode character classes — any
pattern matching a script, category (`\p{L}`, `\p{N}`), or wide range — will
produce lex states with many inline conditions instead of a compact
`set_contains` call. For grammars like tree-sitter-Haskell (which has large
Unicode operator ranges) this inflates the emitted C source and slows C
compilation. Bash and Zig grammars are less affected.

**Fix sketch.**
1. Add `TSCharacterRange` typedef to `compat.zig`.
2. In `emit_c.zig`, detect transitions whose character class has ≥ 8 ranges
   that are not already handled by `ADVANCE_MAP`.
3. Emit `static const TSCharacterRange name[] = {...}` before the lex function.
4. Replace the inline conditions with `set_contains(name, count, lookahead)`.

### Gap 3 — Compiler optimization pragmas not emitted for large lexers

**What is missing.**
When the main lex table has > 300 states, the upstream generator emits:

```c
#ifdef _MSC_VER
#pragma optimize("", off)
#elif defined(__clang__)
#pragma clang optimize off
#elif defined(__GNUC__)
#pragma GCC optimize ("O0")
#endif
```

These suppress optimizations for the large `ts_lex` function, because compiling
it with full optimization takes much longer than the negligible parse-time
benefit justifies.

**Reference.** `render.rs::add_pragmas` (lines 352–375): threshold is
`self.main_lex_table.states.len() > 300`.

**Zig status.** `compat.zig` emits `#pragma GCC diagnostic ignored
"-Wmissing-field-initializers"` (for `UNUSED`) but no optimization-suppression
pragma. The lex state count threshold check is absent.

**Correctness impact.** None. Generated parsers are functionally correct
regardless.

**Practical impact.** For grammars with large lex tables (Haskell, Bash),
release builds of generated parsers will spend more time in the compiler's
optimizer for `ts_lex`. The same parser compiled by the reference generator
will have this overhead suppressed.

**Fix sketch.**
After serializing the lex table, check whether
`serialized.lex_tables[0].states.len > 300` and conditionally emit the
`#ifdef _MSC_VER ... #endif` pragma block in `compat.zig` or `parser_c.zig`.

---

## Items Not in Either Document (Scope Reminders)

The following remain intentionally out of scope per the project's scope rules
and are not gaps:

- Incremental parsing, GLR stack, error recovery — runtime, not generator.
- `repeat_choice_seq_js` shift/reduce conflict — confirmed that upstream tree-sitter
  also rejects this grammar as unresolved. The `expected_blocked` classification
  is correct.
- Parse-table construction memory cost — tracked in `GAPS_260425.md` gap 1,
  not a generator correctness gap.

---

## Accuracy Assessment of `GAPS_260425.md`

`GAPS_260425.md` (updated through RW-5) is accurate:

- Remaining gap 1 (parse-table construction cost): confirmed open, not addressed
  by any rewrite.
- Remaining gap 2 (pipeline goldens EOF refresh): confirmed open, isolated to
  `zig build test-pipeline`.
- Remaining gap 3 (broad external-scanner promotion): correctly scoped — Bash
  and Haskell blocked by construction cost and scanner fixture work, not by
  wiring. RW-5 closed the basic surfaces.
- All "No Longer Gaps" entries (RW-1 through RW-5) verified against the current
  source and are accurate.

**Two items to add to `GAPS_260425.md`** (new findings above):
- Large character sets / `TSCharacterRange` / `set_contains` (Gap 2 above) —
  no correctness impact but affects emitted code size and C compile time for
  Unicode-heavy grammars.
- Compiler optimization pragma for large lexers (Gap 3 above) — no correctness
  impact but affects C compile time for grammars with > 300 lex states.
