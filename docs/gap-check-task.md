# Task: Gap Analysis — gen-z-sitter vs tree-sitter

## Context

`/home/oleg/prog/gen-z-sitter` is a Zig reimplementation of the tree-sitter **parser
generator** (the tool that takes a `grammar.js` / `grammar.json` and produces a
`parser.c`). The reference implementation is the Rust generator in
`/home/oleg/prog/tree-sitter`.

Approach this as a fresh audit. Examine both codebases independently and report what
you find.

---

## What to Compare

### A. Generator pipeline (grammar → parser.c)

Compare what the Rust generator emits in `parser.c` against what the Zig generator
emits. Focus on:

1. **`TSLanguage` struct fields** — read
   `tree-sitter/lib/src/parser.h` (the `TSLanguage` struct, ~lines 107–152) and check
   whether every field is populated in the Zig-emitted output.
   - Zig emitter entry point: `src/parser_emit/parser_c.zig`
   - Zig ABI definitions: `src/parser_emit/compat.zig`

2. **Parse tables** — compare the shape of emitted tables:
   - Reference: `tree-sitter/crates/generate/src/render.rs` functions
     `add_parse_table`, `add_parse_action_list`
   - Zig: `src/parse_table/serialize.zig` (`SerializedTable`) and the emission in
     `parser_c.zig`

3. **Lexer C code** — compare `ts_lex()` and `ts_lex_keywords()` structure:
   - Reference: `render.rs` functions `add_lex_function`, `add_lex_state`
   - Zig: `src/lexer/emit_c.zig`
   - Specific questions:
     - Are EOF transitions modeled and emitted? (`eof_target` field)
     - Is `ADVANCE_MAP` implemented for dense character ranges?
     - Is `ts_lex_keywords` emitted when `word_token` is present?

4. **Lex modes** — compare `ts_lex_modes[]`:
   - Reference: `render.rs::add_lex_modes`
   - Zig: `src/lexer/serialize.zig` (`SerializedLexMode`)
   - Specific questions:
     - Is `external_lex_state` populated (non-zero for grammars with externals)?
     - Is `reserved_word_set_id` populated from builder-level propagation?

5. **External scanner** — compare full external scanner emission:
   - Reference: `render.rs` functions `add_external_token_enum`,
     `add_external_scanner_symbol_map`, `add_external_scanner_states_list`
   - Zig: `parser_c.zig` (search for `writeExternalScannerTables` or similar)

6. **Field map** — check `inherited` flag in `ts_field_map_entries[]`:
   - Reference: `render.rs::add_field_sequences` — entries have an `inherited` bool
   - Zig: `src/parse_table/serialize.zig` (`SerializedFieldMap`)

7. **Conflict resolution** — check which conflict cases the Zig generator handles vs
   the Rust generator:
   - Reference: `build_tables/build_parse_table.rs`
   - Zig: `src/parse_table/resolution.zig`
   - Specific questions:
     - Reduce/reduce resolved by dynamic precedence?
     - Reduce/reduce resolved by textual/production order?
     - Non-terminal extras handled?

### B. Serialization boundary

The Zig generator uses `SerializedTable` as an intermediate representation between
the parse-table builder and the C emitter. Check whether `SerializedTable` captures
all data that the emitter needs, or whether any field is still a stub (`{ 0 }`, empty,
or `null` by default):

- `src/parse_table/serialize.zig` — read the full `SerializedTable` struct and all
  sub-structs. For each field, determine whether it is computed or defaulted.

---

## How to Examine the Code

Use targeted reads and searches — do not try to read every file in full.

Suggested approach:

```bash
# Recent changes in the Zig repo
git -C /home/oleg/prog/gen-z-sitter log --oneline -20

# What does parser_c.zig currently emit?
grep -n "ts_language\|lex_fn\|keyword_lex\|external_scanner\|reserved_word\|supertype\|primary_state\|alias_map" \
  /home/oleg/prog/gen-z-sitter/src/parser_emit/parser_c.zig | head -60

# What fields does SerializedTable have?
grep -n "pub const Serialized" \
  /home/oleg/prog/gen-z-sitter/src/parse_table/serialize.zig | head -30

# What does the Rust reference render?
grep -n "^    fn add_" \
  /home/oleg/prog/tree-sitter/crates/generate/src/render.rs | head -40

# Check for any stub zeros in serialization
grep -n "= 0\|= null\|= false\|= &.{}" \
  /home/oleg/prog/gen-z-sitter/src/parse_table/serialize.zig | head -30
```

---

## Output Format

Write a concise gap report with these sections:

### 1. Confirmed Closed (matches reference)
List items that are correctly implemented, with a one-line note on how you verified.

### 2. Confirmed Gaps (still missing or wrong)
For each gap: what is missing, where the reference does it, where the Zig code is
missing or wrong, and the runtime impact.

### 3. Uncertain / Needs Deeper Check
Items you could not verify fully from the code, with a note on what would be needed
to confirm.

---

## Scope Limits

- Focus on the **generator** (grammar → parser.c), not the tree-sitter C runtime itself.
- Do not assess incremental parsing, GLR stack behavior, or error recovery — those are
  runtime concerns, not generator concerns.
- Keep the report under ~400 lines. Prioritize correctness gaps over performance gaps.
