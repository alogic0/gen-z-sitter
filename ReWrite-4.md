# ReWrite-4: Grammar Metadata, Lex-Mode Coverage, and Generator Accuracy

**Goal**: close the one confirmed correctness gap left by RW-3 (grammar semantic version
not propagated or emitted), resolve three uncertain items from the April 2026 gap audit
(`docs/gap-audit-260425.md`), and leave the generator output accurately matching the
reference for all fields that a grammar consumer can inspect at runtime.

**Scope rule**: keep the project self-contained Zig. Do not copy tree-sitter source
files into this project. Tests may compile against `../tree-sitter/lib/src` as an
external reference/runtime dependency.

**Prerequisite**: ReWrite-3 is substantially complete. All RW-3 acceptance gates pass,
including `zig build test-compat-heavy`.

**Non-goal for RW-4**: do not refresh the stale EOF-aware `test-pipeline` exact string
goldens unless a RW-4 change directly touches that output. Those goldens are a separate
post-RW-3 cleanup item recorded in `GAPS_260425.md`.

**Reference algorithms**:
- `../tree-sitter/lib/src/parser.h`: `TSLanguageMetadata` struct (lines 21–25),
  `TSLanguage.metadata` field (line 151).
- `../tree-sitter/crates/generate/src/render.rs`:
  - `add_lex_modes` — emits one `TSLexerMode` entry per parse state.
  - `generate` / struct `CCodeGenerator` field `metadata: Option<Metadata>` — carries
    the grammar semantic version through to emission.
  - the metadata-emission block near the `TSLanguage` initializer emits
    `.metadata = { .major_version, .minor_version, .patch_version }`.
- `../tree-sitter/crates/generate/src/build_tables/build_parse_table.rs`: parse-state
  lex-mode assignment.

Line numbers in the reference files are approximate; prefer symbol/function names when
checking the current upstream checkout.

---

## Phase 1 — Verify Lex-Mode Array Coverage (Audit Item A)

**Background.** `parser_c.zig:328–331` emits one `TSLexerMode` per state, using a
fallback `SerializedLexMode{ .lex_state = 0 }` for states whose index exceeds
`compacted.lex_modes.len`.  If `serialize.zig` fails to produce a lex mode for a state
that genuinely needs a non-zero `lex_state`, the fallback silently routes that state to
lex state 0 — the wrong lexer DFA start — causing mis-lexing with no generation-time
error.

The Rust reference (`render.rs::add_lex_modes`) iterates **all** parse states in a
single pass. Non-terminal-extra end states receive `(TSStateId)(-1)` because no further
lexing is required.

**Audit tasks (read-only — fix only if a real gap is found).**

- [x] Read `src/lexer/serialize.zig`: identify the function that produces
  `SerializedLexMode` entries and verify it produces exactly one entry per parse state
  (i.e. the output slice is `STATE_COUNT` long, not shorter).
- [x] Read `src/parse_table/serialize.zig` or the optimizer: confirm that
  `compacted.lex_modes.len == compacted.states.len` after optimization.
- [x] Read `render.rs::add_lex_modes` (lines ~1160–1200) and note which states receive
  the sentinel lex state in the Rust output. Confirm whether the local model can
  represent that sentinel separately from ordinary lex state 0.
- [x] If `compacted.lex_modes.len < compacted.states.len` is possible, document the
  conditions under which it happens and whether the fallback value is correct for those
  states.
- [x] Write a short note here summarizing the finding before making any code change.

**Finding.** `lexer/serialize.zig::buildLexModesAlloc` allocates exactly one
`SerializedLexMode` per serialized parse state, and `parser_emit/optimize.zig`
recomputes lex modes from the compacted state slice. The emitter fallback is therefore
not reachable through the normal serialized/optimized pipeline. Upstream emits a
`(TSStateId)(-1)` lex state for non-terminal-extra end states; the local boundary does
not currently carry a separate sentinel flag, so RW-4 does not change that behavior in
this pass.

**If a real gap is found**, add a sub-phase (Phase 1b) with:

- [ ] Fix `serialize.zig` to emit one `SerializedLexMode` per state.
- [ ] Add a test that verifies `lex_modes.len == states.len` for a fixture with both
  normal states and non-terminal-extra end states.
- [ ] Re-run `zig build test-compat-heavy` and confirm no regressions.

---

## Phase 2 — Audit Keyword Capture Token Resolution (Audit Item C)

**Background.** `parser_c.zig:151–154` resolves the word-token symbol via
`symbolIdForRef(...) orelse 0`. Symbol ID 0 is `ts_builtin_sym_end` (EOF). If the
word-token reference is missing from the emitted symbol table — which should be a
generator error — the `keyword_capture_token` field silently points to EOF, causing the
runtime keyword checker to match no keywords, with no error at generation time.

In the Rust generator, symbol references are validated during grammar normalization, so
an invalid word-token reference is caught before emission.

- [x] Determine whether `symbolIdForRef` for the word-token can legitimately return
  `null` in the current Zig pipeline (i.e., is there a grammar that reaches emission
  with a word-token that has no runtime symbol ID?).
- [ ] If `null` is possible and incorrect: replace `orelse 0` with an assertion or a
  returned error that names the missing symbol.
- [x] If `null` is structurally impossible (the builder guarantees the word-token always
  has a symbol ID by the time emission runs): add a comment explaining the invariant and
  change `orelse 0` to `orelse unreachable` so a future violation surfaces at debug
  time.
- [x] Add a test for a grammar with `word_token` and confirm the emitted
  `.keyword_capture_token` is the correct non-zero symbol ID.

