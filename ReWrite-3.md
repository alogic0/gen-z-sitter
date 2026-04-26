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

Status: the focused no-external runtime link test now builds the parser from a tiny
local grammar through the parse-table builder, serializes EOF actions, emits parser C,
links it with `../tree-sitter/lib/src`, and parses real input.

- [x] Choose the smallest no-external fixture that already emits parser C cleanly
  (for example `parse_table_tiny` or another existing fixture with deterministic input).
- [x] Emit `parser.c` for that fixture from the local Zig generator.
- [x] Compile emitted `parser.c` together with the tree-sitter runtime sources from
  `../tree-sitter/lib/src` using `zig cc -std=c11`.
- [x] Add a minimal C driver that calls:
  - `ts_parser_new()`
  - `ts_parser_set_language()`
  - `ts_parser_parse_string()`
  - `ts_tree_root_node()`
- [x] Assert the root node is not an ERROR node and the program does not crash.
- [x] Add a focused `zig build test-link-no-external` step.
- [x] Keep this test independent from broad compatibility harnesses.

---

## Phase 2 — Link-Test Infrastructure

Make runtime link tests reusable before adding more cases.

- [x] Add a small Zig helper module for writing temporary generated C, C driver source,
  and build artifacts.
- [x] Add a helper that discovers or validates `../tree-sitter/lib/src` exists.
- [x] Add a helper that invokes `zig cc` with the runtime include paths and runtime C
  sources needed by the driver.
- [x] Return clear failure diagnostics: generator error, C compile error, link error,
  runtime assertion failure.
- [x] Keep generated artifacts in test temp directories, not checked into the repo.

---

## Phase 3 — Keyword / Reserved-Word Runtime Link Test

RW-2 emits keyword lexing and reserved-word tables. RW-3 must prove the runtime uses
them correctly.

- [x] Choose or add a small serialized fixture with `word`/keyword capture where a
  keyword competes with an identifier.
- [x] Emit and link the parser with the Phase 2 link-test helper.
- [x] Parse input containing the keyword.
- [x] Assert the keyword wins over the generic identifier where expected.
- [x] Verify `ts_lex_modes[]` contains non-zero `reserved_word_set_id` for the state
  that needs the reserved set.
- [x] Add a focused `zig build test-link-keywords` step.

---

## Phase 4 — External Scanner Compile/Link Test

RW-2 emits external scanner metadata and function wiring. RW-3 must prove the generated
parser links with an external scanner implementation.

- [x] Choose the smallest serialized external-scanner fixture with a minimal scanner C
  file.
- [x] Compile emitted `parser.c`, scanner C, runtime C, and a minimal driver.
- [x] Parse minimal valid input.
- [x] Assert the root node is not an ERROR node and the scanner functions are linked.
- [x] Add a focused `zig build test-link-external-scanner` step.

---

## Phase 5 — Builder-Level Reserved-Word-Set Propagation

RW-2 serializes reserved word sets and has a conservative serialization-side
`reserved_word_set_id` assignment. The remaining gap is tree-sitter-style propagation
through the parse-table builder, especially `following_reserved_word_set`.

Upstream reference check: reserved-word context is tracked on item-set entries as
`following_reserved_word_set`. When closure/goto combines entries, tree-sitter merges
the reserved-word-set identity by keeping the largest set ID. Parse states receive a
reserved-word set when the next symbol is the grammar `word_token` with a direct
reserved context, or when a completed item has `word_token` in its lookahead and carries
a propagated following reserved-word set.

- [x] Study and summarize the relevant upstream logic in:
  - `build_tables/item.rs`
  - `build_tables/item_set_builder.rs`
  - `build_tables/build_parse_table.rs`
- [x] Add reserved-word-set identity to the local parse item / item-set data model.
- [x] When closure propagates lookaheads, also propagate the following reserved-word
  set ID, matching tree-sitter's max/set merge behavior.
- [x] During parse-state construction, assign the state reserved-word set when the
  state sees `word_token` as the next symbol or lookahead.
- [x] Preserve that ID through lex-state assignment and state minimization.
- [x] Remove or simplify the temporary serialization-side derivation once builder-level
  tracking is authoritative.
- [x] Add focused tests for:
  - direct `word_token` next-step context
  - propagated lookahead context
  - state minimization preserving non-zero reserved-word set IDs

---

## Phase 6 — EOF Transitions in Lexer Model

The C emitter already handles `SerializedLexState.eof_target`, but the local lexer model
does not currently produce EOF successors. Do not implement this from guesswork.

Upstream reference check: EOF handling lives in
`../tree-sitter/crates/generate/src/build_tables/build_lex_table.rs`. The lexer state
identity includes the NFA state set plus an `eof_valid` flag. When `eof_valid` is true,
the state gets an EOF action to an empty NFA-state-set state with `eof_valid = false`.
Normal transitions propagate EOF validity only across separator transitions:
`next_eof_valid = eof_valid and transition.is_separator`.

