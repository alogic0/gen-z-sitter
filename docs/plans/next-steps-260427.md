# Next Steps — 2026-04-27

This plan picks up after `docs/plans/next-steps-260426.md`. M45 is closed for
bounded local work: expected-conflict reporting and policy routing are wired,
state minimization has a bounded gate, and pipeline goldens are current.

The previous draft assumed the M47 tree builder was already merged. That was
not true in the codebase, so the execution order is corrected below.

---

## What Is Now True

- `expected_conflicts` supports reduce/reduce and shift/reduce policy matching.
- Unused `expected_conflicts` are visible in generate JSON summaries and as
  non-strict warnings.
- A staged parser-only fixture covers an expected shift/reduce conflict.
- `TSUnresolved` side tables and generated C accessors exist.
- State minimization is integrated behind `--minimize` with bounded local
  reporting.
- The behavioral harness has GLR stack forking and two-stage error recovery.

The remaining high-impact gap is split into two tracks:

- **M47 tree builder / incremental parsing groundwork** in the behavioral
  harness.
- **M46 emitted parser GLR loop** in generated `parser.c`.

M47 is the safer bounded track and should come first. The emitted-C GLR loop is
larger and should stay behind an opt-in flag when started.

---

## Priority 1 — M47 Tree Builder

**Goal.** Build a syntax tree in the scanner-free behavioral GLR harness so
incremental parsing has a concrete tree to reuse.

**Implementation shape.**

1. Add `ParseNode` with:
   - `production_id`
   - `start_byte`
   - `end_byte`
   - `entry_state`
   - `children`
   - `is_error`
   - `reused`
2. Add a value stack to each scanner-free `ParseVersion`.
3. On shift, push a terminal node with the consumed byte range.
4. On reduce, pop N child nodes and push a parent node.
5. Return the accepted root as `SimulationResult.accepted.tree`.

**Gate.**

- `zig build test-behavioral`
- A focused scanner-free test parses `1+2+3` and asserts the accepted tree spans
  the full input and contains the expected terminal leaves.

**Completed bounded steps.**

- [x] Add `ParseNode`.
- [x] Add scanner-free GLR value stacks.
- [x] Build terminal nodes on shift and parent nodes on reduce.
- [x] Return the accepted scanner-free root as `SimulationResult.accepted.tree`.
- [x] Add focused scanner-free tree coverage.

---

## Priority 2 — M47 Incremental Parsing Proof-of-Concept

**Prerequisite.** Priority 1 tree builder.

**Implementation shape.**

1. Add:
   ```zig
   pub const Edit = struct {
       start_byte: u32,
       old_end_byte: u32,
       new_end_byte: u32,
   };
   ```
2. Add `simulateIncremental` accepting `old_tree: ?ParseNode` and `edit: Edit`.
3. Before lexing at a cursor, find a reusable old subtree whose:
   - `start_byte == cursor`
   - `cursor >= edit.new_end_byte`
   - `entry_state == current parse state`
4. Reuse the subtree by advancing to `end_byte` and pushing the node.
5. Skip reuse for states with external lex state once that metadata is exposed.

**Completed bounded steps.**

- [x] Add `Edit`.
- [x] Add tree equivalence and reusable-prefix marker helpers.
- [x] Add a scanner-free incremental entry point.
- [x] Reuse unchanged old subtrees in the scanner-free parse loop by matching
  cursor and entry state, then advancing directly to the reused subtree end.

**Remaining.**

- Tighten equivalence assertions for ambiguous grammars, where fresh and
  incremental parses can choose different valid tree shapes.
- Add external-lex-state guards before broadening reuse beyond scanner-free
  fixtures.

**Gate.**

- Fresh parse and incremental parse produce equivalent trees.
- Appending `+4` to `1+2+3` reuses the prefix nodes and parses the new suffix.

---

## Priority 3 — M46 Emitted Parser GLR Loop

**What is missing.**

The emitted `parser.c` is still single-action. The behavioral harness GLR logic
does not yet appear in generated C.

**Implementation shape.**

1. Add an opt-in build/emitter flag for the GLR loop.
2. Add generated parser version storage with a bounded version count.
3. Port the behavioral harness loop shape:
   - lex per active version
   - shift/reduce/accept per version
   - fork on `TSUnresolved`
   - condense versions
   - accumulate dynamic precedence
4. Keep grammars without unresolved entries behaviorally unchanged.

**Gate.**

- Existing generated parser C still compiles with the default path.
- Opt-in GLR loop compiles on small staged fixtures before broad compat runs.

**Completed bounded steps.**

- [x] Add an internal emitter option and generated C feature macro for the
  emitted parser GLR loop without changing default generated parser output.
- [x] Add generated parser version storage with a fixed version cap behind the
  opt-in GLR macro.

---

## Priority 4 — Broader Compat Coverage

The next meaningful real grammar addition is JSON. It is small, scanner-free,
and useful as a fast end-to-end real-world regression target.

Process:

1. Add `tree-sitter-json` `grammar.json` and sample input to `compat_targets/`.
2. Run at compile-smoke/full parser-only level.
3. Add it to the shortlist only after the local proof is stable.
4. Refresh checked-in compatibility artifacts in one explicit batch.

---

## Deferred

- Emitted parser error recovery (`RECOVER` and ERROR nodes) until the emitted GLR
  loop exists.
- `#pragma GCC optimize ("O0")` for large lex tables.
- Public `TSTree` / `TSNode` ABI compatibility.
- Multi-language included ranges.
