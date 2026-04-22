# MILESTONES 46 — Closing the Runtime Gap

This milestone picks up after M44 (lexer-state pipeline) and M45 (LR item-set
and action-table convergence). Those two milestones close the generator-side
algorithmic gap with tree-sitter. M46 targets the runtime-side gap: the parts
of the generated `parser.c` and the behavioral harness that still diverge from
what the tree-sitter C runtime expects.

See `docs/algorithm-comparison.md` for the full diff.

---

## Remaining Gaps After M44 + M45

### Gap 1 — GLR Runtime in Emitted Parser

M45 Phase 2–3 will introduce multi-action table entries into the serialized
form and the emitted C tables. But the emitted `parser.c` parse loop is still
single-action: it takes the first entry and stops.

Tree-sitter's runtime (`lib/src/parser.c`) walks every action in the entry
and forks a new stack version for each one. The stack is multi-headed; versions
are pruned by error cost and dynamic precedence.

### Gap 2 — Error Recovery

Tree-sitter applies two-stage error recovery when no action exists for the
current (state, lookahead) pair:

1. Walk back through stack summaries looking for a state where the lookahead
   is valid; recover to the cheapest such state.
2. If stage 1 succeeds, optionally skip the bad token too, wrapping consumed
   input in an `ERROR` node.

The generated parser currently emits no error-recovery code. Invalid input
causes a hard parse failure with no partial tree.

### Gap 3 — Reserved Words

Tree-sitter attaches a `reserved_word_set_id` to each production step. During
lexing, the active reserved-word set restricts which identifiers the lexer may
match — preventing keywords from being tokenized as generic identifiers in
contexts where the grammar would not accept them.

The grammar IR carries no reserved-word information. The emitted lexer function
ignores the reserved-word dimension.

### Gap 4 — Node-Types Field Inheritance

Tree-sitter's `ParseItem` carries `has_preceding_inherited_fields`, which
tracks whether any fields defined in ancestor productions flow through nullable
chains into the current item's parse tree node.

Gen-z-sitter's `ParseItem` has no field-inheritance bit. The emitted
`node-types.json` omits or mis-classifies fields that are contributed by
enclosing rules through nullable intermediaries.

### Gap 5 — Alias Sequences

Tree-sitter records a per-production alias list that renames children in the
emitted AST node (e.g. the grammar-level `alias($.foo, $.bar)` construct).
This list is emitted as `alias_sequences` in the `TSLanguage` struct and used
at runtime to rename child nodes without changing parse behavior.

The current emitter emits an empty `alias_sequences` table for all grammars.
Grammars that use `alias()` produce incorrectly named nodes.

### Gap 6 — Incremental Parsing Infrastructure

Tree-sitter reuses subtrees from a previous parse tree when only part of the
file changed. The relevant machinery is the `old_tree` parameter to
`ts_parser_parse` and the `ts_parser__reuse_node` fast path inside the advance
loop.

Gen-z-sitter has no incremental parsing concept. This gap is large and mostly
runtime infrastructure rather than table-generation work, but the generated
tables must carry the right metadata (reuse markers, byte ranges) to support it.

---

## TODO List

### T1 — GLR Parse Loop in Emitted Parser

**Priority: High**

