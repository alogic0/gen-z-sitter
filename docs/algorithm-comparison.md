# Algorithm Comparison: gen-z-sitter vs tree-sitter

_Updated 2026-04-25. Reflects state after ReWrite-1 (emitter ABI alignment) and
partial ReWrite-2 (lexer emission, serialization metadata)._

## What Both Share

Both implement **LR(1) parse table generation** with the same general shape:
- FIRST set computation (fixpoint loop over grammar variables)
- Canonical LR(1) item set closure
- Shift/reduce and reduce/reduce conflict detection
- Precedence + associativity-based conflict resolution
- Separate lexical and syntax grammars
- NFA → DFA lexer table construction

---

## Key Algorithmic Differences

### 1. Runtime Parsing Algorithm

|                   | gen-z-sitter                                    | tree-sitter                                            |
|-------------------|-------------------------------------------------|--------------------------------------------------------|
| **Parser type**   | Generator only — produces `parser.c`, no runtime | Full **GLR** runtime in C (`lib/src/parser.c`) |
| **Ambiguity**     | Resolved statically at table-generation time    | Handled dynamically: forks into multiple **stack versions** at parse time |
| **Stack**         | N/A                                             | Multi-headed stack, up to 6 concurrent versions (`MAX_VERSION_COUNT`) |

Tree-sitter's GLR runtime is the largest architectural difference. When a state has
both shift and reduce actions on the same token it forks the parse into concurrent
versions and prunes losers by error cost. gen-z-sitter has no runtime — it only
generates tables.

### 2. ParseItem Representation

|                       | gen-z-sitter                                                  | tree-sitter                                                             |
|-----------------------|---------------------------------------------------------------|-------------------------------------------------------------------------|
| **ParseItem**         | `(production_id: u32, step_index: u16)` — minimal            | `(variable_index, production: &Production, step_index, has_preceding_inherited_fields)` — carries a live reference to the production |
| **Lookaheads**        | `SymbolSet { terminals: []bool, externals: []bool, includes_epsilon: bool }` | `TokenSet` (compact bit vector) + `ReservedWordSetId` per entry |
| **Context follow**    | Explicit context follow sets for nullable suffix propagation  | Part of standard FIRST/closure logic inside `ParseItemSetBuilder` |

gen-z-sitter items are leaner (no production reference, no field-inheritance flag).
Tree-sitter's `has_preceding_inherited_fields` is needed to produce correct
`node-types.json` metadata when fields occur in nullable chains. gen-z-sitter computes
field metadata separately in `src/node_types/compute.zig`.

### 3. Core ID Assignment

|                        | gen-z-sitter                                                                    | tree-sitter                                           |
|------------------------|---------------------------------------------------------------------------------|-------------------------------------------------------|
| **Core identity**      | `core_id: u32` stored on `ParseState`; assigned during state closure in `build.zig` | `ParseItemSetCore` struct (items without lookaheads); keyed in `FxHashMap<ParseItemSetCore, usize>` |
| **Usage**              | `primary_state_ids[symbol]` = first state with same core; now serialized in `SerializedTable.primary_state_ids` | Used for query optimization and node reuse in incremental parsing |
| **Status**             | Fully implemented (ReWrite-2 Phase 2b) | Fully implemented |

### 4. State Minimization

|                        | gen-z-sitter                                                                    | tree-sitter                                           |
|------------------------|---------------------------------------------------------------------------------|-------------------------------------------------------|
| **Algorithm**          | `minimize.zig` — partition refinement, signature built from `(symbol_tag, symbol_idx, action_kind, action_value)` tuples | `minimize_parse_table.rs` — same partition refinement; packs symbol into 64-bit `SymbolKey` (3-bit kind + 61-bit index) for O(1) comparison |
| **Trigger**            | Optional (`minimize_states: bool` flag)                                         | Always applied |
| **Table compaction**   | N/A                                                                             | `small_parse_table` + `small_parse_table_map` for sparse states |

gen-z-sitter implements Hopcroft-style partition refinement but uses byte-array
comparison of full tuples rather than tree-sitter's packed 64-bit keys. Tree-sitter
additionally applies the large/small table split — now replicated in gen-z-sitter's
emitter (ReWrite-1).

### 5. Conflict Resolution Pipeline

Both use: precedence → associativity → expected-conflict whitelist. The structural difference:

- **gen-z-sitter** uses a **two-phase** design (`resolution.zig`): candidates are
  collected first, then resolved independently. `ResolvedDecision` distinguishes
  `reduce_reduce_expected` (diagnostic only) from `reduce_reduce_deferred` (blocking
  gap). Fully auditable — each decision is a value, not an in-place mutation.
- **tree-sitter** interleaves conflict detection and resolution during table
  construction (`handle_conflict` modifies state actions in-place) — faster but the
  resolution logic is entangled with state construction.

Remaining gap: gen-z-sitter does not yet resolve non-trivial reduce/reduce conflicts
without an `expected_conflicts` annotation.

### 6. Lex State Assignment

|                        | gen-z-sitter                                                                    | tree-sitter                                           |
|------------------------|---------------------------------------------------------------------------------|-------------------------------------------------------|
| **Grouping**           | `assignLexStateIdsAlloc()` in `build.zig` groups parse states by identical terminal set; assigns one `lex_state_id` per distinct set | Embedded in lexer build; not a separate named phase |
| **Serialization**      | Terminal sets preserved as `lex_state_terminal_sets: [][]bool` in `SerializedTable` | Computed on demand during rendering |
| **Lex modes table**    | `ts_lex_modes[parse_state] = { lex_state, external_lex_state=0, reserved_word_set_id=0 }` | Same shape; `external_lex_state` and `reserved_word_set_id` populated |

