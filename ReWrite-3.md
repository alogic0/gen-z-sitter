# ReWrite-3: Runtime Acceptance and Remaining Correctness Gaps

**Goal**: prove that generated parsers are usable with the tree-sitter runtime, then
close the remaining algorithmic gaps that affect runtime behavior.

**Scope rule**: keep the project self-contained Zig. Do not copy tree-sitter source
files into this project. Link tests may compile against `../tree-sitter/lib/src` as an
external reference/runtime dependency.

**Prerequisite**: ReWrite-2 generator work is substantially complete. RW-2 left runtime
link tests open; those tests are the first RW-3 acceptance gate.

**Reference algorithms**:
- `../tree-sitter/crates/generate/src/build_tables/build_parse_table.rs`
- `../tree-sitter/crates/generate/src/build_tables/item_set_builder.rs`
- `../tree-sitter/crates/generate/src/lexer/mod.rs`
- `../tree-sitter/crates/generate/src/render.rs`
- `../tree-sitter/lib/src/parser.h`

---

## Phase 1 — No-External Runtime Link Test

First prove that a generated no-external parser can link with the tree-sitter runtime
and parse real input. This should be narrow and fast.

- [ ] Choose the smallest no-external fixture that already emits parser C cleanly
  (for example `parse_table_tiny` or another existing fixture with deterministic input).
- [ ] Emit `parser.c` for that fixture from the local Zig generator.
- [ ] Compile emitted `parser.c` together with the tree-sitter runtime sources from
  `../tree-sitter/lib/src` using `zig cc -std=c11`.
- [ ] Add a minimal C driver that calls:
  - `ts_parser_new()`
  - `ts_parser_set_language()`
  - `ts_parser_parse_string()`
  - `ts_tree_root_node()`
- [ ] Assert the root node is not an ERROR node and the program does not crash.
- [ ] Add a focused `zig build test-link-no-external` step.
- [ ] Keep this test independent from broad compatibility harnesses.

---

## Phase 2 — Link-Test Infrastructure

Make runtime link tests reusable before adding more cases.

- [ ] Add a small Zig helper module for writing temporary generated C, C driver source,
  and build artifacts.
- [ ] Add a helper that discovers or validates `../tree-sitter/lib/src` exists.
- [ ] Add a helper that invokes `zig cc` with the runtime include paths and runtime C
  sources needed by the driver.
- [ ] Return clear failure diagnostics: generator error, C compile error, link error,
  runtime assertion failure.
- [ ] Keep generated artifacts in test temp directories, not checked into the repo.

---

## Phase 3 — Keyword / Reserved-Word Runtime Link Test

RW-2 emits keyword lexing and reserved-word tables. RW-3 must prove the runtime uses
them correctly.

- [ ] Choose or add a small grammar with `word`/keyword capture where a keyword competes
  with an identifier.
- [ ] Emit and link the parser with the Phase 2 link-test helper.
- [ ] Parse input containing the keyword and a normal identifier.
- [ ] Assert the keyword wins over the generic identifier where expected.
- [ ] Verify `ts_lex_modes[]` contains non-zero `reserved_word_set_id` for the state
  that needs the reserved set.
- [ ] Add a focused `zig build test-link-keywords` step.

---

## Phase 4 — External Scanner Compile/Link Test

RW-2 emits external scanner metadata and function wiring. RW-3 must prove the generated
parser links with an external scanner implementation.

- [ ] Choose the smallest external-scanner fixture with a minimal scanner C file.
- [ ] Compile emitted `parser.c`, scanner C, runtime C, and a minimal driver.
- [ ] Parse minimal valid input.
- [ ] Assert the root node is not an ERROR node and the scanner functions are linked.
- [ ] Add a focused `zig build test-link-external-scanner` step.

---

## Phase 5 — Builder-Level Reserved-Word-Set Propagation

RW-2 serializes reserved word sets and has a conservative serialization-side
`reserved_word_set_id` assignment. The remaining gap is tree-sitter-style propagation
through the parse-table builder, especially `following_reserved_word_set`.

- [ ] Study and summarize the relevant upstream logic in:
  - `build_tables/item.rs`
  - `build_tables/item_set_builder.rs`
  - `build_tables/build_parse_table.rs`
