# ReWrite-5_1: External-Token Reduce Lookaheads from Recursive Grammars

## Goal

Prove that the parse-table builder correctly propagates external tokens into
reduce lookaheads for a recursive grammar where an external token closes a
nesting level.  Promote `bracket_lang` from flat `SEQ(OPEN, OPEN, CLOSE, CLOSE)`
to the nested grammar `item := OPEN item? CLOSE` and assert the nested parse
tree.

---

## Background

The note in `tmp/The gap is about parse.txt` identified this gap.

The runtime/serialization path is already proven (RW-5): a hand-crafted table
entry `{ .symbol = .{ .external = 1 }, .action = .{ .reduce = … } }` survives
serialization, emission, compile, link, and triggers a correct reduce at runtime.

The builder has the right pieces for this path, but the recursive path still
needs a direct proof:
- `first.zig:6-10` — `SymbolSet` has separate `terminals: []bool` and
  `externals: []bool`, mirroring Rust's `TokenSet`.
- `first.zig:133-136` — external symbols set `externals[index]` in FIRST
  computation.
- `first.zig:190-195` — `mergeSymbolSet` propagates externals.
- `actions.zig:108-121` — reduce-action insertion iterates externals separately
  and emits `.{ .symbol = .{ .external = N }, .action = .{ .reduce = … } }`.
- `serialize.zig:1376-1382` — `buildExternalScannerStatesAlloc` iterates all
  actions including reduces, so external-keyed reduces also mark the token valid.

**The remaining gap is parser-table generation:** no test drives a recursive
external-token grammar through the builder and asserts that the reduce state
allows the external close token.  The flat `bracket_lang` grammar sidesteps the
recursive closure path entirely.

---

## Non-Goals

- Changes to serialization or emission (proven by RW-5).
- Changes to the external scanner C callbacks (proven by RW-5).
- Bash or Haskell promotion (blocked by construction cost, separate gap).
- Incremental parsing, GLR, or error recovery.

---

## Phases

### Phase 1 — Focused failing test: recursive grammar → reduce-on-external lookahead

[x] Add a unit test in `src/parse_table/` (or alongside
    `test-compat-heavy` if it fits better) that:

    1. Constructs a minimal grammar in-memory:
       ```
       externals: [open_bracket, close_bracket]
       rules:
         source := item
         item   := open_bracket item? close_bracket
       ```
       Expressed as `syntax_ir` / `PreparedGrammar` directly (bypassing JSON
       loading) to keep the test self-contained and fast.

    2. Runs the full parse-table builder on this grammar.

    3. Asserts that the resulting serialized action table contains at least one
       entry of the form:
       ```zig
       .{ .symbol = .{ .external = 1 }, .action = .{ .reduce = _ } }
       ```
       (where `1` is the index of `close_bracket` in the externals list).

    Gate: run the focused `src/parse_table/pipeline.zig` test first.  If it
    fails, proceed to Phase 2.  If it passes, run the fast local unit suite
    before Phase 3.

    Implemented in `src/parse_table/pipeline.zig` as
    `serializeTableFromPrepared carries recursive external close reduce
    lookahead`.

### Phase 2 — Fix lookahead propagation

[x] Fixed closure lookahead propagation for recursive external-token contexts.
    The builder now carries the full inherited lookahead set into closure context
    and projects external suffix lookaheads when nullable recursive additions
    propagate through that context.

### Phase 3 — Promote bracket_lang to nested grammar

[x] Update `compat_targets/bracket_lang/grammar.json` from:
    ```json
    "source": { "type": "SEQ", "members": [
      { "type": "SYMBOL", "name": "open_bracket" },
      { "type": "SYMBOL", "name": "open_bracket" },
      { "type": "SYMBOL", "name": "close_bracket" },
      { "type": "SYMBOL", "name": "close_bracket" }
    ]}
    ```
    to:
    ```json
    "source": { "type": "SYMBOL", "name": "item" },
    "item": { "type": "SEQ", "members": [
      { "type": "SYMBOL", "name": "open_bracket" },
      { "type": "CHOICE", "members": [
        { "type": "SYMBOL", "name": "item" },
        { "type": "BLANK" }
      ]},
      { "type": "SYMBOL", "name": "close_bracket" }
    ]}
    ```

[x] Run the targeted `bracket_lang` runtime-link check.  Confirm: compile,
    link, and parse succeed.  Do not run `zig build test-compat-heavy` for this
    plan unless explicitly requested.

### Phase 4 — Assert nested parse tree

[x] In `src/compat/runtime_link.zig`, extend (or add alongside) the
    `bracket_lang` runtime-link fixture to:

    1. Feed nested input `"(())"` through the linked parser + external scanner.
    2. Assert the root node is not an ERROR node.
    3. Assert child structure: outer `item` → inner `item` nesting (at least two
       `item` nodes, no ERROR).

    The external scanner C file at `compat_targets/bracket_lang/scanner.c` (or
    equivalent) already handles `(` and `)` correctly for the flat case; check
    whether it also handles a nested call correctly (it should, since it just
    reports the token type without counting depth).

[x] Run `zig build test` and confirm the new assertions pass alongside all prior
    `bracket_lang` tests.

### Phase 5 — Update records

[x] Update `GAPS_260425.md`:
    - Close gap 3 sub-item "nested external-close reduction remains future
      parser-table work."
    - Add a "Closed by ReWrite-5_1" section noting: recursive external-token
      grammar builds reduce-on-external lookaheads; `bracket_lang` promotes to
      nested grammar with nested-tree assertion.

[x] Update affected compat snapshots or records if the fixture shape changes.
    Updated the shortlist target metadata and inventory records for the recursive
    fixture proof.

---

## Success Criteria

- Phase 1 test passes: action table for the in-memory recursive grammar contains
  a `.{ .symbol = .{ .external = 1 }, .action = .{ .reduce = _ } }` entry.
- `bracket_lang` compat target uses the nested grammar and its targeted
  runtime-link check (load → prepare → build → serialize → emit → compile →
  link → parse) passes.
- Runtime-link test asserts nested structure for input `"(())"` without ERROR.
- Focused parse-table tests and the fast local unit suite are green.
- No regressions in any other compat target or runtime-link fixture.