- [x] Compare local lexer NFA/DFA code with the upstream build-lex-table code.
- [x] Write a short note in this plan describing the exact upstream EOF-transition rule
  before changing code.
- [x] Add an EOF-transition concept to the local lexer model only after the rule is
  clear.
- [x] Propagate EOF edges through NFA-to-DFA construction.
- [x] Populate `SerializedLexState.eof_target` from the computed EOF successor.
- [x] Keep existing `emit_c.zig` output shape: `if (eof) ADVANCE(target);`.
- [x] Add focused lexer serialization and emitter coverage for a real EOF transition.

---

## Phase 7 — Parser EOF Symbol and Accept Actions

Phase 6 gives generated lexers a runtime EOF transition. Generated-from-grammar parsers
still need a real parser-side EOF/end symbol so start-item lookaheads can produce EOF
reduce/accept actions. This phase is the missing prerequisite for replacing the
serialized no-external runtime fixture with a real generated-from-grammar fixture.

Upstream reference check: `rules.rs` models EOF as `SymbolType::End` with a distinct
`Symbol::end()` and a dedicated `TokenSet.eof` bit. `build_parse_table.rs` seeds the
starting item with `Symbol::end()` as its lookahead, and render/display code maps both
EOF-like end symbols to `EOF` without treating them as normal grammar terminals.

- [x] Study and summarize the upstream parser EOF/end-symbol path in:
  - `build_tables/build_parse_table.rs`
  - `build_tables/item.rs`
  - `build_tables/item_set_builder.rs`
  - `rules.rs` / symbol construction code, if needed
- [x] Add a distinct EOF/end symbol to the local symbol or syntax grammar model without
  treating it as a normal lexical terminal.
- [x] Seed parser-state construction with EOF lookahead for the start production.
- [x] Preserve EOF lookahead through FIRST-set and item-closure propagation.
- [x] Emit reduce and accept actions keyed by EOF in the serialized parse-action model.
- [x] Ensure EOF does not count as a normal named/anonymous grammar symbol in generated
  metadata tables.
- [x] Add focused parser-table tests for:
  - start-production EOF lookahead
  - EOF-keyed reduce/accept action serialization
  - no spurious lexical token generated for EOF
- [x] Convert the Phase 1 no-external link test from serialized-only fixture coverage to
  a real generated-from-grammar parser fixture.
- [x] Assert the generated-from-grammar no-external parser accepts complete input at EOF.

---

## Phase 8 — Inherited Field Metadata

RW-2 emits field map tables, but inherited field metadata is still always false because
the local IR does not track inlined-field origin.

Upstream reference check: parse-table production info marks a field location as
inherited when a production step is a non-visible nonterminal and that child variable's
node-type metadata contains fields. The field location uses the hidden child step's
index and sets `inherited = true`.

- [x] Identify where hidden/inlined rule expansion hoists field annotations into parent
  productions.
- [x] Add an `inherited` flag to the local field/production-step metadata.
- [x] Preserve the flag through syntax extraction, flattening, parse-table production
  collection, and serialization.
- [x] Emit `TSFieldMapEntry.inherited = true` where appropriate.
- [x] Add a fixture with an inlined rule that contributes a field.
- [x] Assert serialized field map entries and emitted `ts_field_map_entries[]` contain
  at least one inherited entry.

---

## Phase 9 — Conflict Resolution and Non-Terminal Extras

These are correctness-sensitive and should come after runtime link tests, because they
can change parse-table behavior broadly.

### 9a — Reduce/Reduce Without Expected Conflicts

Upstream reference check: tree-sitter resolves reduce/reduce precedence while inserting
reduce actions. Higher static precedence replaces lower-precedence reductions. Equal
static precedence remains a conflict unless the grammar declares the conflict. There is
no production-order fallback for this conflict class.

- [x] Compare local `resolution.zig` against tree-sitter's reduce/reduce resolution.
- [x] Verify the exact tie-break order: static precedence first; no production-order
  fallback when tree-sitter does not use one for the same conflict class.
- [x] Implement the narrow matching fallback.
- [x] Add a fixture that tree-sitter resolves by the same rule.
- [x] Assert the local serialized decision is chosen, not blocked.

### 9b — Non-Terminal Extras

Upstream reference check: tree-sitter precomputes one parse state per starting terminal
of non-terminal extra productions, seeded from the extra production after consuming that
starting token. Normal states receive extra shifts to those states unless they are
already at the end of a non-terminal extra. Extra productions whose first symbol is
itself a non-terminal remain unsupported locally for now.

- [x] Model extras that are non-terminals in parse-table construction.
- [x] Add extra-rule closure items where tree-sitter would allow non-terminal extras.
- [x] Ensure resulting extra shifts are represented as extra actions in serialized data.
- [x] Unblock the smallest fixture that currently depends on non-terminal extras.
- [x] Add compile-smoke coverage for that fixture.

---

## Phase 10 — Regression and Compatibility Sweep

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