- [ ] Add a `versions` array to the emitted parser context struct (max 6,
  matching tree-sitter's `TS_MAX_VERSION_COUNT`)
- [ ] Rewrite the emitted parse loop to iterate versions per lookahead step,
  following tree-sitter's outer-inner loop shape:
  `do { for each version: advance(version) } while (versions_exist)`
- [ ] Implement `shift(version, state, lookahead)` as pushing onto a version's
  stack head
- [ ] Implement `reduce(version, symbol, child_count)` as popping N children,
  creating a parent node, then looking up the new state via the `goto` table
- [ ] For states with multiple actions on the same symbol: create a new version
  for each extra action (fork), up to the version cap
- [ ] Add version pruning (`condense_versions`) after each lookahead step:
  - remove versions with error cost higher than the best by more than a
    threshold
  - merge versions that reached the same state with the same stack tail
- [ ] Add a `dynamic_precedence` accumulator per version; use it as a
  tiebreaker during pruning
- [ ] Wire the GLR loop into the behavioral harness so existing tests exercise
  the new path
- [ ] Verify all current compat targets still pass through the GLR loop

**Files:**
`src/parser_emit/parser_c.zig`, `src/parser_emit/parser_tables.zig`,
`src/behavioral/`.

---

### T2 — Error Recovery

**Priority: High** ✓ **Done (harness-level)**

- [x] `error_count: u32` added to `ParseVersion` and `SimulationResult.accepted`
- [x] `recoverFromMissingAction` implemented in the behavioral harness:
  - stage-1: scan backward through the stack for a predecessor state that
    handles the current lookahead; recover to it and increment `error_count`
  - stage-2: skip the bad token (or one byte for unrecognised input) and
    increment `error_count`
- [x] Recovery wired into both `matched_opt == null` and `decision == null`
  branches of the GLR loop
- [x] Behavioral tests: "error recovery skips an unrecognised byte" and
  "error recovery accepts valid input without recording errors" both pass
- [ ] Full emitted-parser error recovery (RECOVER action, ERROR nodes) —
  deferred to M47 once the emitted GLR loop (T1) is in place

**Files:** `src/behavioral/harness.zig`.

---

### T3 — Reserved Words

**Priority: Medium** ✓ **Partial (keyword_capture_token done)**

- [x] `word_token: ?SymbolRef` already present in `SyntaxGrammar` and
  `PreparedGrammar` (parsed from `grammar.json`)
- [x] `word_token: ?syntax_ir.SymbolRef` added to `SerializedTable`; threaded
  through `optimize.compactSerializedTableAlloc` and patched in
  `pipeline.generateParserCEmitterDumpFromPreparedWithOptions`
- [x] `uint16_t keyword_capture_token` added to `TSParser` struct
- [x] `#define TS_KEYWORD_CAPTURE_TOKEN {d}` emitted (0 when no word token,
  flat symbol ID otherwise); `.keyword_capture_token = TS_KEYWORD_CAPTURE_TOKEN`
  in the `ts_parser` initializer
- [ ] `reserved_word_set_id: u16` in `ProductionStep` — M44 lexer scope
- [ ] Reserved-word check in the emitted lexer function — M44 lexer scope
- [ ] `keyword_lex_fn` emission — M44 lexer scope

**Files:** `src/parse_table/serialize.zig`, `src/parser_emit/optimize.zig`,
`src/parse_table/pipeline.zig`, `src/parser_emit/compat.zig`,
`src/parser_emit/parser_c.zig`.

---

### T4 — Node-Types Field Inheritance

**Priority: Medium** ✓ **Already done at compute time**

Field inheritance is handled in `compute.zig` at node-type computation time —
no `ParseItem` flag needed. Test "computeNodeTypes inherits fields and children
through hidden wrappers" (line 1199) confirms correct behaviour. No further
implementation required for M46.

**Files:** `src/node_types/compute.zig`.

---

### T5 — Alias Sequences

**Priority: Medium** ✓ **Done**

- [x] `ProductionStep.alias: ?rules.Alias` already present in the IR
- [x] `SerializedAliasEntry` struct added to `serialize.zig`; `alias_sequences`
  field added to `SerializedTable`; populated in `serializeBuildResult` by
  iterating `result.productions[i].steps[j].alias`
- [x] `optimize.compactSerializedTableAlloc` passes `alias_sequences` through
- [x] `TSAliasEntry` typedef added to the emitted C (`compat.zig`)
- [x] Emitter writes `#define TS_ALIAS_COUNT {d}` and either a populated
  `ts_alias_sequences[TS_ALIAS_COUNT]` array or a null pointer sentinel
- [x] Accessors `ts_parser_alias_count` and `ts_parser_alias_at` emitted
- [x] All golden tests updated and passing

**Files:** `src/parse_table/serialize.zig`, `src/parser_emit/optimize.zig`,
`src/parser_emit/compat.zig`, `src/parser_emit/parser_c.zig`,
`src/tests/fixtures.zig`.

---

### T6 — Incremental Parsing Infrastructure (Scoping Only)

**Priority: Low** ✓ **Done (plan written)**

- [x] Documented which table fields are needed (`external_lex_state` in
  `TSRuntimeStateInfo` is the one addition required before the PoC)
- [x] Identified the minimum `ParseNode` type and value-stack changes needed
  in the harness before any reuse logic can be written
- [x] Wrote the five-step proof-of-concept plan (tree builder → edit repr →
  reuse check → external-scanner guard → test)
- [x] Listed all out-of-scope items and M47+ stubs explicitly

**Files:** `docs/incremental-parsing-plan.md`.

---

## Execution Order

```
T3 (reserved words)         — independent of T1/T2; can start now
T4 (field inheritance)      — independent of T1/T2; can start now
T5 (alias sequences)        — independent of T1/T2; can start now

T1 (GLR loop)               — requires M45 Phase 2 (multi-action table) complete
T2 (error recovery)         — requires T1 complete (needs the version loop)

T6 (incremental scoping)    — after T1+T2 are stable
```

T3, T4, T5 are additive and low-risk. Start them in parallel with the tail
end of M45. T1 is the structural pivot: it requires M45 Phase 2 to exist
before it can proceed. T2 builds on T1 and should not start until T1 is
passing all compat targets.

---

## Exit Criteria

- [ ] Emitted parsers run through the GLR loop on all compat shortlist targets
- [ ] Invalid-input test cases produce ERROR-node trees instead of hard failures
- [ ] Grammars that use `word()` produce correct keyword/identifier split
- [ ] `node-types.json` for field-inheritance test grammar matches upstream
- [ ] `alias_sequences` for alias test grammar matches upstream
- [ ] Incremental-parsing plan written and reviewed

---

## What This Does Not Cover

- Full incremental parsing implementation (scoped to T6 planning only)
- Scanner-runtime ABI beyond what M44 PR 5 already stages
- Lexer NFA→DFA changes (M44 scope)
- Named-precedence ordering changes (M45 Phase 3 scope)