---

## Phase 3 — Propagate Grammar Semantic Version to SerializedTable (Gap 1 / Audit Item B)

**Background.** `grammar.json` carries a `.version` field (for example `"1.2.3"`) that
identifies the grammar's own semantic version. Audit Item B asks whether that parsed
value is already preserved anywhere downstream. The Rust generator parses this as
`semantic_version: Option<(u8, u8, u8)>` and passes it through to `CCodeGenerator`
(field `metadata: Option<Metadata>`). The Zig pipeline should be traced through
`src/grammar/json_loader.zig`, `src/grammar/raw_grammar.zig`, and the prepared/serialized
grammar path to confirm whether `.version` is currently stored or discarded.
`src/support/json.zig` is only a JSON stringification helper and is not the grammar
schema owner.

This phase adds the version to the serialization boundary so the emitter can use it.

- [x] Read `src/grammar/json_loader.zig` and `src/grammar/raw_grammar.zig`; identify
  the grammar JSON struct. Confirm the `.version` field is parsed and what type it
  currently has (string, ignored, or partially stored).
- [x] Trace the grammar JSON struct through `parse_grammar.zig`, `grammar_ir.zig`,
  and the parse-table pipeline to confirm whether version data is currently stored or
  discarded.
- [x] Parse the version string into three `u8` components (major, minor, patch) at the
  JSON parsing stage. Tolerate missing or malformed version strings by defaulting to
  `(0, 0, 0)`.
- [x] Add a `grammar_version: [3]u8` field to `SerializedTable`
  (`src/parse_table/serialize.zig`), ordered `[major, minor, patch]`.
- [x] Thread the parsed version from the JSON struct through the pipeline entry point
  into the `SerializedTable` constructor (or whatever function fills the top-level
  serialized struct).
- [x] Verify that `compacted` / optimized copies preserve the field unchanged (it is
  metadata, not table data, so optimization should be a no-op for this field).
- [x] Add a test that parses a grammar JSON with `"version": "2.3.4"` and asserts
  `serialized.grammar_version == [2, 3, 4]`.
- [x] Add a test that parses a grammar JSON with no `.version` field and asserts
  `serialized.grammar_version == [0, 0, 0]`.

---

## Phase 4 — Emit TSLanguageMetadata (Gap 1, step 2)

**Background.** `parser.h:21–25` defines:

```c
typedef struct TSLanguageMetadata {
  uint8_t major_version;
  uint8_t minor_version;
  uint8_t patch_version;
} TSLanguageMetadata;
```

The `TSLanguage` struct has `TSLanguageMetadata metadata` as its last field (line 151).
`compat.zig` already emits both the typedef (lines 48–51) and the struct member (line
141). `parser_c.zig` does not currently emit `.metadata = {...}` in the language
initializer, so the field reads as `{0, 0, 0}` in every generated parser regardless of
the grammar's declared version.

The Rust reference emits (render.rs:1663–1670):

```rust
add_line!(self, ".metadata = {{");
add_line!(self, ".major_version = {},", metadata.major);
add_line!(self, ".minor_version = {},", metadata.minor);
add_line!(self, ".patch_version = {},", metadata.patch);
add_line!(self, "}},");
```

- [x] In `parser_c.zig`, locate the section that emits the `TSLanguage` struct
  initializer (currently around lines 343–411).
- [x] Add emission of `.metadata = { .major_version = {d}, .minor_version = {d},
  .patch_version = {d} }` using `compacted.grammar_version[0]`,
  `compacted.grammar_version[1]`, `compacted.grammar_version[2]`.
- [x] Place the emission before the closing brace, matching the
  field order in `parser.h`.
- [x] Add a focused emitter test: given a `SerializedTable` with
  `grammar_version = [1, 2, 3]`, assert the emitted C contains
  `.metadata = { .major_version = 1, .minor_version = 2, .patch_version = 3 }`.
- [x] Add a second emitter test: `grammar_version = [0, 0, 0]` emits
  `.metadata = { .major_version = 0, .minor_version = 0, .patch_version = 0 }` (no
  special-casing; always emit).
- [ ] Compile-smoke one fixture through the full path (JSON → SerializedTable → parser.c
  → `zig cc`) and confirm the output compiles without warnings.

---

## Phase 5 — Runtime Validation of Metadata Field

Prove that the runtime can read the emitted `metadata` field correctly.

- [x] Extend the existing no-external runtime link test
  (`zig build test-link-no-external`) or add a sibling test that:
  - Generates a no-external parser fixture with a known non-zero version such as
    `"3.1.4"`.
  - Calls `ts_language_metadata()` from the tree-sitter runtime in the C driver.
  - Asserts `major == 3`, `minor == 1`, `patch == 4`.
- [x] Include the correct runtime header for `ts_language_metadata()`; it is implemented
  in `../tree-sitter/lib/src/language.c`.
- [x] Keep the test in `zig build test-link-no-external` or add a focused
  `zig build test-link-metadata` step.

---

## Phase 6 — Regression and Compatibility Sweep

Run broad checks only after all correctness changes are in place.

- [x] Run `zig fmt --check src`.
- [x] Run `zig build test` and fix failures.
- [ ] Run `zig build test-compat-heavy` and confirm no regressions against the RW-3
  baseline.
- [ ] Run compile-smoke on the full compatibility target set.
- [ ] Update `GAPS_260425.md`: move Gap 1 (metadata) to "No Longer Gaps"; update or
  close Audit Items A, B, C depending on findings from Phases 1 and 2.