gen-z-sitter serializes the terminal sets explicitly so the C emitter does not need
to re-derive them from the grammar. `external_lex_state` and `reserved_word_set_id`
fields default to `0` — not yet wired (ReWrite-2 Phases 6, 8).

### 7. Lexer C-Code Generation

|                        | gen-z-sitter                                                                    | tree-sitter                                           |
|------------------------|---------------------------------------------------------------------------------|-------------------------------------------------------|
| **Emitter**            | `src/lexer/emit_c.zig` — `emitLexFunction(writer, fn_name, lex_table)` (ReWrite-2 Phase 4, done) | `render.rs::add_lex_function` + `add_lex_state` |
| **DFA representation** | `SerializedLexTable { states: []SerializedLexState, start_state_id }` built by `buildLexTablesAlloc()` | Internal `LexTable` struct built during Rust table generation |
| **Transition conditions** | Single char as `lookahead == X`; ranges as `start <= lookahead && lookahead <= end`; separator transitions as `SKIP` | Same, plus: adjacent 2-char range as two equality checks; `!eof` guard for ranges containing `0` |
| **`ADVANCE_MAP` optimization** | Not yet implemented | Used when leading simple-transition count ≥ 8 (batches multiple `(char, next_state)` into an array lookup) |
| **EOF transitions**    | `eof_target` field in `SerializedLexState`; not yet modeled in local lexer IR | Emitted as `if (eof) ADVANCE(target)` |
| **Status**             | Core path working; `ADVANCE_MAP` and EOF transitions deferred | Fully implemented |

### 8. Keyword Lexer

|                        | gen-z-sitter                                    | tree-sitter                                      |
|------------------------|-------------------------------------------------|--------------------------------------------------|
| **`ts_lex_keywords`**  | Planned (ReWrite-2 Phase 6, unchecked)          | Emitted when `word_token` is present; separate lex function for keyword patterns competing with the word token |
| **`keyword_lex_fn`**   | `NULL` in current `ts_language` literal         | Set to `ts_lex_keywords` when `word_token` is present |

### 9. External Scanner

|                        | gen-z-sitter                                                              | tree-sitter                                              |
|------------------------|---------------------------------------------------------------------------|----------------------------------------------------------|
| **Tables emitted**     | None — `TSLanguage.external_scanner` zero-initialized (ReWrite-2 Phase 8, unchecked) | `ts_external_scanner_symbol_map[]`, `ts_external_scanner_states[][]`, function forward-declarations |
| **Grammar IR**         | `PreparedGrammar.external_tokens` present                                 | Fully modeled; per-lex-state external token availability tracked |

### 10. Error Recovery

Tree-sitter has a two-strategy runtime recovery:
1. Look back through the stack summary (up to `MAX_SUMMARY_DEPTH = 16` states) to
   find a state where the bad token is valid.
2. Skip the bad token and wrap skipped content in an `ERROR` node.
3. Cost function drives version pruning: `error_cost + depth × penalty + bytes_skipped × penalty`.

gen-z-sitter: no error recovery — unresolvable conflicts produce a diagnostic
(`UnresolvedReason`), not a runtime fallback. The runtime error recovery lives
entirely in the tree-sitter C library, which gen-z-sitter's generated `parser.c`
links against.

### 11. Incremental Parsing

Tree-sitter's central feature: reuse subtrees from the previous parse when only part
of the file changed.
- `ts_parser__reuse_node`: if the old tree's subtree matches current state + position,
  skip re-parsing entirely.
- `included_ranges`: limit work to changed regions.
- Subtree reference counting (`SubtreeHeapData.ref_count`) and copy-on-write
  (`ts_subtree_make_mut`).

gen-z-sitter: no incremental parsing — this lives entirely in the tree-sitter runtime
and is orthogonal to table generation.

---

## Summary

gen-z-sitter is a **Zig reimplementation of tree-sitter's Rust generator**. After
ReWrite-1 and partial ReWrite-2 the emitter now produces a layout-compatible
`TSLanguage` and a working lexer C body for grammars without external scanners.

### gen-z-sitter additions over tree-sitter's generator

1. **DFA minimization** (`minimize.zig`) — not present in tree-sitter's generator.
2. **Two-phase conflict resolution** — candidates collected first, then resolved;
   each decision is an explicit value, not an in-place mutation.
3. **Explicit serialization boundary** — all data needed by the C emitter is
   pre-computed into `SerializedTable`; the emitter reads only serialized data.

### Remaining generator gaps (after ReWrite-1 + partial ReWrite-2)

| Gap | Blocking? |
|-----|-----------|
| `ADVANCE_MAP` optimization (≥ 8 leading simple transitions) | No — generates correct but larger code |
| EOF-specific lex transitions in serialized lex model | No — produces wrong lex behavior only at EOF edge cases |
| `ts_lex_keywords` / keyword lexer body | Yes — grammars with `word_token` lex incorrectly |
| External scanner tables and function declarations | Yes — grammars with `externals` produce non-functional parser |
| `extra` / `repetition` shift action flags | No — extras work but are not marked; affects `ts_node_is_extra()` |
| `ts_non_terminal_alias_map` content | No — stubs cause wrong query results, not crashes |
| Reserved-word set assignment (`reserved_word_set_id`) | No — reserved words not enforced |
| Supertype tables | No — affects `ts_node_is_named()` for supertypes only |
| Non-trivial reduce/reduce conflict resolution | No — requires `expected_conflicts` annotation to work around |

### What gen-z-sitter intentionally omits (runtime, not generator)

- **GLR multi-version parse stack** — in the tree-sitter C runtime.
- **Incremental parsing / subtree reuse** — in the tree-sitter C runtime.
- **Two-stage error recovery with cost-based pruning** — in the tree-sitter C runtime.