- [ ] Add reserved-word-set identity to the local parse item / item-set data model.
- [ ] When closure propagates lookaheads, also propagate the following reserved-word
  set ID, matching tree-sitter's max/set merge behavior.
- [ ] During parse-state construction, assign the state reserved-word set when the
  state sees `word_token` as the next symbol or lookahead.
- [ ] Preserve that ID through lex-state assignment and state minimization.
- [ ] Remove or simplify the temporary serialization-side derivation once builder-level
  tracking is authoritative.
- [ ] Add focused tests for:
  - direct `word_token` next-step context
  - propagated lookahead context
  - state minimization preserving non-zero reserved-word set IDs

---

## Phase 6 — EOF Transitions in Lexer Model

The C emitter already handles `SerializedLexState.eof_target`, but the local lexer model
does not currently produce EOF successors. Do not implement this from guesswork.

- [ ] Compare local lexer NFA/DFA code with `../tree-sitter/crates/generate/src/lexer/mod.rs`.
- [ ] Write a short note in this plan describing the exact upstream EOF-transition rule
  before changing code.
- [ ] Add an EOF-transition concept to the local lexer model only after the rule is
  clear.
- [ ] Propagate EOF edges through NFA-to-DFA construction.
- [ ] Populate `SerializedLexState.eof_target` from the computed EOF successor.
- [ ] Keep existing `emit_c.zig` output shape: `if (eof) ADVANCE(target);`.
- [ ] Add focused lexer serialization and emitter tests for a real EOF transition.

---

## Phase 7 — Inherited Field Metadata

RW-2 emits field map tables, but inherited field metadata is still always false because
the local IR does not track inlined-field origin.

- [ ] Identify where inlined rule expansion hoists field annotations into parent
  productions.
- [ ] Add an `inherited` flag to the local field/production-step metadata.
- [ ] Preserve the flag through syntax extraction, flattening, parse-table production
  collection, and serialization.
- [ ] Emit `TSFieldMapEntry.inherited = true` where appropriate.
- [ ] Add a fixture with an inlined rule that contributes a field.
- [ ] Assert serialized field map entries and emitted `ts_field_map_entries[]` contain
  at least one inherited entry.

---

## Phase 8 — Conflict Resolution and Non-Terminal Extras

These are correctness-sensitive and should come after runtime link tests, because they
can change parse-table behavior broadly.

### 8a — Reduce/Reduce Without Expected Conflicts

- [ ] Compare local `resolution.zig` against tree-sitter's reduce/reduce resolution.
- [ ] Verify the exact tie-break order: dynamic precedence first, then production order
  only when tree-sitter does that for the same conflict class.
- [ ] Implement the narrow matching fallback.
- [ ] Add a fixture that tree-sitter resolves by the same rule.
- [ ] Assert the local serialized decision is chosen, not blocked.

### 8b — Non-Terminal Extras

- [ ] Model extras that are non-terminals in parse-table construction.
- [ ] Add extra-rule closure items where tree-sitter would allow non-terminal extras.
- [ ] Ensure resulting extra shifts are represented as extra actions in serialized data.
- [ ] Unblock the smallest fixture that currently depends on non-terminal extras.
- [ ] Add compile-smoke coverage for that fixture.

---

## Phase 9 — Regression and Compatibility Sweep

Run broad checks only after the focused runtime link tests and high-risk correctness
changes are in place.

- [ ] Run `zig build test` and fix failures.
- [ ] Run compile-smoke on the full compatibility target set.
- [ ] Run the behavioral harness and compare against the pre-RW-3 baseline.
- [ ] Update `GAPS_260425.md`: move closed items to "No Longer Gaps" and refresh the
  remaining open items.

---

## Already Completed Before RW-3

These items appeared in the first RW-3 draft but were already implemented during RW-2:

- [x] Serialized shift actions can carry `extra` and `repetition`.
- [x] Terminal/external extra shifts are marked `extra = true` from
  `SyntaxGrammar.extra_symbols`.
- [x] Non-terminal extras remain explicit blockers instead of silent normal shifts.
- [x] Repeat-auxiliary conflicts mark serialized shift actions with `repetition = true`.
- [x] Emitted `ts_parse_actions[]` includes `.extra` and `.repetition`.
- [x] Reserved word sets are serialized and emitted in runtime symbol-ID form.
- [x] `SerializedLexMode.reserved_word_set_id` has conservative serialization-side
  assignment.
